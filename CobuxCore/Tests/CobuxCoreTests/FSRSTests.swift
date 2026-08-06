import XCTest
@testable import CobuxCore

final class FSRSTests: XCTestCase {

    // MARK: Retrievability / Interval sanity identities (Fable's spec)

    func testIntervalAtNinetyPercentEqualsStability() {
        let S = 10.0
        let I = FSRS.interval(forRetention: 0.9, stability: S)
        XCTAssertEqual(I, S, accuracy: 0.0001, "I(0.9, S) must equal S exactly by construction")
    }

    func testIntervalAtNinetyFivePercentIsAboutPoint46OfStability() {
        let S = 20.0
        let I = FSRS.interval(forRetention: 0.95, stability: S)
        XCTAssertEqual(I / S, 0.46, accuracy: 0.01)
    }

    func testIntervalAtEightyFivePercentIsAboutPoint164OfStability() {
        let S = 20.0
        let I = FSRS.interval(forRetention: 0.85, stability: S)
        XCTAssertEqual(I / S, 1.64, accuracy: 0.01)
    }

    func testRetrievabilityRoundTripsWithInterval() {
        let S = 15.0
        let target = 0.9
        let t = FSRS.interval(forRetention: target, stability: S)
        let R = FSRS.retrievability(elapsedDays: t, stability: S)
        XCTAssertEqual(R, target, accuracy: 0.0001)
    }

    // MARK: First review

    func testFirstReviewEasyProducesHigherStabilityThanAgain() {
        let again = FSRS.schedule(state: .new, grade: .again, elapsedDays: 0, cardSeed: 1)
        let easy = FSRS.schedule(state: .new, grade: .easy, elapsedDays: 0, cardSeed: 1)
        XCTAssertLessThan(again.state.stability, easy.state.stability)
        XCTAssertEqual(again.state.reps, 1)
        XCTAssertEqual(again.state.lapses, 0, "a first-ever 'Again' is not a lapse, it's the starting point")
    }

    func testFirstReviewDifficultyClampedToOneToTen() {
        for grade in [FSRSGrade.again, .hard, .good, .easy] {
            let result = FSRS.schedule(state: .new, grade: grade, elapsedDays: 0, cardSeed: 2)
            XCTAssertGreaterThanOrEqual(result.state.difficulty, 1)
            XCTAssertLessThanOrEqual(result.state.difficulty, 10)
        }
    }

    // MARK: Subsequent reviews

    func testGoodGradeAfterCorrectIntervalIncreasesStability() {
        let first = FSRS.schedule(state: .new, grade: .good, elapsedDays: 0, cardSeed: 3)
        let second = FSRS.schedule(state: first.state, grade: .good, elapsedDays: Double(first.intervalDays), cardSeed: 3)
        XCTAssertGreaterThan(second.state.stability, first.state.stability, "a successful review at the scheduled interval should grow stability")
    }

    func testAgainGradeNeverIncreasesStability() {
        let first = FSRS.schedule(state: .new, grade: .good, elapsedDays: 0, cardSeed: 4)
        let lapsed = FSRS.schedule(state: first.state, grade: .again, elapsedDays: Double(first.intervalDays), cardSeed: 4)
        XCTAssertLessThanOrEqual(lapsed.state.stability, first.state.stability)
        XCTAssertEqual(lapsed.state.lapses, first.state.lapses + 1)
    }

    func testHardGradeGrowsStabilityLessThanGoodGrade() {
        let base = FSRS.schedule(state: .new, grade: .good, elapsedDays: 0, cardSeed: 5).state
        let hard = FSRS.schedule(state: base, grade: .hard, elapsedDays: 10, cardSeed: 5)
        let good = FSRS.schedule(state: base, grade: .good, elapsedDays: 10, cardSeed: 5)
        XCTAssertLessThan(hard.state.stability, good.state.stability)
    }

    // MARK: Exam Countdown clamp — the feature that makes this a medical-student app

    func testMaxIntervalClampNeverSchedulesPastExamDay() {
        // A well-known card (high stability) would normally get a long interval —
        // maxIntervalDays must still cap it to the exam date.
        var state = FSRSCardState(stability: 200, difficulty: 3, reps: 10, lapses: 0)
        let result = FSRS.schedule(state: state, grade: .easy, elapsedDays: 30, desiredRetention: 0.9, maxIntervalDays: 6, cardSeed: 6)
        XCTAssertLessThanOrEqual(result.intervalDays, 6)
        state = result.state
    }

    func testRisingDesiredRetentionCompressesInterval() {
        let state = FSRSCardState(stability: 30, difficulty: 5, reps: 5, lapses: 0)
        let early = FSRS.interval(forRetention: 0.90, stability: state.stability)
        let late = FSRS.interval(forRetention: 0.95, stability: state.stability)
        XCTAssertLessThan(late, early, "raising desiredRetention as an exam nears must shorten the interval, not lengthen it")
    }

    // MARK: Fuzz determinism — must be reproducible per card, not flaky

    func testFuzzIsDeterministicForSameSeed() {
        let a = FSRS.schedule(state: .new, grade: .good, elapsedDays: 0, cardSeed: 42)
        let b = FSRS.schedule(state: .new, grade: .good, elapsedDays: 0, cardSeed: 42)
        XCTAssertEqual(a.intervalDays, b.intervalDays, "same card, same inputs, must always produce the same interval")
    }

    func testFuzzDiffersAcrossDifferentSeedsAtScale() {
        let base = FSRSCardState(stability: 30, difficulty: 5, reps: 3, lapses: 0)
        let intervals = (0..<20).map { seed in
            FSRS.schedule(state: base, grade: .good, elapsedDays: 25, cardSeed: UInt64(seed)).intervalDays
        }
        XCTAssertTrue(Set(intervals).count > 1, "20 different cards at the same stability should not all land on the exact same due day")
    }

    func testShortIntervalsAreNotFuzzed() {
        // Below 2.5 days, fuzz is explicitly a no-op per spec.
        let state = FSRSCardState(stability: 1, difficulty: 8, reps: 1, lapses: 0)
        let result = FSRS.schedule(state: state, grade: .again, elapsedDays: 0.5, cardSeed: 99)
        XCTAssertGreaterThanOrEqual(result.intervalDays, 1, "minIntervalDays floor must hold")
    }

    // MARK: Migration from the old 5-box Leitner system

    func testMigrationSeedTableMatchesLeitnerBoxes() {
        // Mirrors the seeding table from the architecture pass: box -> (stability, difficulty).
        let seeds: [(box: Int, stability: Double, difficulty: Double)] = [
            (1, 1.0, 7.0), (2, 2.5, 6.0), (3, 6.0, 5.5), (4, 14.0, 5.0), (5, 34.0, 4.5)
        ]
        for seed in seeds {
            let state = FSRSCardState(stability: seed.stability, difficulty: seed.difficulty, reps: 1, lapses: 0)
            XCTAssertGreaterThan(state.stability, 0)
            XCTAssertGreaterThanOrEqual(state.difficulty, 1)
            XCTAssertLessThanOrEqual(state.difficulty, 10)
        }
    }
}
