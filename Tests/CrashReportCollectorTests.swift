import XCTest
@testable import Cobux

/// Regression coverage for the inverted stale-report sort (2.3.x): sorting
/// by the whole filename as a plain string put `"crash-build9-…"` ahead of
/// `"crash-build18-…"` because `'9' > '1'` lexically, exactly backwards from
/// "newest first". `savedReports()` must sort on the timestamp component
/// alone. Writes real files under `CrashReportCollector.reportsDirectory`
/// (a sandboxed test-host path, never a real device's data) and removes
/// only the exact filenames it created.
final class CrashReportCollectorTests: XCTestCase {
    private var createdURLs: [URL] = []

    override func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(at: CrashReportCollector.reportsDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for url in createdURLs {
            try? FileManager.default.removeItem(at: url)
        }
        createdURLs = []
        super.tearDown()
    }

    @discardableResult
    private func writeReport(build: String, timestamp: String) -> URL {
        let url = CrashReportCollector.reportsDirectory.appendingPathComponent("crash-build\(build)-\(timestamp).json")
        try? "{}".write(to: url, atomically: true, encoding: .utf8)
        createdURLs.append(url)
        return url
    }

    func testStaleReportsSortNewestTimestampFirstNotLexically() {
        // Both land in the "stale" bucket since neither build tag matches the
        // test host's own CFBundleVersion -- exactly the case the lexical bug
        // got backwards: build 9's report is older, but "9" > "1" as characters.
        let older = writeReport(build: "9", timestamp: "2026-01-01T00-00-00Z")
        let newer = writeReport(build: "18", timestamp: "2026-06-01T00-00-00Z")

        let reports = CrashReportCollector.savedReports()
        let orderedURLs = reports.map(\.url)
        guard let newerIndex = orderedURLs.firstIndex(of: newer),
              let olderIndex = orderedURLs.firstIndex(of: older) else {
            XCTFail("both written reports should appear in savedReports()")
            return
        }
        XCTAssertLessThan(newerIndex, olderIndex, "the newer report (build 18) must sort ahead of the older one (build 9)")
    }

    func testCurrentBuildReportsSortBeforeStaleReports() {
        let runningBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let current = writeReport(build: runningBuild, timestamp: "2020-01-01T00-00-00Z")
        let stale = writeReport(build: "999999", timestamp: "2099-01-01T00-00-00Z")

        let reports = CrashReportCollector.savedReports()
        let orderedURLs = reports.map(\.url)
        guard let currentIndex = orderedURLs.firstIndex(of: current),
              let staleIndex = orderedURLs.firstIndex(of: stale) else {
            XCTFail("both written reports should appear in savedReports()")
            return
        }
        XCTAssertLessThan(currentIndex, staleIndex, "a current-build report must sort ahead of any stale report regardless of timestamp")
    }
}
