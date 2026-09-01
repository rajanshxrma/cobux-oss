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

    /// Call from the same seed-aware trigger points `WatchSyncService.sync`/
    /// `resolveLaunchSheets` already use in `ContentView` -- the cold-launch
    /// `.task` (covers "seed already finished by the time this runs") and
    /// the `wasSeeding && !isSeeding` transition (covers "seed finished
    /// later"). Never called from inside `seedDatabase` itself, which is
    /// already a large critical section with its own documented crash
    /// history and has no business waiting on iCloud I/O.
    @MainActor
    static func restoreIfNeeded(modelContext: ModelContext) async {
        guard !SeedingStatus.shared.isSeeding, !StoreHealthStatus.shared.isDegraded else { return }
        guard !defaults.bool(forKey: completedKey) else { return }
        // `wasFreshInstallKey` is nil only if `seedDatabase` hasn't run even
        // once yet this launch (shouldn't happen given the `isSeeding` guard
        // above, but fail closed rather than open if it somehow does) --
        // `== true` is the only value that means "genuinely fresh."
        guard defaults.object(forKey: wasFreshInstallKey) as? Bool == true else { return }

        // The real guard against restoring over a deliberately-cleared local
        // state: zero personal-writing entries, zero chat messages, and no
        // highlight carries a real personal note -- reusing the exact
        // "genuine user authorship" signal `CobuxApp.dedupeDuplicateBooks`
        // already established (which explicitly rejects `isReminder` as too
        // weak a signal for the same reason).
        let personalWritingCount = (try? modelContext.fetchCount(FetchDescriptor<PersonalWritingEntry>())) ?? 0
        guard personalWritingCount == 0 else { return }
        let chatCount = (try? modelContext.fetchCount(FetchDescriptor<ChatMessage>())) ?? 0
        guard chatCount == 0 else { return }
        // Plain `!= nil` + `!=` rather than `($0.personalNote ?? "") != ""` --
        // this codebase's other `#Predicate` uses (BookCard.swift,
        // WidgetHighlightPool.swift) all avoid nil-coalescing inside the
        // macro for the same documented reason: unverified whether `??`
        // converts cleanly to `NSPredicate` or traps at fetch time. Optional
        // chaining/comparison (`?.`, `!= nil`) is the proven-safe form here.
        let notedHighlightCount = (try? modelContext.fetchCount(
            FetchDescriptor<Highlight>(predicate: #Predicate { $0.personalNote != nil && $0.personalNote != "" })
        )) ?? 0
        guard notedHighlightCount == 0 else { return }

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

        let existingBooks = (try? modelContext.fetch(FetchDescriptor<Book>())) ?? []
        let existingQuizAttempts = (try? modelContext.fetch(FetchDescriptor<QuizAttempt>())) ?? []
        guard let result = try? BackupService.importData(
            data,
            existingBooks: existingBooks,
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

    private static func summaryText(for result: BackupService.ImportResult) -> String {
        var parts: [String] = []
        if result.personalWritingEntriesImported > 0 {
            parts.append("\(result.personalWritingEntriesImported) journal \(result.personalWritingEntriesImported == 1 ? "entry" : "entries")")
        }
        if result.booksImported > 0 {
            parts.append("\(result.booksImported) \(result.booksImported == 1 ? "book" : "books")")
        }
        if result.quizAttemptsImported > 0 {
            parts.append("\(result.quizAttemptsImported) quiz \(result.quizAttemptsImported == 1 ? "attempt" : "attempts")")
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
        let pending = missing.filter { !FileManager.default.fileExists(atPath: JournalAttachmentStore.fileURL(for: $0.id).path) }
        guard !pending.isEmpty else { return }
        guard let documentsURL = await UbiquityContainer.shared.documentsURL() else { return }
        let attachmentsDir = documentsURL.appendingPathComponent("Backups", isDirectory: true).appendingPathComponent("Attachments", isDirectory: true)

        for attachment in pending {
            let sourceURL = attachmentsDir.appendingPathComponent(attachment.id.uuidString + ".jpg")
            guard await UbiquityContainer.shared.waitForDownload(of: sourceURL, timeout: 15) else { continue }
            guard let data = try? Data(contentsOf: sourceURL) else { continue }
            JournalAttachmentStore.restore(data, id: attachment.id)
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

    /// Precise: deletes exactly what the restore inserted, nothing else --
    /// see `BackupService.undoImport`'s own doc comment.
    func undo(modelContext: ModelContext) {
        guard let identifiers else { return }
        BackupService.undoImport(identifiers, modelContext: modelContext)
        dismiss()
    }
}
