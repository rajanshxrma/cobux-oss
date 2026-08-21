import XCTest
@testable import Cobux

/// Coverage for the always-flush / bounded-rotation behavior `DiagnosticLog`
/// depends on to be trustworthy evidence during a crash-every-launch
/// incident: an entry must be readable back immediately after `log()`
/// returns, newest first, and the file must never grow past `maxEntries`.
/// Deliberately does not delete `Application Support` itself to reproduce
/// the original missing-directory bug (destructive in a shared test-host
/// directory) -- `createDirectory` there is idempotent, so this exercises
/// the same code path safely by just calling `log()` directly.
final class DiagnosticLogTests: XCTestCase {
    override func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(at: DiagnosticLog.fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: DiagnosticLog.fileURL)
        super.tearDown()
    }

    func testLoggedEntryIsImmediatelyReadable() {
        DiagnosticLog.log("regression-guard test entry")
        XCTAssertTrue(DiagnosticLog.recentEntries().contains { $0.contains("regression-guard test entry") })
    }

    func testEntriesReturnNewestFirst() {
        DiagnosticLog.log("first")
        DiagnosticLog.log("second")
        let entries = DiagnosticLog.recentEntries()
        let firstIndex = entries.firstIndex { $0.contains("first") }
        let secondIndex = entries.firstIndex { $0.contains("second") }
        guard let firstIndex, let secondIndex else {
            XCTFail("both entries should be present")
            return
        }
        XCTAssertLessThan(secondIndex, firstIndex, "the more recently logged entry should come first")
    }

    func testLogStaysBoundedAtMaxEntries() {
        // maxEntries is 500 (private constant) -- keep in sync if it changes.
        for i in 0..<520 {
            DiagnosticLog.log("entry \(i)")
        }
        XCTAssertLessThanOrEqual(DiagnosticLog.recentEntries().count, 500)
    }
}
