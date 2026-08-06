import XCTest
@testable import CobuxCore

final class BudgetGuardTests: XCTestCase {

    func testDefaultCapIsBelowUtkarshsRealFiveDollarKey() {
        // The whole point of the default is to trip before the account-level
        // cap does, leaving headroom for interactive chat.
        XCTAssertLessThan(BudgetGuard.defaultCapDollars, 5.0)
    }

    func testAllowsSpendWellUnderCap() {
        let guardValue = BudgetGuard(capDollars: 3.50)
        let decision = guardValue.evaluate(alreadySpentDollars: 0.50, proposedCostDollars: 0.20)
        XCTAssertTrue(decision.allowed)
        XCTAssertNil(decision.blockReason)
        XCTAssertEqual(decision.remainingDollars, 2.80, accuracy: 0.001)
    }

    func testAllowsSpendExactlyAtCap() {
        let guardValue = BudgetGuard(capDollars: 1.00)
        let decision = guardValue.evaluate(alreadySpentDollars: 0.60, proposedCostDollars: 0.40)
        XCTAssertTrue(decision.allowed)
        XCTAssertEqual(decision.remainingDollars, 0, accuracy: 0.001)
    }

    func testBlocksSpendThatWouldExceedCap() {
        let guardValue = BudgetGuard(capDollars: 1.00)
        let decision = guardValue.evaluate(alreadySpentDollars: 0.90, proposedCostDollars: 0.20)
        XCTAssertFalse(decision.allowed)
        XCTAssertNotNil(decision.blockReason)
    }

    func testBlocksWhenAlreadyOverCapBeforeThisCall() {
        // e.g. cap was lowered in Settings after spend already happened this month.
        let guardValue = BudgetGuard(capDollars: 1.00)
        let decision = guardValue.evaluate(alreadySpentDollars: 1.50, proposedCostDollars: 0.01)
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.remainingDollars, 0)
    }

    func testRemainingNeverGoesNegativeWhenAlreadyOverCap() {
        let guardValue = BudgetGuard(capDollars: 1.00)
        let decision = guardValue.evaluate(alreadySpentDollars: 5.00, proposedCostDollars: 0)
        XCTAssertEqual(decision.remainingDollars, 0)
    }

    func testBlockReasonMentionsBothFiguresForClarity() throws {
        let guardValue = BudgetGuard(capDollars: 3.50)
        let decision = guardValue.evaluate(alreadySpentDollars: 3.40, proposedCostDollars: 0.30)
        XCTAssertFalse(decision.allowed)
        let reason = try XCTUnwrap(decision.blockReason)
        XCTAssertTrue(reason.contains("3.50"))
        XCTAssertTrue(reason.contains("3.70"))
    }
}
