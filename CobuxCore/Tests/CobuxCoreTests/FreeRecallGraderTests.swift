import XCTest
@testable import CobuxCore

final class FreeRecallGraderTests: XCTestCase {
    func testAboveThresholdIsCorrect() {
        XCTAssertTrue(FreeRecallGrader.isCorrect(similarity: 0.9))
        XCTAssertTrue(FreeRecallGrader.isCorrect(similarity: FreeRecallGrader.defaultThreshold))
    }

    func testBelowThresholdIsIncorrect() {
        XCTAssertFalse(FreeRecallGrader.isCorrect(similarity: 0.5))
    }

    func testCustomThresholdOverridesDefault() {
        XCTAssertFalse(FreeRecallGrader.isCorrect(similarity: 0.8, threshold: 0.85))
        XCTAssertTrue(FreeRecallGrader.isCorrect(similarity: 0.8, threshold: 0.75))
    }
}
