import Foundation

/// Sole owner of `FileManager.url(forUbiquityContainerIdentifier:)` for the whole app.
///
/// Two real problems motivated pulling this into one place instead of leaving every caller to
/// call the API directly (which `JournalAutoExportService` originally did):
///
/// 1. **Threading.** Apple's own documentation notes this call "may take a nontrivial amount of
///    time" -- it is not safe to treat as free, and every existing caller in this app is
///    `@MainActor`. `documentsURL()` is `async` specifically so a caller can't accidentally block
///    the main actor on it the way the original `JournalAutoExportService` did (it looked up the
///    container BEFORE checking its own throttle, so the expensive call ran on every single
///    foreground/background transition regardless of the 20h guard -- exactly backwards).
/// 2. **Repeated lookups.** A successful lookup is memoized for the process lifetime (the
///    container identifier and its resolved URL don't change mid-session), so only the first
///    caller in a given launch pays the real cost. A `nil` result is NEVER memoized permanently --
///    only a short 60s cooldown -- because the entitlement can go from absent to present mid-session
///    (this exact app shipped tonight with the capability freshly enabled), and silently disabling
///    every iCloud feature for the rest of that session would be a worse failure than one extra
///    lookup.
actor UbiquityContainer {
    static let shared = UbiquityContainer()

    private let identifier = "iCloud.com.rajansharma.Cobux"
    private var cachedURL: URL?
    private var lastNilLookup: Date?
    private let nilCooldown: TimeInterval = 60

    /// `Documents/` inside the app's ubiquity container, or `nil` if the container isn't
    /// available yet (entitlement not active on this install, or iCloud Drive is off/signed out
    /// on this device). Every caller in this app treats `nil` as a silent no-op, never an error --
    /// same convention as `CrashReportCollector`/`DiagnosticLog` reaching for a directory that
    /// might not exist yet.
    func documentsURL() async -> URL? {
        if let cachedURL { return cachedURL }
        if let lastNilLookup, Date.now.timeIntervalSince(lastNilLookup) < nilCooldown { return nil }

        let resolved = FileManager.default.url(forUbiquityContainerIdentifier: identifier)?
            .appendingPathComponent("Documents", isDirectory: true)

        if let resolved {
            cachedURL = resolved
        } else {
            lastNilLookup = .now
        }
        return resolved
    }

    /// Waits for a ubiquity file to finish downloading from iCloud before it's read -- a file
    /// that exists in the container's directory listing can still be a non-materialized
    /// placeholder on this device. Only relevant to restore (this app has never read a ubiquity
    /// file before tonight; every existing write-only caller doesn't need this). Bounded timeout:
    /// a restore that can't materialize its snapshot in time should fail cleanly and retry next
    /// launch, not hang indefinitely.
    func waitForDownload(of url: URL, timeout: TimeInterval = 30) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
               values.ubiquitousItemDownloadingStatus == .current {
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }
}
