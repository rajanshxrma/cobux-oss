import SwiftData
import Foundation

/// Silently pulls Rajan's whole writing archive into Cobux, so it's simply
/// there instead of waiting behind a file picker.
///
/// His ask: *"add my notes... all writing with date and time according to Cobux
/// formatting and everything in my Cobux as it is so i have all of it in one
/// place and order."*
///
/// The archive already existed and was already correctly formatted — 244
/// entries spanning Apple Journal, Notes, the user's writing folders, handwritten transcriptions
/// — maintained daily by `journal-brain-sync.py` on the Mac. The only thing
/// standing between that file and the app was a **manual file picker**:
/// `PersonalWritingImportService.importData` was reachable from exactly one
/// place, a button in Settings. So "all of it in one place" was never going to
/// happen on its own, no matter how good the Mac-side pipeline got.
///
/// This closes that last gap. The Mac now drops a copy into Cobux's OWN
/// ubiquity container (an iOS app can't read arbitrary iCloud Drive files
/// without a picker — the app's own container it can), and this reads it on
/// launch.
///
/// Safe to run every launch because the underlying importer is genuinely
/// idempotent: it dedupes on (source, title, text, day), so re-importing the
/// same archive adds nothing. That's the same property `AutoRestoreService`
/// relies on, and it's why this can be silent rather than asking each time.
enum PersonalWritingAutoImportService {
    private static let defaults = UserDefaults.standard
    /// Digest of the last file successfully imported. Skips the (multi-hundred
    /// entry) parse+dedupe entirely when the archive hasn't changed since last
    /// launch, which is the overwhelmingly common case -- same
    /// digest-gating idea `AutoBackupService` uses to avoid rewriting an
    /// unchanged snapshot.
    private static let lastImportedDigestKey = "cobux.personalWriting.lastImportedDigest"
    private static let filename = "cobux-personal-writing-export.json"

    /// Call opportunistically at launch, off the critical path. Every failure
    /// mode -- no container, no file, unreadable JSON -- is a silent no-op:
    /// this is a convenience, and it must never be the reason the app feels
    /// slow or shows an error about a file the user never asked about.
    @MainActor
    static func importIfNeeded(modelContext: ModelContext) async {
        guard !SeedingStatus.shared.isSeeding, !StoreHealthStatus.shared.isDegraded else { return }
        guard let documentsURL = await UbiquityContainer.shared.documentsURL() else { return }

        let fileURL = documentsURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        // Materialize it if iCloud hasn't downloaded it yet -- the same
        // placeholder problem `AutoRestoreService` handles for snapshots.
        guard await UbiquityContainer.shared.waitForDownload(of: fileURL) else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return }

        // Cheap change check before the expensive part.
        let digest = "\(data.count)"
        guard defaults.string(forKey: lastImportedDigestKey) != digest else { return }

        guard let result = try? await PersonalWritingImportService.importData(data, modelContext: modelContext) else {
            return
        }
        defaults.set(digest, forKey: lastImportedDigestKey)

        if result.imported > 0 {
            DiagnosticLog.log("auto-imported \(result.imported) personal writing entries")
        }
    }

    /// What a manual "Sync now" actually did, so the UI can say something real
    /// instead of spinning.
    enum SyncOutcome: Equatable {
        case imported(Int)
        case alreadyUpToDate
        case noFileInICloud
        case waitingForICloudDownload
        case failed
    }

    /// Runs the import right now, ignoring both gates the automatic path uses.
    ///
    /// The automatic path is invisible and unpushable: it only runs at launch,
    /// and it skips entirely when the file's byte count matches the last import.
    /// So when Rajan wrote a journal entry this morning and wanted it in the app,
    /// there was no way to make that happen and no way to see why it hadn't --
    /// "we're still waiting on the journals to sync."
    ///
    /// Embeddings are deferred here on purpose: they are the slow part, and
    /// `backfillPersonalWritingEmbeddings` picks them up afterwards, so today's
    /// entry shows up in seconds rather than after several hundred model calls.
    @MainActor
    static func syncNow(modelContext: ModelContext) async -> SyncOutcome {
        guard let documentsURL = await UbiquityContainer.shared.documentsURL() else { return .failed }
        let fileURL = documentsURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .noFileInICloud }
        guard await UbiquityContainer.shared.waitForDownload(of: fileURL) else { return .waitingForICloudDownload }
        guard let data = try? Data(contentsOf: fileURL) else { return .failed }

        guard let result = try? await PersonalWritingImportService.importData(
            data, modelContext: modelContext, deferEmbeddings: true
        ) else { return .failed }

        defaults.set("\(data.count)", forKey: lastImportedDigestKey)
        DiagnosticLog.log("manual sync imported \(result.imported) entries")
        return result.imported > 0 ? .imported(result.imported) : .alreadyUpToDate
    }
}
