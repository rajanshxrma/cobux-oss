import SwiftData
import Foundation

/// Silently keeps a Mac-visible copy of every `PersonalWritingEntry` current, so the
/// existing `journal-brain-sync.py` LaunchAgent can pick up new in-app Journal writing the
/// same automatic way it already scrapes Apple Journal/Notes -- see "Journal sync pipeline,
/// 2026-08-20" in ai-brain/pending-tasks.md for the full two-sided design.
///
/// Routes every ubiquity-container lookup through `UbiquityContainer` -- the throttle check
/// below runs FIRST and returns before ever touching the container on the (overwhelmingly
/// common) call where nothing needs to happen. This used to be backwards: the original version
/// resolved the container URL before checking its own throttle, so Apple's documented
/// not-necessarily-fast lookup ran on every single foreground/background transition regardless
/// of the 20h guard. `documentsURL()` returns `nil` until the container's entitlement is active
/// on this install, and every call below no-ops the moment that happens rather than crashing or
/// logging noise -- the same graceful-degradation shape as `CrashReportCollector`/`DiagnosticLog`
/// reaching for a directory that might not be there yet.
enum JournalAutoExportService {
    private static let defaults = UserDefaults.standard
    private static let lastExportKey = "cobux.journalAutoExport.lastExportDate"
    /// Roughly once a day -- this mirrors a nightly Mac-side cron pickup, not
    /// a live sync, so there is no value in writing more often than that.
    private static let minimumInterval: TimeInterval = 20 * 60 * 60
    private static let exportFilename = "cobux-journal-autoexport.json"

    struct ExportedEntry: Codable {
        var source: String
        var title: String
        var text: String
        /// ISO 8601, unlike `PersonalWritingImportService.ExportedEntry`'s
        /// raw AppleScript date string -- this file is written and read by
        /// code this project controls end to end, so there's no reason to
        /// carry that format's locale quirks forward into a new export path.
        var modifiedDate: String?
    }

    /// Call opportunistically on launch/background, same cadence as
    /// `WatchSyncService.sync` in `ContentView` -- cheap to call often since
    /// the throttle check is the very first thing this does, entirely local,
    /// before any iCloud I/O.
    static func exportIfNeeded(modelContext: ModelContext) async {
        if let last = defaults.object(forKey: lastExportKey) as? Date,
           Date.now.timeIntervalSince(last) < minimumInterval {
            return
        }

        let entries = (try? modelContext.fetch(FetchDescriptor<PersonalWritingEntry>())) ?? []
        guard !entries.isEmpty else { return }

        guard let containerDocumentsURL = await UbiquityContainer.shared.documentsURL() else { return }

        let formatter = ISO8601DateFormatter()
        let exported = entries.map { entry in
            ExportedEntry(
                source: entry.source,
                title: entry.title,
                text: entry.text,
                modifiedDate: entry.modifiedDate.map(formatter.string(from:))
            )
        }

        guard let data = try? JSONEncoder().encode(exported) else { return }

        try? FileManager.default.createDirectory(at: containerDocumentsURL, withIntermediateDirectories: true)
        let fileURL = containerDocumentsURL.appendingPathComponent(exportFilename)
        do {
            try data.write(to: fileURL, options: .atomic)
            defaults.set(Date.now, forKey: lastExportKey)
        } catch {
            // Best-effort, same as every other silent background sync in this
            // app -- a failed write here just means tonight's export waits
            // for the next opportunistic call rather than surfacing an error
            // nobody's looking at.
        }
    }
}
