import Foundation
import SwiftData

/// What one pass did. Plain values only -- this crosses back from a
/// `@ModelActor`. Counts here are diagnostics for the calibration row and
/// the log; no surface shows them as anything but a fact about the pass.
struct PeopleIndexReport: Sendable, Equatable {
    /// People in three or more entries after every exclusion.
    let listed: Int
    /// People in exactly two.
    let noticed: Int
    /// Entries the tagger ran on.
    let tagged: Int
    /// Entries still untagged when the pass budget ran out.
    let pending: Int
    /// `JournalPerson` rows written (created or changed).
    let changedRows: Int
    let duration: TimeInterval
    /// Why nothing ran, when nothing ran ("off", "seeding", "store").
    let skipped: String?
    /// When the pass ended.
    let date: Date

    init(listed: Int, noticed: Int, tagged: Int, pending: Int, changedRows: Int,
         duration: TimeInterval, skipped: String?, date: Date = .now) {
        self.listed = listed
        self.noticed = noticed
        self.tagged = tagged
        self.pending = pending
        self.changedRows = changedRows
        self.duration = duration
        self.skipped = skipped
        self.date = date
    }

    static func skipped(_ reason: String) -> PeopleIndexReport {
        PeopleIndexReport(listed: 0, noticed: 0, tagged: 0, pending: 0, changedRows: 0, duration: 0, skipped: reason)
    }

    /// The names the list and Diagnostics read it by.
    var scanned: Int { tagged }
    var durationSeconds: Double { duration }

    // MARK: The last completed pass, as the list's empty state and
    // Diagnostics read it: a small dictionary in `UserDefaults.standard`
    // (app-group-free, so the extensions never see even a count). Written
    // by `JournalPeopleIndexer` at the end of every pass that ran; cleared
    // by "Forget the people index".

    static let key = "cobux.people.lastReport"

    static func read() -> PeopleIndexReport? {
        guard let dict = UserDefaults.standard.dictionary(forKey: key) else { return nil }
        return PeopleIndexReport(
            listed: dict["listed"] as? Int ?? 0,
            noticed: dict["noticed"] as? Int ?? 0,
            tagged: dict["scanned"] as? Int ?? 0,
            pending: dict["pending"] as? Int ?? 0,
            changedRows: dict["changedRows"] as? Int ?? 0,
            duration: dict["durationSeconds"] as? Double ?? 0,
            skipped: nil,
            date: dict["date"] as? Date ?? .distantPast)
    }

    func write() {
        UserDefaults.standard.set([
            "listed": listed, "noticed": noticed, "scanned": tagged, "pending": pending,
            "changedRows": changedRows, "durationSeconds": duration, "date": date,
        ] as [String: Any], forKey: Self.key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// The calibration read for Diagnostics (`docs/people-in-the-journal.md` §2,
/// "Calibration before trust"): the two tiers with their entry counts, and
/// the last pass. A human read, never a surface.
struct PeopleCalibration: Sendable, Equatable {
    struct Row: Sendable, Equatable {
        let name: String
        let entries: Int
    }
    let listed: [Row]
    let noticed: [Row]
    let lastPass: PeopleIndexReport?
    let lastPassDate: Date?
}

/// The People index pass: `SeedRunner`'s shape -- a `@ModelActor` owning a
/// context confined to its own executor, off main by construction.
///
/// It reads entries in a snapshot (id, text, dates -- `propertiesToFetch`,
/// no relationship ever faulted, so it is safe while seeding still touches
/// the store), hands them to `JournalPeopleRecognizer` (pure), and writes
/// only the `JournalPerson` rows that changed. Incremental by text hash, so
/// an unchanged entry is never re-tagged; bounded to `passBudget` entries of
/// tagging per pass, so a cold index of 3,000 entries is spread over a few
/// passes and never sits in front of the tab.
///
/// **Two stores, split by who decided** (§2): his decisions live on the rows
/// and survive a restore; what the machine derived -- which entry carried
/// which surface form, the text hashes, the last pass -- lives in
/// `Application Support/People/scan.json`, `VolumeStore`'s convention:
/// excluded from backup, regenerable in a second. Lose it and nothing of his
/// is lost.
///
/// **The rows are his.** The pass never renames what he named, never
/// re-lists a `notPerson`, never touches a `self` row, and folds a newly
/// seen form into an existing row's aliases only by case-insensitive match
/// -- Merge, Split, Rename, Not a person and This is me are row edits the
/// page makes, and the pass respects every one of them.
///
/// **When it runs**: `schedule(container:)` from launch settle, a compose
/// save, an import, a restore and a quiet-word change; `runNow` from the
/// list's pull-to-refresh. Scheduling is debounced and single-flight, waits
/// out seeding, and is fire-and-forget from the caller's side -- a save
/// never waits on it (`JournalAutoExportService.exportAfterWrite`'s rule).
///
/// Nothing here makes a network request, writes to the app group, or
/// touches Spotlight, widgets or notifications. Pull only.
@ModelActor
actor JournalPeopleIndexer {
    // MARK: - Settings

    /// "Notice people in my journal". Absent means ON (Q4, recorded in the
    /// recognizer's header). Read from `.standard`: nothing about People may
    /// live in the app-group suite (§6).
    static let enabledKey = "cobux.people.enabled"

    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: enabledKey) != nil else { return true }
        return defaults.bool(forKey: enabledKey)
    }

    /// Entries tagged per pass. ~1 ms an entry on his corpus, so a pass is
    /// well under a second of background work; the rest waits for the next.
    static let passBudget = 200

    // MARK: - Scheduling

    /// Debounced, single-flight, seeding-aware. Safe to call from anywhere,
    /// any number of times; the caller never waits.
    ///
    /// - Parameter delay: how long to coalesce further requests before the
    ///   pass runs. Launch passes a longer one so the first seconds of a
    ///   session belong to the person, not to indexing they cannot see.
    static func schedule(container: ModelContainer, after delay: Duration = .seconds(1.5)) {
        Task(priority: .utility) {
            await Scheduler.shared.request(container: container, after: delay)
        }
    }

    /// The pull-to-refresh entry: runs one pass now (still off main, still
    /// waiting out seeding) and returns its report.
    static func runNow(container: ModelContainer) async -> PeopleIndexReport {
        await Scheduler.shared.runNow(container: container)
    }

    /// The calibration read, for Diagnostics.
    static func calibration(container: ModelContainer) async -> PeopleCalibration {
        await JournalPeopleIndexer(modelContainer: container).calibration()
    }

    /// "Forget the people index": every row, and the ledger. The thumbnails
    /// are `PeopleThumbnailStore`'s to clear (Settings calls both). Entries
    /// are untouched -- the index is not the record.
    static func forget(container: ModelContainer) async {
        await JournalPeopleIndexer(modelContainer: container).forgetEverything()
    }

    /// Owns the debounce and the single-flight guard, and remembers the
    /// container so a quiet-word change (`JournalQuietWords.onChange`, which
    /// has no container of its own) can ask for a pass.
    private actor Scheduler {
        static let shared = Scheduler()

        private var pending: Task<Void, Never>?
        private var running = false
        private var requestedAgain = false
        private var container: ModelContainer?
        private var quietWordsHookInstalled = false

        func request(container: ModelContainer, after delay: Duration) {
            self.container = container
            installQuietWordsHook()
            pending?.cancel()
            pending = Task(priority: .utility) { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                _ = await self.runIfIdle(container: container)
            }
        }

        /// From `JournalQuietWords.onChange`: a pass only if a container has
        /// been seen this launch (before that there is nothing to index).
        func requestIfKnown() {
            guard let container else { return }
            request(container: container, after: .seconds(1))
        }

        func runNow(container: ModelContainer) async -> PeopleIndexReport {
            self.container = container
            installQuietWordsHook()
            pending?.cancel()
            pending = nil
            return await runIfIdle(container: container)
        }

        private func installQuietWordsHook() {
            guard !quietWordsHookInstalled else { return }
            quietWordsHookInstalled = true
            // Written where it is read: `add`/`remove` fire the hook on the
            // main actor, so it is installed there too, not from this actor.
            Task { @MainActor in
                JournalQuietWords.onChange = {
                    Task(priority: .utility) { await Scheduler.shared.requestIfKnown() }
                }
            }
        }

        /// Single-flight: a request that lands mid-pass runs one more pass
        /// after it, never two at once against the same rows.
        private func runIfIdle(container: ModelContainer) async -> PeopleIndexReport {
            guard !running else {
                requestedAgain = true
                return .skipped("running")
            }
            running = true
            defer { running = false }
            var report = await runWaitingOutSeeding(container: container)
            while requestedAgain {
                requestedAgain = false
                report = await runWaitingOutSeeding(container: container)
            }
            return report
        }

        /// Seeding owns the store on a first launch; the pass waits for it
        /// (bounded) rather than reading rows still being written. A pass
        /// that ran out of budget schedules its successor after a real pause.
        private func runWaitingOutSeeding(container: ModelContainer) async -> PeopleIndexReport {
            var waits = 0
            while await MainActor.run(body: { SeedingStatus.shared.isSeeding }) == true {
                waits += 1
                guard waits <= 60 else {
                    // A long first seed: come back later rather than stay
                    // silent until the next save.
                    request(container: container, after: .seconds(30))
                    return .skipped("seeding")
                }
                try? await Task.sleep(for: .seconds(2))
            }
            let report = await JournalPeopleIndexer(modelContainer: container).runPass()
            if report.pending > 0, report.skipped == nil {
                request(container: container, after: .seconds(3))
            }
            return report
        }
    }

    // MARK: - The pass

    func runPass() async -> PeopleIndexReport {
        guard Self.isEnabled else { return .skipped("off") }
        let started = Date.now
        let previous = Self.readLedger()

        // 1. Entries, in a snapshot: id, text, the two dates. Nothing else
        //    is fetched and no relationship is touched.
        var entryDescriptor = FetchDescriptor<PersonalWritingEntry>()
        entryDescriptor.propertiesToFetch = [\.id, \.text, \.modifiedDate, \.dateImported]
        guard let rows = try? modelContext.fetch(entryDescriptor) else { return .skipped("store") }
        var snapshots: [JournalPeopleRecognizer.EntrySnapshot] = []
        snapshots.reserveCapacity(rows.count)
        // Every entry is hashed every pass: SHA-256 over his whole corpus is
        // about a millisecond, and a reused hash is how a same-length edit
        // would slip past the incremental rule.
        for row in rows {
            snapshots.append(.init(id: row.id,
                                   stamp: row.modifiedDate ?? row.dateImported,
                                   text: row.text,
                                   textHash: JournalPeopleRecognizer.textHash(row.text)))
            if snapshots.count % 100 == 0 { await Task.yield() }
        }

        // 2. His rows, and the exclusions they and the rest of the app give.
        let people = (try? modelContext.fetch(FetchDescriptor<JournalPerson>())) ?? []
        var bookDescriptor = FetchDescriptor<Book>()
        bookDescriptor.propertiesToFetch = [\.author]
        let authors = ((try? modelContext.fetch(bookDescriptor)) ?? []).map(\.author)

        var selfNames = JournalPeopleRecognizer.selfNames(
            fromDisplayName: UserDefaults.standard.string(forKey: "cobux.user.displayName") ?? "")
        var notPersonForms: Set<String> = []
        var confirmedForms: Set<String> = []
        var aliasFolds: [String: String] = [:]
        for person in people {
            switch person.kind {
            case .isSelf:
                selfNames.formUnion(person.allForms.map(JournalPeopleRecognizer.fold))
            case .notPerson:
                notPersonForms.formUnion(person.allForms.map(JournalPeopleRecognizer.fold))
            case .person:
                let canonical = JournalPeopleRecognizer.fold(person.name)
                guard !canonical.isEmpty else { continue }
                aliasFolds[canonical] = canonical
                for alias in person.aliases {
                    let folded = JournalPeopleRecognizer.fold(alias)
                    if !folded.isEmpty { aliasFolds[folded] = canonical }
                }
                if person.confirmedAt != nil {
                    confirmedForms.formUnion(person.allForms.map(JournalPeopleRecognizer.fold))
                }
            }
        }
        let exclusions = JournalPeopleRecognizer.Exclusions(
            authorSurnames: JournalPeopleRecognizer.authorSurnames(fromAuthors: authors),
            selfNames: selfNames,
            quietWords: Set(JournalQuietWords.all()),
            suppressedEntryIDs: EbbSuppressionStore.suppressedIDs(),
            notPersonForms: notPersonForms,
            confirmedPersonForms: confirmedForms)

        // 3. Recognise, within budget.
        let scan = JournalPeopleRecognizer.scan(entries: snapshots,
                                                exclusions: exclusions,
                                                ledger: previous.entries,
                                                aliasFolds: aliasFolds,
                                                budget: Self.passBudget)
        await Task.yield()

        // 4. Reconcile rows. Only `person` rows are ever written by the pass.
        var changed = 0
        var rowsByFold: [String: JournalPerson] = [:]
        for person in people where person.kind == .person {
            for form in person.allForms {
                let folded = JournalPeopleRecognizer.fold(form)
                if !folded.isEmpty, rowsByFold[folded] == nil { rowsByFold[folded] = person }
            }
        }
        var touched: Set<UUID> = []
        for cluster in scan.clusters {
            let folds = [cluster.key] + cluster.forms.map(JournalPeopleRecognizer.fold)
            if let row = folds.lazy.compactMap({ rowsByFold[$0] }).first {
                touched.insert(row.id)
                if apply(cluster, to: row) { changed += 1 }
            } else {
                let row = JournalPerson(name: cluster.forms.first ?? cluster.key,
                                        kind: .person,
                                        aliases: Array(cluster.forms.dropFirst()),
                                        entryIDs: cluster.entryIDs,
                                        firstSeen: cluster.firstSeen,
                                        lastSeen: cluster.lastSeen)
                modelContext.insert(row)
                for fold in folds where rowsByFold[fold] == nil { rowsByFold[fold] = row }
                touched.insert(row.id)
                changed += 1
            }
        }
        // A person row no cluster reached -- a name he quieted, or one that
        // fell below Noticed -- loses its ids, so its page goes on the next
        // open. Only when the pass covered every entry: a partial cold pass
        // must not zero a row whose entries are simply not tagged yet.
        if scan.pendingEntries == 0 {
            for person in people where person.kind == .person && !touched.contains(person.id) && !person.entryIDs.isEmpty {
                person.entryIDs = []
                person.updatedAt = .now
                changed += 1
            }
        }

        if changed > 0 {
            do {
                try modelContext.save()
            } catch {
                DiagnosticLog.log("people: save failed: \(error)")
                return .skipped("save")
            }
        }

        // 5. The ledger, and the report.
        let listed = scan.clusters.filter { $0.tier == .listed }.count
        let noticed = scan.clusters.count - listed
        let report = PeopleIndexReport(listed: listed, noticed: noticed,
                                       tagged: scan.taggedEntries, pending: scan.pendingEntries,
                                       changedRows: changed,
                                       duration: Date.now.timeIntervalSince(started), skipped: nil)
        Self.writeLedger(Ledger(entries: scan.ledger, lastPass: report, lastPassDate: report.date))
        report.write()
        DiagnosticLog.log(String(format: "people: listed=%d noticed=%d tagged=%d pending=%d rows=%d %.0f ms",
                                 listed, noticed, scan.taggedEntries, scan.pendingEntries, changed,
                                 report.duration * 1000))
        return report
    }

    /// Writes a cluster onto an existing row without touching what he
    /// decided: the name stays, forms fold into aliases by case-insensitive
    /// match, ids and span are replaced. Returns whether anything changed.
    private func apply(_ cluster: JournalPeopleRecognizer.PersonCluster, to row: JournalPerson) -> Bool {
        var changed = false
        for form in cluster.forms {
            if row.addAlias(form) { changed = true }
        }
        if row.entryIDs != cluster.entryIDs {
            row.entryIDs = cluster.entryIDs
            changed = true
        }
        if row.firstSeen != cluster.firstSeen {
            row.firstSeen = cluster.firstSeen
            changed = true
        }
        if row.lastSeen != cluster.lastSeen {
            row.lastSeen = cluster.lastSeen
            changed = true
        }
        if changed { row.updatedAt = .now }
        return changed
    }

    // MARK: - Calibration and forgetting

    func calibration() -> PeopleCalibration {
        let people = (try? modelContext.fetch(FetchDescriptor<JournalPerson>())) ?? []
        let visible = people
            .filter { $0.kind == .person && $0.mentionCount >= JournalPeopleRecognizer.noticedThreshold }
            .sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
        let rows = visible.map { PeopleCalibration.Row(name: $0.name, entries: $0.mentionCount) }
        let ledger = Self.readLedger()
        return PeopleCalibration(
            listed: rows.filter { $0.entries >= JournalPeopleRecognizer.listedThreshold },
            noticed: rows.filter { $0.entries < JournalPeopleRecognizer.listedThreshold },
            lastPass: ledger.lastPass,
            lastPassDate: ledger.lastPassDate)
    }

    func forgetEverything() {
        let people = (try? modelContext.fetch(FetchDescriptor<JournalPerson>())) ?? []
        for person in people { modelContext.delete(person) }
        try? modelContext.save()
        try? FileManager.default.removeItem(at: Self.ledgerURL)
        PeopleIndexReport.clear()
    }

    // MARK: - The scan ledger (machine-derived, regenerable, never backed up)

    struct Ledger: Codable, Sendable {
        var version: Int = 1
        var entries: [UUID: JournalPeopleRecognizer.ScanRecord] = [:]
        var lastPass: PeopleIndexReport?
        var lastPassDate: Date?
    }

    /// `Application Support/People/scan.json` -- `VolumeStore`'s directory
    /// convention. Never in the app group, never in a backup.
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("People", isDirectory: true)
    }

    static var ledgerURL: URL { directory.appendingPathComponent("scan.json") }

    static func readLedger() -> Ledger {
        guard let data = try? Data(contentsOf: ledgerURL),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data),
              ledger.version == 1 else { return Ledger() }
        return ledger
    }

    static func writeLedger(_ ledger: Ledger) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(ledger)
            var url = ledgerURL
            try data.write(to: url, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        } catch {
            DiagnosticLog.log("people: ledger write failed: \(error)")
        }
    }
}

extension PeopleIndexReport: Codable {}

/// The tier a row is in, derived from its ids against the recognizer's
/// thresholds -- the one place the list and the page read it. App target
/// only: the model is compiled into the extensions and must not know the
/// recognizer.
extension JournalPerson {
    var tier: JournalPeopleRecognizer.Tier? {
        guard kind == .person else { return nil }
        if mentionCount >= JournalPeopleRecognizer.listedThreshold { return .listed }
        if mentionCount >= JournalPeopleRecognizer.noticedThreshold { return .noticed }
        return nil
    }
}
