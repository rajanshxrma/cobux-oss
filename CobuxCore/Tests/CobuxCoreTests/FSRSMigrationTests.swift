import XCTest
@testable import CobuxCore

final class FSRSMigrationTests: XCTestCase {

    func testSingleHighlightSeedsExactlyFromItsBox() {
        let state = FSRSMigration.seedState(fromSourceHighlightBoxes: [3])
        let expected = FSRSMigration.seedTable[3]!
        XCTAssertEqual(state.stability, expected.stability)
        XCTAssertEqual(state.difficulty, expected.difficulty)
        XCTAssertEqual(state.reps, 1, "a migrated card has real history, not zero -- it shouldn't look 'new' to the scheduler")
    }

    func testMultipleHighlightsAverageRoundedToNearestBox() {
        // (1 + 5) / 2 = 3 exactly.
        let state = FSRSMigration.seedState(fromSourceHighlightBoxes: [1, 5])
        let expected = FSRSMigration.seedTable[3]!
        XCTAssertEqual(state.stability, expected.stability)
        XCTAssertEqual(state.difficulty, expected.difficulty)
    }

    func testAverageRoundsToNearestNotTruncates() {
        // (2 + 3) / 2 = 2.5 -> rounds to 3, not floors to 2.
        let state = FSRSMigration.seedState(fromSourceHighlightBoxes: [2, 3])
        let expected = FSRSMigration.seedTable[3]!
        XCTAssertEqual(state.stability, expected.stability)
    }

    func testEmptyBoxesReturnsNewState() {
        XCTAssertEqual(FSRSMigration.seedState(fromSourceHighlightBoxes: []), .new)
    }

    func testHigherBoxAlwaysProducesHigherStabilityThanLowerBox() {
        // Ordering must be preserved -- a well-known fact can't migrate to a
        // WORSE starting point than a fact that was never reviewed.
        var previousStability = 0.0
        for box in 1...5 {
            let state = FSRSMigration.seedState(fromSourceHighlightBoxes: [box])
            XCTAssertGreaterThan(state.stability, previousStability)
            previousStability = state.stability
        }
    }

    func testOutOfRangeBoxesAreClamped() {
        // Defensive: real data should never have box outside 1...5, but the
        // function shouldn't crash or silently misbehave if it somehow did.
        let low = FSRSMigration.seedState(fromSourceHighlightBoxes: [0])
        let high = FSRSMigration.seedState(fromSourceHighlightBoxes: [99])
        XCTAssertEqual(low.stability, FSRSMigration.seedTable[1]!.stability)
        XCTAssertEqual(high.stability, FSRSMigration.seedTable[5]!.stability)
    }
}
