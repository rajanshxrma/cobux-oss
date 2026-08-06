import XCTest
@testable import CobuxCore

final class GradeArbitrationTests: XCTestCase {
    func testClearPassNeedsNoArbitration() {
        XCTAssertFalse(GradeArbitration.needsArbitration(
            score: 0.95, answerText: "It inhibits mTOR", referenceText: "Rapamycin inhibits mTOR"
        ))
    }

    func testClearFailNeedsNoArbitration() {
        XCTAssertFalse(GradeArbitration.needsArbitration(
            score: 0.2, answerText: "Something unrelated", referenceText: "Rapamycin inhibits mTOR"
        ))
    }

    func testScoreJustBelowThresholdNeedsArbitration() {
        let threshold = FreeRecallGrader.defaultThreshold
        XCTAssertTrue(GradeArbitration.needsArbitration(
            score: threshold - 0.05, answerText: "a", referenceText: "b"
        ))
    }

    func testScoreJustAboveThresholdNeedsArbitration() {
        let threshold = FreeRecallGrader.defaultThreshold
        XCTAssertTrue(GradeArbitration.needsArbitration(
            score: threshold + 0.02, answerText: "a", referenceText: "b"
        ))
    }

    func testPassingScoreWithMismatchedNegationNeedsArbitration() {
        // The real embedding-blind-spot case: "inhibits" vs "does not inhibit" score high on
        // pure similarity despite being opposite claims.
        XCTAssertTrue(GradeArbitration.needsArbitration(
            score: 0.9, answerText: "Rapamycin does not inhibit mTOR", referenceText: "Rapamycin inhibits mTOR"
        ))
    }

    func testPassingScoreWithMatchedNegationInBothNeedsNoArbitration() {
        // Both sides agree on the negation -- not a mismatch, no reason to escalate.
        XCTAssertFalse(GradeArbitration.needsArbitration(
            score: 0.9,
            answerText: "Rapamycin does not inhibit mTORC2 directly",
            referenceText: "Rapamycin does not inhibit mTORC2 directly, only mTORC1"
        ))
    }

    func testContainsNegatorIsWholeWordNotSubstring() {
        // "known" contains "no" as a substring but is not the negator "no".
        XCTAssertFalse(GradeArbitration.containsNegator("This is a well-known fact"))
        XCTAssertTrue(GradeArbitration.containsNegator("There is no known cure"))
    }
}
