import SwiftData
import Foundation

/// Fires the one silent, automatic restore a fresh install gets from
/// `AutoBackupService`'s snapshots -- see the approved backup/restore plan
/// for the full design rationale, in particular why a fully silent restore
/// is safe here: `BackupService.importData` is additive-only and can never
/// overwrite or delete a value the user already has, so the worst case is
/// "recovered data the user didn't need," never lost or corrupted data.
///
/// Surfaced through `AutoRestoreStatus` (a dismissible banner with Undo),
/// not a sheet -- `ContentView`'s launch-sheet chain already has three
/// participants and a documented history of one silently losing a race
/// against another; a fourth competitor would re-enter a bug already fixed
/// twice there.
enum AutoRestoreService {
    private static let defaults = UserDefaults.standard
    /// One-shot per install -- `UserDefaults` is wiped by an actual
    /// reinstall (re-arming this), never by clearing app data from inside
    /// Settings, so a deliberate in-app cleanup can't accidentally
    /// re-trigger a restore.
    private static let completedKey = "cobux.autoRestore.completed"
    /// Written once, durably, by `CobuxApp.seedDatabase` the very first time
    /// THIS install is ever seeded -- true only if the store was genuinely
    /// empty at that moment. This used to be inferred from the ABSENCE of
    /// `AutoBackupService`'s own throttle key, on the theory that a key only
    /// automatic backup ever writes is a good fresh-install proxy -- it
    /// isn't: that key is equally absent on every EXISTING install's first
    /// launch of a build that ships automatic backup for the first time
    /// (this exact cycle), and the two services also race each other
    /// writing/reading it. This flag is the real signal and can't drift.
    private static let wasFreshInstallKey = "cobux.install.wasFreshOnFirstSeed"
    /// `completedKey` is the one-shot ACROSS launches; this is the one-shot
    /// WITHIN a launch. Every guard below is synchronous, so two overlapping
    /// calls both cleared them before either reached the first `await`, both
    /// downloaded, and both imported -- and with an empty store the import's
    /// own dedup had nothing to match against, so the second pass re-inserted
    /// every entry under the SAME `id` as the first. That is the exact state
    /// `BackupService.repairDuplicateIDs` exists to clean up, now gated behind
    /// a repair-pass version, and the second `present(...)` overwrote the
    /// first restore's Undo identifiers, so Undo could only take the
    /// duplicates back out. On a fresh install -- the one launch this whole
    /// service exists for -- that overlap was the normal path, not a race.
    @MainActor private static var inFlight = false

    /// Call from the same seed-aware trigger points `WatchSyncService.sync`/
    /// `resolveLaunchSheets` already use in `ContentView` -- the cold-launch
    /// `.task` (covers "seed already finished by the time this runs") and
    /// the `wasSeeding && !isSeeding` transition (covers "seed finished
    /// later"). Never called from inside `seedDatabase` itself, which is
    /// already a large critical section with its own documented crash
    /// history and has no business waiting on iCloud I/O.
    @MainActor
    static func restoreIfNeeded(modelContext: ModelContext) async {
        guard !SeedingStatus.shared.isSeeding, !StoreHealthStatus.shared.isDegraded else { return }  // retries: ContentView's onChange(of: seedingStatus.isSeeding)
        guard !defaults.bool(forKey: completedKey) else { return }
        // `wasFreshInstallKey` is nil only if `seedDatabase` hasn't run even
        // once yet this launch (shouldn't happen given the `isSeeding` guard
        // above, but fail closed rather than open if it somehow does) --
        // `== true` is the only value that means "genuinely fresh."
        guard defaults.object(forKey: wasFreshInstallKey) as? Bool == true else { return }
        // Set before the first `await` and cleared on every exit -- see
        // `inFlight`'s own comment for what a second overlapping pass did.
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        guard storeIsUntouched(modelContext: modelContext) else { return }

        guard let documentsURL = await UbiquityContainer.shared.documentsURL() else { return }
        let backupsDir = documentsURL.appendingPathComponent("Backups", isDirectory: true)
        guard let manifest = BackupSnapshotManifest.read(from: backupsDir),
              manifest.bookCount > 0 || manifest.personalWritingEntryCount > 0 else { return }

        let snapshotURL = backupsDir.appendingPathComponent(manifest.latestFilename)
        // Leaves `completedKey` false on a download timeout -- the next
        // launch's opportunistic call simply tries again, rather than
        // burning the one-shot on a transient iCloud delay.
        guard await UbiquityContainer.shared.waitForDownload(of: snapshotURL) else { return }
        guard let data = try? Data(contentsOf: snapshotURL) else { return }

        // Re-checked AFTER the awaits, not only before them. `inFlight` stops
        // a second concurrent pass, but the iCloud download is long enough
        // that a completed restore from an earlier launch state, or the user
        // writing his first entry while it ran, can both land in between --
        // and either makes this import the wrong thing to do.
        guard !defaults.bool(forKey: completedKey) else { return }
        guard storeIsUntouched(modelContext: modelContext) else { return }

        let existingBooks = (try? modelContext.fetch(FetchDescriptor<Book>())) ?? []
        let existingQuizAttempts = (try? modelContext.fetch(FetchDescriptor<QuizAttempt>())) ?? []
        // Passed even though the guards above just proved both are empty:
        // `importData` dedupes entries and messages ONLY against what it is
        // handed, so omitting them made this call structurally incapable of
        // recognising a row it had already imported. Fetching them costs one
        // empty fetch on the path that matters and removes the whole class.
        let existingChatMessages = (try? modelContext.fetch(FetchDescriptor<ChatMessage>())) ?? []
        let existingPersonalWritingEntries = (try? modelContext.fetch(FetchDescriptor<PersonalWritingEntry>())) ?? []
        guard let result = try? BackupService.importData(
            data,
            existingBooks: existingBooks,
            existingChatMessages: existingChatMessages,
            existingPersonalWritingEntries: existingPersonalWritingEntries,
            existingQuizAttempts: existingQuizAttempts,
            modelContext: modelContext
        ) else { return }

        defaults.set(true, forKey: completedKey)
        AutoRestoreStatus.shared.present(
            summary: summaryText(for: result),
            identifiers: result.insertedIdentifiers.isEmpty ? nil : result.insertedIdentifiers
        )

        // A restore is exactly the "rows with a nil embedding" case these
        // two passes already exist to backfill -- run them now rather than
        // leaving a just-recovered library only keyword-searchable until the
        // next cold launch.
        let container = modelContext.container
        await CobuxApp.backfillEmbeddingsAndReindex(container: container)
        await CobuxApp.backfillPersonalWritingEmbeddings(container: container)
    }

    /// The real guard against restoring over a deliberately-cleared local
    /// state: zero personal-writing entries, zero chat messages, and no
    /// highlight carries a real personal note -- reusing the exact "genuine
    /// user authorship" signal `CobuxApp.dedupeDuplicateBooks` already
    /// established (which explicitly rejects `isReminder` as too weak a
    /// signal for the same reason). Factored out of `restoreIfNeeded` so the
    /// same three checks can run again after the iCloud awaits, which is the
    /// only place a decision this old can go stale.
    @MainActor
    private static func storeIsUntouched(modelContext: ModelContext) -> Bool {
        let personalWritingCount = (try? modelContext.fetchCount(FetchDescriptor<PersonalWritingEntry>())) ?? 0
        guard personalWritingCount == 0 else { return false }
        let chatCount = (try? modelContext.fetchCount(FetchDescriptor<ChatMessage>())) ?? 0
        guard chatCount == 0 else { return false }
        // Plain `!= nil` + `!=` rather than `($0.personalNote ?? "") != ""` --
        // this codebase's other `#Predicate` uses (BookCard.swift,
        // WidgetHighlightPool.swift) all avoid nil-coalescing inside the
        // macro for the same documented reason: unverified whether `??`
        // converts cleanly to `NSPredicate` or traps at fetch time. Optional
        // chaining/comparison (`?.`, `!= nil`) is the proven-safe form here.
        let notedHighlightCount = (try? modelContext.fetchCount(
            FetchDescriptor<Highlight>(predicate: #Predicate { $0.personalNote != nil && $0.personalNote != "" })
        )) ?? 0
        return notedHighlightCount == 0
    }

    /// Names everything a restore actually brought back. Chat messages and
    /// situation threads used to be missing from this list even though the
    /// import counts both, so a restore whose recovered content was a
    /// conversation read as "Restored your Cobux backup from iCloud." with
    /// nothing named -- the banner understating what had just happened on the
    /// one screen he had to judge it from.
    private static func summaryText(for result: BackupService.ImportResult) -> String {
        var parts: [String] = []
        if result.personalWritingEntriesImported > 0 {
            parts.append("\(result.personalWritingEntriesImported) journal \(result.personalWritingEntriesImported == 1 ? "entry" : "entries")")
        }
        if result.chatMessagesImported > 0 {
            parts.append("\(result.chatMessagesImported) chat \(result.chatMessagesImported == 1 ? "message" : "messages")")
        }
        if result.situationsImported > 0 {
            parts.append("\(result.situationsImported) situation \(result.situationsImported == 1 ? "thread" : "threads")")
        }
        if result.booksImported > 0 {
            parts.append("\(result.booksImported) \(result.booksImported == 1 ? "book" : "books")")
        }
        if result.quizAttemptsImported > 0 {
            parts.append("\(result.quizAttemptsImported) quiz \(result.quizAttemptsImported == 1 ? "attempt" : "attempts")")
        }
        if result.journalKeepsImported > 0 {
            parts.append("\(result.journalKeepsImported) held \(result.journalKeepsImported == 1 ? "passage" : "passages")")
        }
        if result.highlightMemoriesImported > 0 || result.quizQuestionsImported > 0 || result.booksMerged > 0 {
            parts.append("your saved progress")
        }
        if parts.isEmpty {
            return "Restored your Cobux backup from iCloud."
        }
        return "Restored from your iCloud backup: " + parts.joined(separator: ", ") + "."
    }

    /// Resumable, independent of the one-shot restore above -- copies in any
    /// sidecar photo whose `JournalAttachment` row exists locally (restored
    /// with the sidecar's own id, see `BackupService.importData`'s
    /// `.sidecar` branch) but whose file hasn't arrived on this device yet.
    /// Self-healing by construction: a mid-download kill just leaves that
    /// row's file missing for the next opportunistic call to pick back up,
    /// rather than depending on a fragile one-shot flag.
    @MainActor
    static func downloadPendingAttachments(modelContext: ModelContext) async {
        let missing = (try? modelContext.fetch(FetchDescriptor<JournalAttachment>())) ?? []
        // By id, not by extension: a voice note present on disk has no .jpg, so the
        // old check classified it as forever-pending and this pass never settled.
        let pending = missing.filter { JournalAttachmentStore.existingFileURL(for: $0.id) == nil }
        guard !pending.isEmpty else { return }
        guard let documentsURL = await UbiquityContainer.shared.documentsURL() else { return }
        let attachmentsDir = documentsURL.appendingPathComponent("Backups", isDirectory: true).appendingPathComponent("Attachments", isDirectory: true)

        for attachment in pending {
            // Try each known kind. This asked iCloud only for `<id>.jpg`, so a
            // voice note -- uploaded as .m4a -- was never even requested, and
            // the row came back on a new phone pointing at nothing.
            // `restore` sniffs the container itself, so the extension we happen
            // to find it under never decides how it is written back.
            for ext in JournalAttachmentStore.knownExtensions {
                let sourceURL = attachmentsDir.appendingPathComponent(attachment.id.uuidString + "." + ext)
                guard await UbiquityContainer.shared.waitForDownload(of: sourceURL, timeout: 15),
                      let data = try? Data(contentsOf: sourceURL) else { continue }
                JournalAttachmentStore.restore(data, id: attachment.id)
                break
            }
        }
    }
}

/// Dismissible banner state for a completed auto-restore -- rendered in
/// `ContentView`'s existing `.overlay`, alongside the milestone celebration,
/// deliberately not a sheet (see this file's own doc comment).
@MainActor
@Observable
final class AutoRestoreStatus {
    static let shared = AutoRestoreStatus()
    private init() {}

    var summary: String?
    private var identifiers: BackupService.InsertedIdentifiers?

    var canUndo: Bool { identifiers != nil }

    func present(summary: String, identifiers: BackupService.InsertedIdentifiers?) {
        self.summary = summary
        self.identifiers = identifiers
    }

    func dismiss() {
        summary = nil
        identifiers = nil
    }

    /// Precise: deletes exactly what the restore inserted and he has not made
    /// his since -- see `BackupService.undoImport`'s own doc comment. Whatever
    /// it kept replaces the restore summary, with Undo gone, so the banner
    /// never implies a wholesale revert that did not happen; the X dismisses
    /// that notice like any other.
    func undo(modelContext: ModelContext) {
        guard let identifiers else { return }
        let outcome = BackupService.undoImport(identifiers, modelContext: modelContext)
        guard outcome.keptAnything else {
            dismiss()
            return
        }
        self.identifiers = nil
        summary = Self.keptSummary(outcome)
    }

    private static func keptSummary(_ outcome: BackupService.UndoResult) -> String {
        var parts: [String] = []
        if outcome.entriesKept > 0 {
            parts.append("\(outcome.entriesKept) journal \(outcome.entriesKept == 1 ? "entry" : "entries") you had written in since")
        }
        if outcome.situationsKept > 0 {
            parts.append("\(outcome.situationsKept) situation \(outcome.situationsKept == 1 ? "thread" : "threads") you had continued")
        }
        if parts.isEmpty {
            return "Restore undone."
        }
        return "Restore undone. Kept " + parts.joined(separator: " and ") + "."
    }
}
