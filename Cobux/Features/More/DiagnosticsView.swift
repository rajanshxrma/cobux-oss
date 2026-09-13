import SwiftUI
import SwiftData
import UIKit

/// Visibility into the exact classes of invisible corruption this app has
/// actually had: the `Highlight.chapter` free-text join silently going stale,
/// duplicate IDs collapsing SwiftUI's diffing, embeddings not finishing their
/// backfill, and so on. The point is turning "something is subtly wrong" into
/// a number Rajan can see without attaching a debugger — part of the answer to
/// "I shouldn't have to be the bug-finder."
///
/// Ships in Release (see `MoreView`), so it is a `@ModelActor` probe, not a
/// screen of `@Query`s. It used to hold seven unbounded queries -- every
/// Highlight in the library among them -- and filter them repeatedly inside
/// `body`: a full-table materialisation on the main actor for a screen whose
/// job is to say whether the store is healthy.
///
/// Moving that off the main actor stopped it blocking the UI but did not make
/// it quick, and on a real library (156 books, ~32,000 highlights) the screen
/// then sat on one spinner for seconds: "the dialnostic tab does not open
/// right awya it takes hellaa time to open looks liek the ap is slow". A
/// screen that is drawn but has nothing to say has not opened.
///
/// So the read is now staged by cost, cheapest first, and each stage publishes
/// as it lands:
///
///   0. the first frame does NO file or store IO at all;
///   1. `DiagnosticsProbe.counts()` -- every number that is one SQL `COUNT`,
///      which is the bulk of the screen;
///   2. `DiagnosticsProbe.integrity()` -- the three questions that genuinely
///      need rows, arriving into rows that are already laid out.
struct DiagnosticsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var counts: DiagnosticsCounts?
    @State private var integrity: DiagnosticsIntegrity?
    @State private var logEntryCount: Int?
    @State private var diskSpace: DiagnosticsDiskSpace?
    private let seedingStatus = SeedingStatus.shared

    var body: some View {
        List {
            if let counts {
                sections(for: counts, integrity: integrity)
            } else {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(seedingStatus.isSeeding ? "Waiting for your library to finish setting up…" : "Reading the store…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // EVIDENCE for "still not right away" (build 60). The last tab
            // switch and the last Flow open, measured from the tap to the
            // frame that shows the result (`SpeedTrace` -- `CACurrentMediaTime`
            // and an `os_signpost` interval each), which tabs the shell's
            // warm-up has built and when, the phone's class and its free
            // disk. Every row is `isHealthy: true` on purpose: these are
            // measurements to read, not marks to pass -- this screen grades
            // nothing (`checklist:nothing-grades-the-user`). Reads a
            // `UserDefaults` dictionary each; no store or file IO.
            Section("Speed") {
                diagnosticRow("Last tab switch", Self.describe(SpeedTrace.lastTabSwitch(), layout: true), isHealthy: true)
                diagnosticRow("Last Flow open", Self.describe(SpeedTrace.lastFlowOpen(), layout: false), isHealthy: true)
                diagnosticRow("Warmed tabs", Self.warmedTabsSummary(), isHealthy: true)
                diagnosticRow("Device class", DeviceClass.current.label, isHealthy: true)
                if let diskSpace {
                    diagnosticRow("Free disk", Self.formatBytes(diskSpace.free), isHealthy: true)
                } else {
                    pendingRow("Free disk")
                }
            }

            Section("Spend") {
                diagnosticRow("Estimated this month", String(format: "$%.2f", UsageTracker.currentMonthEstimate()), isHealthy: true)
            }

            // The People calibration row (build 62, `docs/people-in-the-journal.md`
            // §2 "Calibration before trust"): the two tiers as counts and the
            // last pass's duration, read from the indexer's report in
            // `UserDefaults.standard` -- never the app group. Counts only, no
            // names: this screen sits outside the journal's Face ID gate.
            // `isHealthy: true` on purpose -- a measurement, not a mark.
            Section("People") {
                if let report = PeopleIndexReport.read() {
                    diagnosticRow("Listed / Noticed", "\(report.listed) / \(report.noticed)", isHealthy: true)
                    diagnosticRow("Last pass", Self.peoplePassSummary(report), isHealthy: true)
                } else {
                    diagnosticRow("Last pass", "never", isHealthy: true)
                }
            }

            Section("Build") {
                diagnosticRow("Version", "\(Self.appVersion) (\(Self.appBuild))", isHealthy: true)
                diagnosticRow("TestFlight renews in", "\(BuildInfo.daysUntilExpiry) day(s)", isHealthy: BuildInfo.daysUntilExpiry > 14)
                // The rest of "recognize the devices of the users so that you
                // also know what's happening exactly" -- the same facts
                // `DiagnosticLog`'s header now stamps into the log itself,
                // shown here too so a look at the screen answers the question
                // without anyone having to share the log file first.
                diagnosticRow("Device", DiagnosticLog.modelIdentifier(), isHealthy: true)
                diagnosticRow("iOS", UIDevice.current.systemVersion, isHealthy: true)
                if let diskSpace {
                    // The concrete case this exists for: a tester's phone had
                    // 2.18 GB free of 119 GB while the app's Kokoro voice
                    // model alone is 327 MB -- a download that fails there
                    // fails outside this app's own code, so no debugger and
                    // no crash log inside Cobux would ever have shown it.
                    // 500 MB gives that model room plus headroom for iOS
                    // itself, which needs its own free space to operate at all.
                    diagnosticRow(
                        "Free disk",
                        "\(Self.formatBytes(diskSpace.free)) of \(Self.formatBytes(diskSpace.total))",
                        isHealthy: diskSpace.free > 500_000_000
                    )
                } else {
                    pendingRow("Free disk")
                }
                diagnosticRow("Memory", Self.formatBytes(Int64(ProcessInfo.processInfo.physicalMemory)), isHealthy: true)
                diagnosticRow(
                    "Thermal state",
                    Self.thermalStateLabel(ProcessInfo.processInfo.thermalState),
                    isHealthy: ProcessInfo.processInfo.thermalState == .nominal
                )
                // The widget's cycle tap, traced (58): his fourth report of
                // "clicking it does not change the highlight" could not be
                // answered because nothing recorded whether the tap reached the
                // intent at all. The widget writes when it last ran and what
                // happened; this row reads it back. "never" means no tap has
                // reached an intent since 58 was installed -- the Button layer.
                diagnosticRow(
                    "Widget tap",
                    Self.widgetTapSummary(),
                    isHealthy: Self.widgetTapSummary() != "never"
                )
            }

            // Always present, never gated on a crash existing first -- unlike
            // `CrashReportCollector`'s reports (which only ever appear after
            // something has already gone wrong), this log exists precisely so
            // there's real evidence to share BEFORE a bug reaches the point of
            // crashing, e.g. a seed that hangs instead of finishing.
            Section("Diagnostic Log") {
                if let logEntryCount {
                    diagnosticRow("Entries", "\(logEntryCount)", isHealthy: true)
                    if logEntryCount > 0 {
                        ShareLink(item: DiagnosticLog.fileURL) {
                            Label("Share Diagnostic Log", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    // A share sheet is the right shape for the whole file, but
                    // pasting a few facts and the recent tail straight into a
                    // message to Rajan is a smaller ask than attaching a file
                    // -- this is that path, not a replacement for the one above.
                    Button {
                        UIPasteboard.general.string = diagnosticsSummaryText()
                    } label: {
                        Label("Copy Diagnostics", systemImage: "doc.on.doc")
                    }
                } else {
                    pendingRow("Entries")
                }
            }
        }
        .navigationTitle("Diagnostics")
        // Never read the library while the background seed/upgrade merge is
        // in flight (the Build-5 crash class). Keyed on the flag so the probe
        // runs the moment the merge lands.
        .task(id: seedingStatus.isSeeding) {
            await load()
        }
    }

    /// Three publishes, cheapest first. `counts` is what fills the screen and
    /// it is all `fetchCount`, so it lands in a beat; `integrity` needs rows
    /// and arrives into rows that are already drawn, so nothing the user is
    /// waiting on is behind it.
    ///
    /// `@MainActor` explicitly, the way `JournalHighlightCard.buildDeck` is:
    /// this assigns `@State`, and a bare `async` method makes no promise about
    /// which actor it resumes on (SE-0338). The probe's own methods are
    /// actor-isolated on the `@ModelActor`, so awaiting them hops off main and
    /// nothing but a `Sendable` struct comes back -- no `@Model` object and no
    /// `ModelContext` crosses.
    @MainActor
    private func load() async {
        guard !seedingStatus.isSeeding else { return }
        // Reading the log file is IO too, and it belongs to no actor, so it
        // runs alongside the store work rather than in front of it. Detached
        // for the reason `EbbView.build()` is: this must actually leave the
        // main actor.
        let logCount = Task.detached(priority: .utility) { DiagnosticLog.entryCount() }
        // `resourceValues(forKeys:)` below is a real syscall against the
        // volume, not a cached property -- detached for the same reason the
        // log count is: this screen already learned once, the slow way, what
        // "never on the main thread" is for.
        let disk = Task.detached(priority: .utility) { Self.readDiskSpace() }
        let probe = DiagnosticsProbe(modelContainer: modelContext.container)
        counts = await probe.counts()
        logEntryCount = await logCount.value
        diskSpace = await disk.value
        integrity = await probe.integrity()
    }

    /// Off the main actor by construction (`Task.detached`, called only from
    /// `load()` above) -- `.volumeAvailableCapacityForImportantUsageKey` asks
    /// the filesystem, not a cache.
    private static func readDiskSpace() -> DiagnosticsDiskSpace? {
        guard let home = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let values = try? home.resourceValues(forKeys: [
                  .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey
              ])
        else { return nil }
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        let total = Int64(values.volumeTotalCapacity ?? 0)
        return DiagnosticsDiskSpace(free: free, total: total)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    /// Reads the widget process's tap trace out of the app group. Kept in
    /// sync by key with `WidgetHighlightHistory.trace` in the widget target,
    /// which this target does not compile.
    static func widgetTapSummary() -> String {
        let defaults = CobuxSchema.groupDefaults
        guard let at = defaults.object(forKey: "widgetTap.lastAt") as? Date,
              let outcome = defaults.string(forKey: "widgetTap.outcome") else { return "never" }
        return "\(outcome) · \(at.formatted(.relative(presentation: .named)))"
    }

    /// "Chat → Library (tap) · 14 ms to frame, layout 9 ms · 2 min ago".
    /// A tab-switch sample with no layout time means the incoming tab's
    /// warm layout was reused unchanged -- said in words, because that
    /// absence is the warm-up doing its job.
    /// "0.66 s · 246 entries · 3 min ago". Built once per body from a
    /// dictionary read; the relative formatter is hoisted like every other
    /// formatter on this screen.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static func peoplePassSummary(_ report: PeopleIndexReport) -> String {
        let seconds = String(format: report.durationSeconds < 1 ? "%.2f s" : "%.1f s", report.durationSeconds)
        let scanned = report.scanned == 1 ? "1 entry" : "\(report.scanned) entries"
        guard report.date > .distantPast else { return "\(seconds) · \(scanned)" }
        return "\(seconds) · \(scanned) · \(relativeFormatter.localizedString(for: report.date, relativeTo: .now))"
    }

    @MainActor
    private static func describe(_ sample: SpeedTrace.Sample?, layout: Bool) -> String {
        guard let sample else { return "not yet" }
        var parts = ["\(sample.label) · \(Int(sample.frameMs.rounded())) ms to frame"]
        if layout {
            if let layoutMs = sample.layoutMs {
                parts[0] += ", layout \(Int(layoutMs.rounded())) ms"
            } else {
                parts[0] += ", layout reused"
            }
        }
        parts.append(sample.at.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    @MainActor
    private static func warmedTabsSummary() -> String {
        let warmed = SpeedTrace.warmedTabs()
        return warmed.isEmpty ? "not yet this launch" : warmed.joined(separator: ", ")
    }


    private static func thermalStateLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    /// The facts in the Build section plus the log's own tail, as plain text
    /// -- everything a "what's happening exactly" question needs, sized to
    /// paste into a message rather than attach as a file.
    @MainActor
    private func diagnosticsSummaryText() -> String {
        var lines = [
            "Cobux \(Self.appVersion) (\(Self.appBuild))",
            "Device: \(DiagnosticLog.modelIdentifier()), iOS \(UIDevice.current.systemVersion)",
        ]
        if let diskSpace {
            lines.append("Free disk: \(Self.formatBytes(diskSpace.free)) of \(Self.formatBytes(diskSpace.total))")
        }
        lines.append("Memory: \(Self.formatBytes(Int64(ProcessInfo.processInfo.physicalMemory)))")
        lines.append("Thermal state: \(Self.thermalStateLabel(ProcessInfo.processInfo.thermalState))")
        lines.append("Device class: \(DeviceClass.current.label)")
        lines.append("Last tab switch: \(Self.describe(SpeedTrace.lastTabSwitch(), layout: true))")
        lines.append("Last Flow open: \(Self.describe(SpeedTrace.lastFlowOpen(), layout: false))")
        lines.append("Warmed tabs: \(Self.warmedTabsSummary())")
        lines.append("")
        lines.append("--- Recent log ---")
        lines.append(contentsOf: DiagnosticLog.recentEntries().prefix(20).reversed())
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func sections(for counts: DiagnosticsCounts, integrity: DiagnosticsIntegrity?) -> some View {
        Section("Embeddings") {
            diagnosticRow("Backfilled", "\(counts.embeddedCount) / \(counts.highlightCount)", isHealthy: counts.embeddedCount == counts.highlightCount)
        }

        Section("Chapter Join Integrity") {
            if let integrity {
                diagnosticRow("chapterRef backfilled", "\(integrity.chapterRefResolved) / \(integrity.chapterRefTotal)", isHealthy: integrity.chapterRefResolved == integrity.chapterRefTotal)
                // A trailing "+" when the scan stopped short, so the number is
                // never read as a total it isn't.
                diagnosticRow("Orphaned highlights", integrity.orphanScanWasCapped ? "\(integrity.orphanCount)+" : "\(integrity.orphanCount)", isHealthy: integrity.orphanCount == 0)
                ForEach(Array(integrity.orphans.enumerated()), id: \.offset) { _, orphan in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(orphan.bookTitle).font(.caption).fontWeight(.semibold)
                        Text("\"\(orphan.chapter)\" matches no chapter title")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if integrity.orphanCount > integrity.orphans.count {
                    Text("+ \(integrity.orphanCount - integrity.orphans.count) more").font(.caption2).foregroundStyle(.secondary)
                }
                if integrity.orphanScanWasCapped {
                    // Said out loud rather than folded into the number. A
                    // truncated integrity check that reads like a whole one is
                    // worse than a slow screen.
                    Text("Checked over the \(DiagnosticsIntegrity.scanLimit.formatted()) most recently added unlinked highlights. The ratio above is the whole library.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                pendingRow("chapterRef backfilled")
                pendingRow("Orphaned highlights")
            }
        }

        Section("Duplicate IDs") {
            if let integrity {
                diagnosticRow("Book", "\(integrity.duplicateBookIDs)", isHealthy: integrity.duplicateBookIDs == 0)
                diagnosticRow("Highlight", "\(integrity.duplicateHighlightIDs)", isHealthy: integrity.duplicateHighlightIDs == 0)
                diagnosticRow("Theme", "\(integrity.duplicateThemeIDs)", isHealthy: integrity.duplicateThemeIDs == 0)
                if integrity.duplicateScanWasCapped {
                    Text("Highlights and themes are checked over the \(DiagnosticsIntegrity.scanLimit.formatted()) most recently added of each — where a duplicate written by a seed, import or restore lands.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                pendingRow("Book")
                pendingRow("Highlight")
                pendingRow("Theme")
            }
        }

        Section("Chat") {
            diagnosticRow("General thread", "\(counts.generalThreadMessages) messages", isHealthy: true)
            diagnosticRow("Book-scoped threads", "\(counts.bookScopedMessages) messages", isHealthy: true)
        }

        Section("Quiz") {
            diagnosticRow("Questions generated", "\(counts.quizQuestionCount)", isHealthy: true)
            diagnosticRow("Highlights with review state", "\(counts.highlightMemoryCount) / \(counts.highlightCount)", isHealthy: true)
            diagnosticRow("Figures", "\(counts.figureCount)", isHealthy: true)
        }

        Section("FSRS Scheduling") {
            diagnosticRow("Never introduced (dueDate nil)", "\(counts.notIntroduced)", isHealthy: counts.notIntroduced == 0)
            diagnosticRow("New cards", "\(counts.newCards)", isHealthy: true)
            diagnosticRow("Due now", "\(counts.dueNow)", isHealthy: true)
            diagnosticRow("Scheduled ahead", "\(counts.scheduledAhead)", isHealthy: true)
            diagnosticRow("Suspended", "\(counts.suspended)", isHealthy: true)
            if let integrity {
                if let average = integrity.averageDaysUntilNextReview {
                    diagnosticRow("Avg. days to next review", String(format: "%.1f", average), isHealthy: true)
                }
            } else if counts.scheduledAhead > 0 {
                // Only when there is something scheduled, so the row appears
                // exactly where it will settle instead of popping in.
                pendingRow("Avg. days to next review")
            }
        }
    }

    /// `static let`, not a computed property: `Bundle.main.infoDictionary` is
    /// fixed for the life of the process, and these were two dictionary
    /// lookups per body evaluation on a screen that now evaluates its body
    /// three times as each stage lands.
    private static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    private static let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"

    @ViewBuilder
    private func diagnosticRow(_ label: String, _ value: String, isHealthy: Bool) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(isHealthy ? Color.secondary : Color.cobuxWarning)
                .fontWeight(isHealthy ? .regular : .semibold)
        }
    }

    /// A row whose number is still being worked out, in the same shape as a
    /// finished one so the list does not reflow when it lands. A bare
    /// `ProgressView` is this app's loading idiom everywhere (Settings'
    /// restore and import rows, Volumes, Flow); this is that idiom in the
    /// value slot.
    private func pendingRow(_ label: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            ProgressView()
        }
    }
}

/// Stage one: every number the store can answer with a `fetchCount` -- one SQL
/// `COUNT` each, no rows read, no objects registered. This is most of the
/// screen, and on the real library it is the difference between the numbers
/// arriving in a beat and arriving after the slowest question in the app.
struct DiagnosticsCounts: Sendable {
    var highlightCount = 0
    var embeddedCount = 0
    var generalThreadMessages = 0
    var bookScopedMessages = 0
    var quizQuestionCount = 0
    var highlightMemoryCount = 0
    var figureCount = 0
    var notIntroduced = 0
    var newCards = 0
    var dueNow = 0
    var scheduledAhead = 0
    var suspended = 0
}

/// The volume's free/total capacity, read off the main actor by
/// `DiagnosticsView.readDiskSpace()` -- a plain value so it can cross back
/// onto `@State` without carrying a `URL` or `FileManager` with it.
struct DiagnosticsDiskSpace: Sendable {
    let free: Int64
    let total: Int64
}

/// Stage two: the three questions that genuinely need rows and not counts --
/// the chapter join, duplicate ids, and the mean next-review interval. Built
/// off the main actor by `DiagnosticsProbe`; nothing here is a model object.
struct DiagnosticsIntegrity: Sendable {
    struct Orphan: Sendable {
        let bookTitle: String
        let chapter: String
    }

    /// How many rows a row-level scan will read before it stops.
    ///
    /// Every question in this struct except the book one is O(table) by
    /// nature: there is no `COUNT` that finds a duplicate id, and no `COUNT`
    /// that tells a stale free-text chapter from a live one. Uncapped, that
    /// meant reading all ~32,000 `Highlight` rows -- each carrying its full
    /// text and its embedding vector -- on the load path of a screen, twice.
    /// Capped and ordered newest-first it reads a bounded slice of the rows
    /// where a freshly written defect actually lands, and the screen says so
    /// whenever the cap binds.
    static let scanLimit = 5_000

    var chapterRefResolved = 0
    var chapterRefTotal = 0
    /// The first ten, for display; `orphanCount` is the total over what was
    /// scanned, and `orphanScanWasCapped` says whether that was everything.
    var orphans: [Orphan] = []
    var orphanCount = 0
    var orphanScanWasCapped = false
    var duplicateBookIDs = 0
    var duplicateHighlightIDs = 0
    var duplicateThemeIDs = 0
    var duplicateScanWasCapped = false
    var averageDaysUntilNextReview: Double?
}

/// Reads the store off the main actor, in two passes: `counts()` first, then
/// `integrity()`. Counts are `fetchCount` wherever the question is a count;
/// the few places that need rows fetch newest-first with a `fetchLimit`.
@ModelActor
actor DiagnosticsProbe {
    func counts() -> DiagnosticsCounts {
        var result = DiagnosticsCounts()
        let now = Date.now
        let distantPast = Date.distantPast
        let distantFuture = Date.distantFuture

        result.highlightCount = count(FetchDescriptor<Highlight>())
        result.embeddedCount = count(FetchDescriptor<Highlight>(
            predicate: #Predicate { $0.embeddingData != nil }))

        result.generalThreadMessages = count(FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.bookID == nil }))
        result.bookScopedMessages = count(FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.bookID != nil }))

        result.quizQuestionCount = count(FetchDescriptor<QuizQuestion>())
        result.highlightMemoryCount = count(FetchDescriptor<HighlightMemory>())
        result.figureCount = count(FetchDescriptor<Figure>())

        // Never introduced into review at all -- would have caught the real
        // shipped bug where every freshly generated question had `dueDate ==
        // nil` and was therefore permanently invisible to Daily Review.
        // Should trend to 0 shortly after any chapter is quizzed; a number
        // that stays high and grows is exactly that bug back.
        result.notIntroduced = count(FetchDescriptor<QuizQuestion>(
            predicate: #Predicate { $0.dueDate == nil }))
        result.newCards = count(FetchDescriptor<QuizQuestion>(
            predicate: #Predicate { $0.fsrsReps == 0 && $0.dueDate != nil }))
        result.dueNow = count(FetchDescriptor<QuizQuestion>(
            predicate: #Predicate { !$0.isSuspended && ($0.dueDate ?? distantFuture) <= now }))
        result.suspended = count(FetchDescriptor<QuizQuestion>(
            predicate: #Predicate { $0.isSuspended }))
        // This was the LENGTH of a fetch of every scheduled question's row --
        // a whole table read to show one integer. The same predicate as a
        // `COUNT` is exactly as correct and reads nothing; only the mean below
        // still needs the dates themselves.
        result.scheduledAhead = count(FetchDescriptor<QuizQuestion>(
            predicate: #Predicate { !$0.isSuspended && ($0.dueDate ?? distantPast) > now }))

        return result
    }

    func integrity() -> DiagnosticsIntegrity {
        var result = DiagnosticsIntegrity()
        let now = Date.now
        let distantPast = Date.distantPast
        let limit = DiagnosticsIntegrity.scanLimit

        let books = (try? modelContext.fetch(FetchDescriptor<Book>())) ?? []

        // Every chapter title, keyed by its book, in ONE fetch. This used to
        // be `book.chapters` inside a loop over every book: one to-many fault
        // per book, each its own round trip, for data a single query already
        // has -- 156 of them on this library. The `book` back-reference costs
        // no further query, because the books above are already registered in
        // this context and the foreign key is in the chapter's own row.
        var titlesByBook: [UUID: Set<String>] = [:]
        for chapter in (try? modelContext.fetch(FetchDescriptor<Chapter>())) ?? [] {
            guard let bookID = chapter.book?.id else { continue }
            titlesByBook[bookID, default: []].insert(chapter.title)
        }

        // Mirrors the exact lookup `Book.highlights(in:)` performs -- a
        // highlight resolved by neither `chapterRef` nor the free-text
        // `chapter` string is invisible to that lookup (and therefore to
        // Quiz, which scopes by chapter) with no error raised anywhere. Only
        // books that actually have chapters are counted, so a book still
        // being authored without chapters yet doesn't falsely show every
        // highlight as unbackfilled.
        //
        // A highlight can only carry a non-nil `chapterRef` if its book has
        // chapters at all, so the store-wide count IS the chaptered-books
        // count: one `COUNT` in place of one per book.
        result.chapterRefResolved = count(FetchDescriptor<Highlight>(
            predicate: #Predicate<Highlight> { $0.chapterRef != nil }))
        // ...and the denominator is every highlight minus the ones the old
        // per-book loop never visited: highlights attached to no book, and
        // highlights in a book with no chapters yet. Books without chapters
        // are normally none, so this loop normally runs zero times -- where
        // the old shape ran two relationship-joined `COUNT`s against a
        // ~32,000-row table for each of 156 books before the screen could
        // show anything.
        var chapterRefTotal = count(FetchDescriptor<Highlight>())
        chapterRefTotal -= count(FetchDescriptor<Highlight>(
            predicate: #Predicate<Highlight> { $0.book == nil }))
        for book in books where titlesByBook[book.id] == nil {
            let bookID = book.id
            chapterRefTotal -= count(FetchDescriptor<Highlight>(
                predicate: #Predicate<Highlight> { $0.book?.id == bookID }))
        }
        result.chapterRefTotal = chapterRefTotal

        // The orphan detail, in one fetch of the unresolved rows rather than
        // one fetch per book. Newest first and capped, because the condition
        // this row exists to catch -- a `chapterRef` backfill that never ran
        // -- is exactly the condition under which "every unresolved
        // highlight" is the entire library, so an uncapped fetch here would
        // be at its slowest in the one case it matters most. The ratio above
        // is the unbounded truth; this names names.
        var unresolved = FetchDescriptor<Highlight>(
            predicate: #Predicate<Highlight> { $0.chapterRef == nil },
            sortBy: [SortDescriptor(\Highlight.dateAdded, order: .reverse)])
        unresolved.fetchLimit = limit
        let unresolvedRows = (try? modelContext.fetch(unresolved)) ?? []
        result.orphanScanWasCapped = unresolvedRows.count >= limit
        var orphans: [DiagnosticsIntegrity.Orphan] = []
        var orphanCount = 0
        for highlight in unresolvedRows {
            // No book, or a book with no chapters: not an orphan, exactly as
            // the per-book loop's `guard !chapterTitles.isEmpty` had it.
            guard let book = highlight.book, let chapterTitles = titlesByBook[book.id] else { continue }
            let chapterName = highlight.chapter ?? ""
            guard !chapterTitles.contains(chapterName) else { continue }
            orphanCount += 1
            if orphans.count < 10 {
                orphans.append(.init(bookTitle: book.title, chapter: chapterName))
            }
        }
        result.orphans = orphans
        result.orphanCount = orphanCount

        // Duplicate ids are the one question here with no `COUNT` that answers
        // them -- they need the ids themselves. Books are few, so that one is
        // whole; highlights and themes are the newest `scanLimit`, which is
        // where a duplicate written by a seed, an import or a restore lands
        // (`SeedRunner.repairDuplicateIDs` is the thing this row watches).
        result.duplicateBookIDs = duplicateIDs(books.map(\.id))

        var highlightIDs = FetchDescriptor<Highlight>(
            sortBy: [SortDescriptor(\Highlight.dateAdded, order: .reverse)])
        highlightIDs.fetchLimit = limit
        highlightIDs.propertiesToFetch = [\.id]
        let highlightRows = (try? modelContext.fetch(highlightIDs)) ?? []
        result.duplicateHighlightIDs = duplicateIDs(highlightRows.map(\.id))

        var themeIDs = FetchDescriptor<Theme>(
            sortBy: [SortDescriptor(\Theme.dateGenerated, order: .reverse)])
        themeIDs.fetchLimit = limit
        themeIDs.propertiesToFetch = [\.id]
        let themeRows = (try? modelContext.fetch(themeIDs)) ?? []
        result.duplicateThemeIDs = duplicateIDs(themeRows.map(\.id))
        result.duplicateScanWasCapped = highlightRows.count >= limit || themeRows.count >= limit

        // Mean days from now to each scheduled question's next review -- the
        // "next-interval predictions" the FSRS risk table promised
        // Diagnostics would expose, so a scheduler gone subtly wrong is a
        // number visible here, not something that only shows up as "the app
        // feels off" weeks later. Soonest first, so the capped slice is the
        // part of the schedule that is actually about to happen; the count of
        // scheduled cards itself is exact and comes from `counts()`.
        var scheduled = FetchDescriptor<QuizQuestion>(
            predicate: #Predicate { !$0.isSuspended && ($0.dueDate ?? distantPast) > now },
            sortBy: [SortDescriptor(\QuizQuestion.dueDate, order: .forward)])
        scheduled.fetchLimit = limit
        scheduled.propertiesToFetch = [\.dueDate]
        let futureDueDays = ((try? modelContext.fetch(scheduled)) ?? []).compactMap { question -> Double? in
            guard let due = question.dueDate else { return nil }
            return due.timeIntervalSince(now) / 86400
        }
        if !futureDueDays.isEmpty {
            result.averageDaysUntilNextReview = futureDueDays.reduce(0, +) / Double(futureDueDays.count)
        }

        return result
    }

    private func count<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> Int {
        (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    private func duplicateIDs(_ ids: [UUID]) -> Int {
        ids.count - Set(ids).count
    }
}
