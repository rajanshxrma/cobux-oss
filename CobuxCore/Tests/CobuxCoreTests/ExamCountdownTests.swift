import XCTest
@testable import CobuxCore

final class ExamCountdownTests: XCTestCase {

    func testDaysLeftNeverGoesBelowOne() {
        let now = Date()
        let examToday = now.addingTimeInterval(3600) // an hour from now, same calendar day
        XCTAssertGreaterThanOrEqual(ExamCountdown.daysLeft(from: now, to: examToday), 1)

        let examYesterday = now.addingTimeInterval(-86400)
        XCTAssertEqual(ExamCountdown.daysLeft(from: now, to: examYesterday), 1, "a past exam date must not produce a negative countdown")
    }

    func testDaysLeftCountsRealCalendarDays() {
        let now = Date()
        let in10Days = Calendar.current.date(byAdding: .day, value: 10, to: now)!
        XCTAssertEqual(ExamCountdown.daysLeft(from: now, to: in10Days), 10)
    }

    func testDesiredRetentionRisesAsExamApproaches() {
        XCTAssertEqual(ExamCountdown.desiredRetention(daysLeft: 30), 0.90)
        XCTAssertEqual(ExamCountdown.desiredRetention(daysLeft: 15), 0.90)
        XCTAssertEqual(ExamCountdown.desiredRetention(daysLeft: 14), 0.93)
        XCTAssertEqual(ExamCountdown.desiredRetention(daysLeft: 8), 0.93)
        XCTAssertEqual(ExamCountdown.desiredRetention(daysLeft: 7), 0.95)
        XCTAssertEqual(ExamCountdown.desiredRetention(daysLeft: 1), 0.95)
    }

    func testMaxIntervalNeverExceedsDaysLeft() {
        // The actual point of the whole feature: nothing scheduled past exam day.
        XCTAssertEqual(ExamCountdown.maxIntervalDays(daysLeft: 6), 6)
        let result = FSRS.schedule(
            state: FSRSCardState(stability: 200, difficulty: 3, reps: 10, lapses: 0),
            grade: .easy,
            elapsedDays: 30,
            desiredRetention: ExamCountdown.desiredRetention(daysLeft: 6),
            maxIntervalDays: ExamCountdown.maxIntervalDays(daysLeft: 6),
            cardSeed: 1
        )
        XCTAssertLessThanOrEqual(result.intervalDays, 6)
    }

    func testRequiredNewPerDayAccountsForBuffer() {
        // 90 cards, 12 days left, 3-day buffer -> 9 effective days -> 10/day.
        XCTAssertEqual(ExamCountdown.requiredNewPerDay(notIntroduced: 90, daysLeft: 12, bufferDays: 3), 10)
    }

    func testRequiredNewPerDayRoundsUpNotDown() {
        // 10 cards, 4 effective days -> 2.5 -> rounds up to 3, never 2 (2/day would leave 2 cards unseen).
        XCTAssertEqual(ExamCountdown.requiredNewPerDay(notIntroduced: 10, daysLeft: 7, bufferDays: 3), 3)
    }

    func testRequiredNewPerDayIsZeroWhenNothingLeftToIntroduce() {
        XCTAssertEqual(ExamCountdown.requiredNewPerDay(notIntroduced: 0, daysLeft: 10), 0)
    }

    func testProjectedCoverageAtRequiredPaceReachesFullCoverage() {
        let notIntroduced = 90
        let daysLeft = 12
        let requiredPace = ExamCountdown.requiredNewPerDay(notIntroduced: notIntroduced, daysLeft: daysLeft)
        let coverage = ExamCountdown.projectedCoverage(notIntroduced: notIntroduced, daysLeft: daysLeft, newPerDay: requiredPace)
        XCTAssertEqual(coverage, 1.0, accuracy: 0.01, "the pace this function itself recommends must actually achieve full coverage")
    }

    func testProjectedCoverageBelowRequiredPaceIsPartial() {
        let coverage = ExamCountdown.projectedCoverage(notIntroduced: 100, daysLeft: 12, newPerDay: 1)
        XCTAssertLessThan(coverage, 1.0)
        XCTAssertGreaterThan(coverage, 0)
    }

    func testProjectedCoverageNeverExceedsOneHundredPercent() {
        let coverage = ExamCountdown.projectedCoverage(notIntroduced: 5, daysLeft: 30, newPerDay: 50)
        XCTAssertEqual(coverage, 1.0)
    }

    func testProjectedCoverageIsFullWhenNothingToIntroduce() {
        XCTAssertEqual(ExamCountdown.projectedCoverage(notIntroduced: 0, daysLeft: 10, newPerDay: 5), 1.0)
    }
}
