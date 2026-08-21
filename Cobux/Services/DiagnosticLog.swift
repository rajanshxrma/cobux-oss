import Foundation

/// A small, always-on, append-only local event log -- not a third-party analytics SDK
/// (Mixpanel/Amplitude/Firebase-style), which would be overkill for a 3-person TestFlight
/// audience and works against the app's local-first/BYOK ethos, and the content this app
/// stores (journals, personal notes) argues for less telemetry infrastructure, not more.
///
/// Directly motivated by a real gap: `CrashReportCollector`'s MetricKit crash diagnostics
/// only deliver on the NEXT successful launch -- useless during a crash-every-launch
/// incident, where the fix had to be reverse-engineered from source alone instead of from
/// real evidence a tester could have shared. This flushes every entry to disk immediately
/// (not batched), so a log survives right up to the moment of a crash, not just up to the
/// last batch boundary.
///
/// Scoped down deliberately: seed lifecycle and store health, the two real event classes
/// this app has actually needed evidence for so far. Not "record everything" -- a log that
/// captures every view appearance or button tap would grow unbounded and bury the signal
/// that actually matters in noise nobody will ever read.
enum DiagnosticLog {
    private static let maxEntries = 500

    /// Exposed for `DiagnosticsView`'s `ShareLink` -- the same "any tester can
    /// export and send this directly" convention `CrashReportCollector`
    /// already established.
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("diagnostic-log.txt")
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Appends one line and flushes immediately -- a real `FileHandle` write + `synchronize()`,
    /// not a buffered write that could still be sitting in memory if the app dies a moment later.
    static func log(_ message: String) {
        let line = "\(timestampFormatter.string(from: .now))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        // `Application Support` is NOT created by the system -- `urls(for:in:)`
        // only computes the path, it never creates the directory. Without this,
        // `createFile` below fails silently on a fresh install (nothing else in
        // the app creates this exact directory), `FileHandle(forWritingTo:)`
        // throws, and every single entry -- including the "store degraded" case
        // this whole log exists to catch -- is dropped with no error anywhere.
        // `CrashReportCollector.swift` already gets this right for its own
        // subdirectory; this mirrors it.
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        // The throwing variants (iOS 13.4+), not `seekToEndOfFile()`/`write(_:)`/
        // `synchronizeFile()` -- those raise an uncatchable Objective-C
        // exception on failure (a full disk, most realistically) rather than a
        // Swift error, and `try?` cannot catch an NSException. The very first
        // call site of this function runs inside `sharedModelContainer`'s own
        // initializer at launch, so that failure mode would have turned a full
        // device into a launch crash coming from the crash-diagnostics code
        // itself.
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            return
        }

        rotateIfNeeded()
    }

    /// Newest first, for the Diagnostics screen and `ShareLink`.
    static func recentEntries() -> [String] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").reversed().map(String.init)
    }

    /// Caps the file at `maxEntries` lines rather than letting it grow forever -- checked
    /// on every write rather than on a timer, since this app has no background scheduler
    /// running when it isn't already foregrounded to log something in the first place.
    private static func rotateIfNeeded() {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > maxEntries else { return }
        let trimmed = lines.suffix(maxEntries).joined(separator: "\n") + "\n"
        try? trimmed.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
