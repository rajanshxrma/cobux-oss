import Foundation
import MetricKit

/// In-app crash capture via MetricKit. Exists because of a real gap: a beta
/// tester's crash produced NOTHING actionable — no TestFlight feedback
/// submission (the API returned zero), and iOS's "share with developers"
/// analytics path only surfaces in Xcode's Organizer a day or two later, if
/// at all. With this subscriber, iOS hands the app its own crash diagnostics
/// on the next launch after a crash; they're written to Application Support
/// as JSON and surfaced in Settings, where any tester can export and send
/// them directly.
final class CrashReportCollector: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReportCollector()
    private override init() { super.init() }

    /// Per build-tier cap, not one flat cap across everything -- see
    /// `pruneOldReports`'s doc comment for why a single count would let a
    /// crash-looping build silently evict the one report from a build
    /// someone might still be running.
    private static let maxCurrentBuildReports = 10
    private static let maxStaleReports = 5

    static var reportsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CrashReports", isDirectory: true)
    }

    /// The build a saved report actually crashed on, alongside whether that's
    /// the build currently running -- the whole point of this rework. A
    /// report is otherwise indistinguishable from one Rajan already fixed
    /// three builds ago; nothing in a bare timestamp says which build it's
    /// even from, let alone whether it's still live.
    struct StoredReport: Identifiable {
        let url: URL
        let buildVersion: String
        let isCurrentBuild: Bool
        var id: String { url.absoluteString }
    }

    private static var runningBuildVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let crashPayloads = payloads.filter { !($0.crashDiagnostics ?? []).isEmpty }
        guard !crashPayloads.isEmpty else { return }

        let directory = Self.reportsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stampFormatter = ISO8601DateFormatter()
        stampFormatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate]
        for payload in crashPayloads {
            let stamp = stampFormatter.string(from: payload.timeStampEnd)
                .replacingOccurrences(of: ":", with: "-")
            // `metaData` lives on each individual `MXCrashDiagnostic`, not on
            // the payload itself -- `applicationBuildVersion` is the build
            // that actually produced THIS diagnostic, not necessarily the
            // build running right now, since MetricKit can deliver a payload
            // from a crash that happened before the app was updated. Encoded
            // directly in the filename (not just inside the JSON) so
            // `buildComponent(from:)` never has to open and parse a file just
            // to sort or label it. A payload can carry more than one crash
            // diagnostic; the first is a fine label since they share one
            // filename and JSON blob regardless.
            let build = Self.sanitizedBuildComponent(from: payload.crashDiagnostics?.first?.metaData.applicationBuildVersion)
            let url = directory.appendingPathComponent("crash-build\(build)-\(stamp).json")
            try? payload.jsonRepresentation().write(to: url)
        }

        Self.pruneOldReports()
    }

    /// A build number is normally plain digits, but this is data MetricKit
    /// handed back from a possibly-old payload -- sanitize defensively rather
    /// than let a stray path separator or space in a future OS's payload
    /// format corrupt the filename.
    private static func sanitizedBuildComponent(from raw: String?) -> String {
        let allowed = CharacterSet.alphanumerics
        let cleaned = (raw ?? "unknown").unicodeScalars.filter { allowed.contains($0) }
        let result = String(String.UnicodeScalarView(cleaned))
        return result.isEmpty ? "unknown" : result
    }

    /// Parses the build tag back out of a filename this collector wrote --
    /// `crash-build<N>-<timestamp>.json`. Falls back to "unknown" for a
    /// report saved before this rework shipped, so an old install's existing
    /// reports still show up (unlabeled as to build, correctly never treated
    /// as "current") rather than being silently dropped or crashing the parse.
    private static func buildComponent(from filename: String) -> String {
        guard filename.hasPrefix("crash-build") else { return "unknown" }
        let afterPrefix = filename.dropFirst("crash-build".count)
        guard let dashIndex = afterPrefix.firstIndex(of: "-") else { return "unknown" }
        return String(afterPrefix[afterPrefix.startIndex..<dashIndex])
    }

    /// Parses the timestamp portion back out of a filename this collector
    /// wrote -- `crash-build<N>-<timestamp>.json`. Sorting on THIS, not the
    /// whole filename, is what "newest first" actually requires: comparing
    /// the whole filename as a plain string compares the build-number digits
    /// first, so `"crash-build9-…" > "crash-build18-…"` lexically (`'9' >
    /// '1'`) even though build 18 is newer -- exactly backwards whenever
    /// single- and double-digit build numbers land in the same stale group,
    /// which is exactly the shape `pruneOldReports`'s `.dropFirst` then
    /// deletes in the wrong direction. The timestamp itself is ISO8601-style
    /// with dashes in place of colons, so it sorts correctly on its own with
    /// no numeric parsing needed. Falls back to the whole filename for
    /// anything that doesn't match the expected shape, same defensive spirit
    /// as `buildComponent(from:)`.
    private static func timestampComponent(from filename: String) -> String {
        guard filename.hasPrefix("crash-build"),
              let dashIndex = filename.dropFirst("crash-build".count).firstIndex(of: "-") else {
            return filename
        }
        return String(filename[filename.index(after: dashIndex)...])
    }

    /// Newest first within each group, current build's reports ahead of every
    /// stale one -- a tester should never have to scroll past reports from a
    /// build they're not even running to find the one that matters right now.
    /// Dates Cobux is known to have crashed, newest first, from the saved
    /// reports' own file timestamps.
    ///
    /// Used by `StreakTracker` to avoid punishing the user for the app's own
    /// failure: builds 25-30 crashed on launch for several days, which silently
    /// broke a real streak because the app simply could not be opened. A streak
    /// is a promise about the user's consistency, not the build's.
    static func crashDates() -> [Date] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: reportsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return urls.compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }.sorted(by: >)
    }

    static func savedReports() -> [StoredReport] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: reportsDirectory, includingPropertiesForKeys: nil
        )) ?? []
        let running = runningBuildVersion
        let reports = urls
            .filter { $0.pathExtension == "json" }
            .map { url -> StoredReport in
                let build = buildComponent(from: url.lastPathComponent)
                return StoredReport(url: url, buildVersion: build, isCurrentBuild: build == running)
            }
            .sorted { timestampComponent(from: $0.url.lastPathComponent) > timestampComponent(from: $1.url.lastPathComponent) }
        let current = reports.filter(\.isCurrentBuild)
        let stale = reports.filter { !$0.isCurrentBuild }
        return current + stale
    }

    /// Two separate caps, not one shared count. A single flat cap (the old
    /// behavior) meant a build that crashes repeatedly could fill the entire
    /// quota with duplicates of itself and silently evict every report from a
    /// build someone might still be running -- exactly backwards, since
    /// "still running" is the one case actually actionable right now. Capping
    /// current-build and stale reports independently means a crash-looping
    /// current build can never push out historical context, and old builds'
    /// reports can never crowd out what's actually live.
    private static func pruneOldReports() {
        let reports = savedReports()
        let staleOverflow = reports.filter { !$0.isCurrentBuild }.dropFirst(maxStaleReports)
        let currentOverflow = reports.filter(\.isCurrentBuild).dropFirst(maxCurrentBuildReports)
        for report in staleOverflow + currentOverflow {
            try? FileManager.default.removeItem(at: report.url)
        }
    }
}
