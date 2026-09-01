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
    /// Throttle for the OPPORTUNISTIC path only (launch, backgrounding). Was 20
    /// hours, which is why a freshly written entry could not reach the Mac for
    /// most of a day no matter how many times the app was opened: "why the recent
    /// ones are not coming... iCloud Apple reminders are syncing so quick."
    ///
    /// Reminders feels instant because CloudKit pushes on every change. The
    /// equivalent here is `exportAfterWrite()` below, which fires on save and
    /// ignores this entirely. This interval now only bounds the redundant
    /// background sweeps, so it can be short without costing anything: the file
    /// is ~500 KB and writing it is a local write plus an iCloud upload.
    private static let minimumInterval: TimeInterval = 5 * 60
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
    ///
    /// `@MainActor` is load-bearing, not decorative: this used to be a plain
    /// synchronous function (always on-main by construction) and only became
    /// `async` this cycle so it could `await UbiquityContainer`. A nonisolated
    /// `async` function called with `await` from a `@MainActor` context does
    /// NOT stay on the main actor (SE-0338) -- it hops to the background
    /// executor, which means the `modelContext.fetch` below would run
    /// `container.mainContext` off the main thread on every single cold
    /// launch. That's the exact SwiftData/Core Data concurrency violation
    /// this codebase already has five separate comments warning about (the
    /// "Build-5 crash class" -- see `ContentView.swift`, `WatchSyncService.swift`,
    /// `FlowView.swift`), now hit unconditionally at launch instead of only
    /// on a race. `AutoBackupService`/`AutoRestoreService` both got this right
    /// from the start; this was the one omission.
    @MainActor
    static func exportIfNeeded(modelContext: ModelContext) async {
        _ = await export(modelContext: modelContext, force: false)
    }

    /// Called the instant an entry is saved. Unthrottled and deliberately so --
    /// this is the whole difference between "syncs eventually" and "it's there
    /// when I go looking for it", which is the behaviour he actually wants and
    /// already gets from Reminders.
    ///
    /// Fire-and-forget from the save path: the sheet must dismiss immediately,
    /// so this never blocks the write it is reacting to.
    @MainActor
    static func exportAfterWrite(modelContext: ModelContext) {
        Task { _ = await export(modelContext: modelContext, force: true) }
    }

    /// Ignores the throttle and reports what happened. Exists because the
    /// automatic path is invisible: it only runs at launch, it silently skips
    /// when throttled, and it says nothing either way -- so when Rajan wanted
    /// his journal synced *now*, there was no way to make it happen or to see
    /// why it hadn't.
    @MainActor
    @discardableResult
    static func export(modelContext: ModelContext, force: Bool) async -> Bool {
        if !force,
           let last = defaults.object(forKey: lastExportKey) as? Date,
           Date.now.timeIntervalSince(last) < minimumInterval {
            return false
        }

        let entries = (try? modelContext.fetch(FetchDescriptor<PersonalWritingEntry>())) ?? []
        guard !entries.isEmpty else { return false }

        guard let containerDocumentsURL = await UbiquityContainer.shared.documentsURL() else { return false }

        let formatter = ISO8601DateFormatter()
        let exported = entries.map { entry in
            ExportedEntry(
                source: entry.source,
                title: entry.title,
                text: entry.text,
                modifiedDate: entry.modifiedDate.map(formatter.string(from:))
            )
        }

        guard let data = try? JSONEncoder().encode(exported) else { return false }

        try? FileManager.default.createDirectory(at: containerDocumentsURL, withIntermediateDirectories: true)
        let fileURL = containerDocumentsURL.appendingPathComponent(exportFilename)
        do {
            try data.write(to: fileURL, options: .atomic)
            defaults.set(Date.now, forKey: lastExportKey)
            return true
        } catch {
            // Best-effort, same as every other silent background sync in this
            // app -- a failed write here just means tonight's export waits
            // for the next opportunistic call rather than surfacing an error
            // nobody's looking at.
            return false
        }
    }
}
