import Foundation
import UIKit

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

    /// Serializes appends. Until SeedRunner existed every caller was on the
    /// main actor, so the per-call open/seek/write/close pattern below never
    /// overlapped; now seed work logs from its own executor while the UI
    /// logs from main. Two unserialized appends both seek to the same end
    /// and interleave bytes -- a garbled diagnostic log is worthless in the
    /// exact crash it exists to explain.
    private static let writeLock = NSLock()

    /// Exposed for `DiagnosticsView`'s `ShareLink` -- the same "any tester can
    /// export and send this directly" convention `CrashReportCollector`
    /// already established.
    ///
    /// A `let`, not a computed `var`: the path cannot change while the process
    /// lives, and `log()` alone reads this four times per call (directory,
    /// existence check, create, open). Recomputing
    /// `FileManager.urls(for:in:)` each time made the app's most frequently
    /// called logging primitive do four container lookups to learn a constant.
    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("diagnostic-log.txt")
    }()

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Whether this process has already written its own device/build header.
    /// Read and set only inside `writeLock`'s critical section below -- the
    /// same lock that already serializes main-actor UI logging against
    /// `SeedRunner`'s own executor, so two callers racing to be "first" this
    /// launch cannot both decide they are.
    private static var loggedDeviceHeaderThisLaunch = false

    /// The device model identifier ("iPhone15,2", not the marketing name) via
    /// `uname`/`utsname.machine` -- the one fact App Store Connect crash
    /// reports and MetricKit already carry that this log did not, and the
    /// cheapest fix for "can you build something so that you also recognize
    /// the devices of the users ... it could be a little thing." `Mirror`
    /// over the fixed-size C char tuple avoids hand-rolled unsafe-pointer
    /// casting for a value read once per header stamp.
    static func modelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return Mirror(reflecting: systemInfo.machine).children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result += String(UnicodeScalar(UInt8(value)))
        }
    }

    /// One line naming the device and build this log came from -- see
    /// `log()`'s call site for why it is written once per process launch
    /// rather than once per install. `Bundle.main`, not `DiagnosticsView`'s
    /// own cached `appVersion`/`appBuild`: this file has no dependency on
    /// that view and must not gain one just to read two strings.
    private static func deviceHeader() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current
        return "device: \(modelIdentifier()), \(device.systemName) \(device.systemVersion), build \(version) (\(build))"
    }

    /// Appends one line and flushes immediately -- a real `FileHandle` write + `synchronize()`,
    /// not a buffered write that could still be sitting in memory if the app dies a moment later.
    static func log(_ message: String) {
        writeLock.lock()
        defer { writeLock.unlock() }

        var line = "\(timestampFormatter.string(from: .now))  \(message)\n"
        // The launch's first line, whether that is because the file itself is
        // brand new or because this is simply the first call since the
        // process started -- a pasted log otherwise names neither the phone
        // it came from nor which build wrote which entries, which is exactly
        // what made Amal's crash log identifiable only because App Store
        // Connect (not this file) happened to carry the device separately.
        if !loggedDeviceHeaderThisLaunch {
            loggedDeviceHeaderThisLaunch = true
            line = "\(timestampFormatter.string(from: .now))  \(deviceHeader())\n" + line
        }
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

    /// Newest first. The Diagnostics screen shows a count and shares the file
    /// itself, so it takes `entryCount()` and `fileURL` instead; this stays as
    /// the only way to actually read the entries back -- it is what
    /// `DiagnosticLogTests` asserts rotation against, and what any surface
    /// that ever shows the log in the app will want. Deleting it would leave
    /// an append-only log with no reader.
    static func recentEntries() -> [String] { // lint:unused-ok read by DiagnosticLogTests; the log's only line-level reader

        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").reversed().map(String.init)
    }

    /// How many entries the log holds, without building one `String` per line.
    ///
    /// The Diagnostics screen only ever wanted this number, and it was getting
    /// it from `recentEntries().count` -- inside `body`, on the main actor. That
    /// read the whole file, decoded it as UTF-8, split it, reversed it and
    /// allocated up to `maxEntries` Strings, and it did all of that again on
    /// every single body evaluation, to display one Int. Counting the line
    /// terminators over the bytes answers the same question without
    /// materialising anything; `recentEntries()` stays for the callers that
    /// genuinely want the lines.
    ///
    /// This counts runs of non-newline bytes rather than newlines, so it agrees
    /// with `recentEntries().count` exactly -- that one splits with
    /// `omittingEmptySubsequences`, so a blank line (a logged message that
    /// itself ended in a newline) is not an entry there and must not be one
    /// here. A diagnostics screen whose own two counts disagree is worse than
    /// no count.
    static func entryCount() -> Int {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return 0 }
        let newline = UInt8(ascii: "\n")
        var entries = 0
        var insideEntry = false
        for byte in data {
            if byte == newline {
                insideEntry = false
            } else if !insideEntry {
                insideEntry = true
                entries += 1
            }
        }
        return entries
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
