import XCTest
@testable import Cobux

/// Exercises the 2.3.0 streak-protection logic by writing directly into the
/// same defaults suite `StreakTracker` uses (in the test host this is
/// process-local, not Rajan's real device state). Dates are injected by
/// planting `lastActiveDate` N days in the past — `recordActivityToday()`
/// always acts on "now", so the past is the only thing a test needs to fake.
final class StreakTrackerTests: XCTestCase {
    private let defaults = UserDefaults(suiteName: "group.com.rajansharma.Cobux") ?? .standard

    private let allKeys = [
        StreakTracker.lastActiveDateKey,
        StreakTracker.currentStreakKey,
        StreakTracker.freezeBankKey,
        StreakTracker.freezeProgressKey,
        StreakTracker.pendingMilestoneKey,
        StreakTracker.longestStreakKey,
    ]

    override func setUp() {
        super.setUp()
        allKeys.forEach(defaults.removeObject(forKey:))
    }

    override func tearDown() {
        allKeys.forEach(defaults.removeObject(forKey:))
        super.tearDown()
    }

    private func plantState(daysAgo: Int, streak: Int, freezeBank: Int = 0, freezeProgress: Int = 0) {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: .now))!
        defaults.set(day, forKey: StreakTracker.lastActiveDateKey)
        defaults.set(streak, forKey: StreakTracker.currentStreakKey)
        defaults.set(freezeBank, forKey: StreakTracker.freezeBankKey)
        defaults.set(freezeProgress, forKey: StreakTracker.freezeProgressKey)
    }

    func testFirstActivityStartsAtOne() {
        XCTAssertEqual(StreakTracker.recordActivityToday(), 1)
        XCTAssertEqual(StreakTracker.currentStreak, 1)
        XCTAssertTrue(StreakTracker.hasShownUpToday)
    }

    func testSameDayIsNoOp() {
        plantState(daysAgo: 0, streak: 5)
        XCTAssertEqual(StreakTracker.recordActivityToday(), 5)
    }

    func testConsecutiveDayIncrements() {
        plantState(daysAgo: 1, streak: 5)
        XCTAssertEqual(StreakTracker.recordActivityToday(), 6)
    }

    func testMissedDayWithoutFreezeResets() {
        plantState(daysAgo: 2, streak: 5, freezeBank: 0)
        XCTAssertEqual(StreakTracker.currentStreak, 0, "display goes honest-zero before the next record")
        XCTAssertEqual(StreakTracker.recordActivityToday(), 1)
    }

    func testMissedDayCoveredByFreeze() {
        plantState(daysAgo: 2, streak: 5, freezeBank: 1)
        XCTAssertEqual(StreakTracker.currentStreak, 5, "a freeze-covered gap keeps showing the streak")
        XCTAssertEqual(StreakTracker.recordActivityToday(), 6)
        XCTAssertEqual(StreakTracker.freezeBank, 0, "the freeze was spent")
    }

    func testTwoMissedDaysNeedTwoFreezes() {
        plantState(daysAgo: 3, streak: 9, freezeBank: 2)
        XCTAssertEqual(StreakTracker.recordActivityToday(), 10)
        XCTAssertEqual(StreakTracker.freezeBank, 0)

        allKeys.forEach(defaults.removeObject(forKey:))
        plantState(daysAgo: 3, streak: 9, freezeBank: 1)
        XCTAssertEqual(StreakTracker.recordActivityToday(), 1, "gap bigger than the bank resets")
        XCTAssertEqual(StreakTracker.freezeBank, 0, "an insufficient bank isn't partially spent — the reset clears it outright")
    }

    func testStreakResetClearsFreezeBank() {
        plantState(daysAgo: 10, streak: 20, freezeBank: 2)
        XCTAssertEqual(StreakTracker.recordActivityToday(), 1)
        XCTAssertEqual(StreakTracker.freezeBank, 0, "freezes must not survive the streak they failed to save")
    }

    func testFreezeEarnedAfterSevenConsecutiveDays() {
        plantState(daysAgo: 1, streak: 6, freezeBank: 0, freezeProgress: 6)
        StreakTracker.recordActivityToday()
        XCTAssertEqual(StreakTracker.freezeBank, 1)
    }

    func testFreezeBankCapsAtTwo() {
        plantState(daysAgo: 1, streak: 20, freezeBank: 2, freezeProgress: 6)
        StreakTracker.recordActivityToday()
        XCTAssertEqual(StreakTracker.freezeBank, 2)
    }

    func testMilestoneParkedOnCrossing() {
        plantState(daysAgo: 1, streak: 6)
        StreakTracker.recordActivityToday()
        XCTAssertEqual(StreakTracker.pendingMilestone, 7)
        StreakTracker.clearPendingMilestone()
        XCTAssertEqual(StreakTracker.pendingMilestone, 0)
    }

    func testNonMilestoneDayParksNothing() {
        plantState(daysAgo: 1, streak: 7)
        StreakTracker.recordActivityToday()
        XCTAssertEqual(StreakTracker.pendingMilestone, 0)
    }

    func testClockMovedBackwardIsTreatedAsSameDay() {
        // `daysAgo: -1` plants `lastActiveDate` one day in the *future* --
        // simulating a device clock (or timezone data) that moved backward
        // since the last recorded activity. Before the fix this fell into
        // the missed-day `default` branch with a negative `daysBetween`,
        // which always passed the `missedDays <= bank` check and both
        // inflated `freezeBank` past its cap and regressed `lastActiveDate`
        // to a date earlier than what was already stored.
        plantState(daysAgo: -1, streak: 5, freezeBank: 1)
        XCTAssertEqual(StreakTracker.recordActivityToday(), 5, "a lastActiveDate in the future must not be treated as a multi-day gap")
        XCTAssertEqual(StreakTracker.freezeBank, 1, "the freeze bank must not be touched, let alone inflated past its cap")
    }

    func testLongestStreakTracksHighWaterMark() {
        plantState(daysAgo: 1, streak: 5)
        StreakTracker.recordActivityToday()
        XCTAssertEqual(StreakTracker.longestStreak, 6)

        // A reset doesn't erase the high-water mark.
        allKeys.forEach { key in
            if key != StreakTracker.longestStreakKey { defaults.removeObject(forKey: key) }
        }
        plantState(daysAgo: 2, streak: 3)
        StreakTracker.recordActivityToday()
        XCTAssertEqual(StreakTracker.longestStreak, 6)
    }
}
