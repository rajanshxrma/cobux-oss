import XCTest
@testable import Cobux

/// Coverage for the smart-timing notification feature (2.5.11): below the
/// minimum sample count `smartHours()` must stay `nil` (never a shaky
/// one-sample guess), and once there's enough data it should surface the
/// genuinely most-common hours, breaking ties toward the earlier hour so the
/// result is stable run to run. `key` mirrors `AppActivityTracker`'s own
/// private storage key exactly — keep the two in sync if that literal ever
/// changes.
final class AppActivityTrackerTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private let key = "cobux.activity.openHours"

    override func setUp() {
        super.setUp()
        defaults.removeObject(forKey: key)
    }

    override func tearDown() {
        defaults.removeObject(forKey: key)
        super.tearDown()
    }

    private func record(hours: [Int]) {
        for hour in hours {
            let date = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: hour)) ?? .now
            AppActivityTracker.recordOpen(at: date)
        }
    }

    func testBelowMinimumSamplesReturnsNil() {
        // minimumSamplesForSmartTiming is 7 -- one short of it must still be nil.
        record(hours: [8, 8, 8, 8, 8, 8])
        XCTAssertNil(AppActivityTracker.smartHours())
    }

    func testAtMinimumSamplesReturnsMostCommonHours() {
        record(hours: [8, 8, 8, 8, 20, 20, 20])
        XCTAssertEqual(AppActivityTracker.smartHours(), [8, 20])
    }

    func testTiesBreakTowardEarlierHour() {
        record(hours: [7, 7, 9, 9, 20, 20, 20])
        // 7 and 9 tie at 2 samples each; 20 leads outright. The earlier tied
        // hour (7) must win the second slot, not whichever happened to hash first.
        XCTAssertEqual(AppActivityTracker.smartHours(), [7, 20])
    }

    func testResultIsSortedEarliestFirst() {
        record(hours: [20, 20, 20, 8, 8, 8, 8])
        XCTAssertEqual(AppActivityTracker.smartHours(), [8, 20])
    }

    func testHistoryStaysBoundedAtMaxSamples() {
        // maxSamples is 60 (private constant) -- keep in sync if it changes.
        record(hours: Array(repeating: 8, count: 65))
        let raw = defaults.array(forKey: key) as? [Int] ?? []
        XCTAssertLessThanOrEqual(raw.count, 60)
    }
}
