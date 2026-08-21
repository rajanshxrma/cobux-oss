import Foundation

/// Shared build-number comparison, used by `UpdateAvailabilityStatus` (is a remote
/// build newer than the one running?) and `WhatsNewSheet` (which changelog entries
/// are newer than the last one a tester saw?). `CFBundleVersion` and
/// `BuildInfo.ChangelogEntry.build` are both plain strings -- today always a single
/// integer ("12"), but Apple permits dotted build numbers ("12.1.3") -- so this
/// parses to `[Int]` and compares element-wise rather than assuming one integer or
/// comparing lexically, which would rank "2.10.0" below "2.9.0".
enum BuildVersion {
    /// `true` if `candidate` is strictly newer than `baseline`. Returns `false` if
    /// either string fails to parse -- every caller here needs a fail-closed default
    /// (no banner, no unwanted changelog entry) rather than a crash or a false positive.
    static func isNewer(_ candidate: String, than baseline: String) -> Bool {
        guard let candidateParts = components(candidate), let baselineParts = components(baseline) else {
            return false
        }
        for i in 0..<max(candidateParts.count, baselineParts.count) {
            let c = i < candidateParts.count ? candidateParts[i] : 0
            let b = i < baselineParts.count ? baselineParts[i] : 0
            if c != b { return c > b }
        }
        return false
    }

    private static func components(_ raw: String) -> [Int]? {
        let parts = raw.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.map { $0! }
    }
}
