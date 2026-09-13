import SwiftData
import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

/// Silent, automatic, private-to-the-user protection against ever losing
/// Cobux data -- see "Cobux: pre-final-build audit, real backup/restore, and
/// a Journal redesign" (the approved plan this ships from) for the full
/// design rationale. Reuses `BackupService.exportData`/`importData` as the
/// one serializer/deserializer for both the manual "share this file" export
/// and this automatic path -- never a second implementation of the same
/// thing.
///
/// Three real risks this specifically guards against, each with its own
/// concrete counter-measure below:
/// 1. **A bad write destroying the only copy.** Never a single overwritten
///    file -- up to `maxSnapshots` rotating, atomically-written snapshots.
/// 2. **Silently backing up emptiness.** Hard-aborts on an empty store, and
///    skips pruning (never skips backing up) on a sharp count drop, so a
///    real cleanup doesn't cost the history that would tell it apart from
///    corruption.
/// 3. **Wasting bandwidth/storage on unchanged data.** A SHA256 digest of
///    the encoded snapshot gates both the write AND the rotation -- three
///    quiet days in a row must not evict your last three genuinely
///    *distinct* states.
enum AutoBackupService {
    private static let defaults = UserDefaults.standard
    private static let lastBackupDateKey = "cobux.autoBackup.lastBackupDate"
    private static let lastDigestKey = "cobux.autoBackup.lastDigest"
    /// Same cadence as `JournalAutoExportService` -- this mirrors a daily
    /// cadence, not a live sync, so there's no value running more often.
    private static let minimumInterval: TimeInterval = 20 * 60 * 60
    private static let maxSnapshots = 3
    /// Spreads a large first-run photo backlog across a few launches rather
    /// than stalling one -- `manifest.attachmentsPending` tracks the rest.
    private static let maxAttachmentsPerRun = 50

    /// Reads the manifest only -- cheap, for Settings' "Last automatic
    /// backup" row and the digest/count comparisons below, without ever
    /// touching the real (multi-MB) snapshot file.
    static func currentManifest() async -> BackupSnapshotManifest? {
        guard let documentsURL = await UbiquityContainer.shared.documentsURL() else { return nil }
        return BackupSnapshotManifest.read(from: backupsDirectory(in: documentsURL))
    }

    private static func backupsDirectory(in documentsURL: URL) -> URL {
        documentsURL.appendingPathComponent("Backups", isDirectory: true)
    }

    /// Call opportunistically on launch/background/post-seed transitions,
    /// same call sites `JournalAutoExportService.exportIfNeeded` already
    /// uses. Gates cheaply and synchronously on the main actor (seeding/
    /// degraded-store checks, the throttle) before ever touching iCloud or
    /// walking the whole library -- the real work happens in a detached
    /// task against its OWN fresh `ModelContext`, never the caller's.
    @MainActor
    static func backupIfNeeded(modelContext: ModelContext) {
        guard !SeedingStatus.shared.isSeeding, !StoreHealthStatus.shared.isDegraded else { return }  // retries: ContentView's onChange(of: seedingStatus.isSeeding)
        if let last = defaults.object(forKey: lastBackupDateKey) as? Date,
           Date.now.timeIntervalSince(last) < minimumInterval {
            return
        }

        let container = modelContext.container

        #if canImport(UIKit)
        // The background-transition trigger can suspend the app before an
        // async write finishes -- `JournalAutoExportService`'s old
        // synchronous version implicitly completed before suspension; this
        // one won't, and a half-finished write on the "data cannot be lost"
        // path is the wrong trade. `.invalid` sentinel + a matching guard in
        // the completion closure keeps a double-end call harmless.
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "CobuxAutoBackup") {
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }
        #endif

        Task.detached(priority: .utility) {
            await performBackup(container: container)
            #if canImport(UIKit)
            await MainActor.run {
                if backgroundTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                    backgroundTaskID = .invalid
                }
            }
            #endif
        }
    }

    private static func performBackup(container: ModelContainer) async {
        guard let documentsURL = await UbiquityContainer.shared.documentsURL() else { return }
        let backupsDir = backupsDirectory(in: documentsURL)
        let attachmentsDir = backupsDir.appendingPathComponent("Attachments", isDirectory: true)

        // Own context, never the caller's -- this fetch+encode is
        // potentially multi-MB at real scale, the exact reason
        // `CobuxApp.backfillEmbeddingsAndReindex` establishes this same
        // "detached task, fresh ModelContext" pattern.
        let context = ModelContext(container)
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        let chatMessages = (try? context.fetch(FetchDescriptor<ChatMessage>())) ?? []
        let personalWritingEntries = (try? context.fetch(FetchDescriptor<PersonalWritingEntry>())) ?? []
        let quizAttempts = (try? context.fetch(FetchDescriptor<QuizAttempt>())) ?? []
        let journalKeeps = (try? context.fetch(FetchDescriptor<JournalKeep>())) ?? []
        let journalPeople = (try? context.fetch(FetchDescriptor<JournalPerson>())) ?? []
        let situations = (try? context.fetch(FetchDescriptor<SituationThread>())) ?? []

        // Never write an empty snapshot -- a degraded/in-memory store or a
        // launch-time race shouldn't ever get to overwrite real history with
        // emptiness. (The `!isDegraded` gate above already covers the known
        // degraded case; this is the belt to that suspenders.)
        guard !books.isEmpty || !personalWritingEntries.isEmpty else { return }

        guard let data = try? BackupService.exportData(
            books: books,
            chatMessages: chatMessages,
            personalWritingEntries: personalWritingEntries,
            quizAttempts: quizAttempts,
            journalKeeps: journalKeeps,
            situations: situations,
            journalPeople: journalPeople,
            attachmentPolicy: .sidecar
        ) else { return }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if digest == defaults.string(forKey: lastDigestKey) {
            // Unchanged since last run -- bump the throttle timestamp so the
            // next opportunistic call waits the full interval again, but
            // skip the write and rotation entirely. This is what makes
            // "keep the last 3 snapshots" mean "your last 3 DISTINCT
            // states," not "whatever happened to still exist after three
            // quiet days evicted the real history."
            defaults.set(Date.now, forKey: lastBackupDateKey)
            return
        }

        try? FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)

        let previousManifest = BackupSnapshotManifest.read(from: backupsDir)
        // A sharp drop (or a nonzero-to-zero collapse) is a reason to KEEP
        // history longer, never a reason to stop backing up -- the write
        // below always happens; only pruning is conditionally skipped.
        let shrankSharply = hasShrunkSharply(
            newBookCount: books.count, previousBookCount: previousManifest?.bookCount,
            newEntryCount: personalWritingEntries.count, previousEntryCount: previousManifest?.personalWritingEntryCount
        )

        // Not a render path and not a loop: `performBackup` writes ONE snapshot
        // per run, on a detached off-main task, throttled to an interval. One
        // formatter is built per backup, for one filename. Hoisting it would
        // also put a shared `ISO8601DateFormatter` behind a background caller,
        // which is the opposite of the condition `ChatView`'s pair documents.
        // lint-ok: formatter-constructed-per-render -- once per backup run, off-main, for a single filename
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let filename = "cobux-backup-\(stamp).json"
        let fileURL = backupsDir.appendingPathComponent(filename)

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return
        }

        let (attachmentsCopiedThisRun, attachmentsPending) = syncAttachmentSidecars(
            personalWritingEntries: personalWritingEntries, attachmentsDir: attachmentsDir
        )
        _ = attachmentsCopiedThisRun

        // Prune ONLY after the new write succeeds -- makes "deleted the old
        // one, then failed to write the new one" structurally impossible.
        if !shrankSharply {
            pruneOldSnapshots(in: backupsDir, keeping: maxSnapshots)
        }
        pruneOrphanAttachments(backupsDir: backupsDir, attachmentsDir: attachmentsDir)

        defaults.set(digest, forKey: lastDigestKey)
        defaults.set(Date.now, forKey: lastBackupDateKey)

        BackupSnapshotManifest(
            schemaVersion: 1,
            latestFilename: filename,
            latestDigest: digest,
            latestDate: .now,
            bookCount: books.count,
            personalWritingEntryCount: personalWritingEntries.count,
            attachmentsPending: attachmentsPending,
            personCount: journalPeople.count
        ).write(to: backupsDir)
    }

    private static func hasShrunkSharply(newBookCount: Int, previousBookCount: Int?, newEntryCount: Int, previousEntryCount: Int?) -> Bool {
        if let previousBookCount, previousBookCount > 0 {
            if newBookCount == 0 || newBookCount < previousBookCount / 2 { return true }
        }
        if let previousEntryCount, previousEntryCount > 0 {
            if newEntryCount == 0 || newEntryCount < previousEntryCount / 2 { return true }
        }
        return false
    }

    /// Copies each attachment's sidecar file if missing -- files are
    /// immutable once written (`JournalAttachmentStore.save` never mutates
    /// an existing one), so "already exists at the destination" is a
    /// complete, correct skip condition, not just an optimization. Returns
    /// (copied this run, still pending) so the manifest can record the
    /// latter for a resumable follow-up pass.
    @discardableResult
    private static func syncAttachmentSidecars(personalWritingEntries: [PersonalWritingEntry], attachmentsDir: URL) -> (copied: Int, pending: Int) {
        var copied = 0
        var pending = 0
        for entry in personalWritingEntries {
            for attachment in entry.attachments {
                // Resolve by id, never by a hardcoded extension. This read
                // `<id>.jpg` and nothing else, so a voice note failed the
                // existence guard below and was skipped BEFORE the pending
                // counter -- absent from every automatic snapshot while the
                // manifest still reported success. An earlier fix corrected the
                // manual export path and missed this one, which is the path that
                // actually runs.
                guard let sourceURL = JournalAttachmentStore.existingFileURL(for: attachment.id) else { continue }
                let destURL = attachmentsDir.appendingPathComponent(
                    attachment.id.uuidString + "." + sourceURL.pathExtension
                )
                guard !FileManager.default.fileExists(atPath: destURL.path) else { continue }
                if copied >= maxAttachmentsPerRun {
                    pending += 1
                    continue
                }
                try? FileManager.default.copyItem(at: sourceURL, to: destURL)
                copied += 1
            }
        }
        return (copied, pending)
    }

    private static func pruneOldSnapshots(in backupsDir: URL, keeping: Int) {
        let snapshots = listSnapshotFilenames(in: backupsDir)
        guard snapshots.count > keeping else { return }
        // Lexicographic sort == chronological -- ISO8601-basic-UTC filenames.
        for stale in snapshots.sorted().dropLast(keeping) {
            try? FileManager.default.removeItem(at: backupsDir.appendingPathComponent(stale))
        }
    }

    private static func listSnapshotFilenames(in backupsDir: URL) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        return entries.filter { $0.hasPrefix("cobux-backup-") && $0.hasSuffix(".json") }
    }

    /// Orphan-prunes against the union of attachment ids referenced by ALL
    /// currently-retained snapshots, not just the current local store --
    /// pruning against local state would delete the sidecar for a photo the
    /// user just deleted, which is exactly the photo an older retained
    /// snapshot exists to let them roll back to.
    private static func pruneOrphanAttachments(backupsDir: URL, attachmentsDir: URL) {
        var referencedIDs = Set<String>()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for filename in listSnapshotFilenames(in: backupsDir) {
            guard let data = try? Data(contentsOf: backupsDir.appendingPathComponent(filename)),
                  let document = try? decoder.decode(BackupService.BackupDocument.self, from: data) else { continue }
            for entry in document.personalWritingEntries {
                referencedIDs.formUnion(entry.attachmentIDs)
            }
        }

        let files = (try? FileManager.default.contentsOfDirectory(atPath: attachmentsDir.path)) ?? []
        for file in files {
            let id = (file as NSString).deletingPathExtension
            guard !referencedIDs.contains(id) else { continue }
            try? FileManager.default.removeItem(at: attachmentsDir.appendingPathComponent(file))
        }
    }
}
