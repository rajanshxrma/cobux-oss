import XCTest
@testable import Cobux

/// Guards the treasure's two promises: it only grows, and nothing about it can
/// be read back as a quantity.
final class DeltaLedgerTests: XCTestCase {

    /// Growth-only is the anti-grading mechanism. A quiet month must cost
    /// nothing, or the mark becomes a scoreboard.
    func testComplexityNeverShrinks() {
        var last = 0
        for words in stride(from: 0, through: 2_000_000, by: 5_000) {
            let strands = DeltaLedger.strands(words: words)
            XCTAssertGreaterThanOrEqual(strands, last, "the sigil may never be docked")
            last = strands
        }
    }

    /// Coarse on purpose: it moves across months and years, never week to week,
    /// so it can never read as a weekly score.
    func testComplexityMovesOnlyInLargeSteps() {
        XCTAssertEqual(DeltaLedger.strands(words: 400), DeltaLedger.strands(words: 900))
        XCTAssertEqual(DeltaLedger.strands(words: 1_000), DeltaLedger.strands(words: 1_900))
        XCTAssertLessThan(DeltaLedger.strands(words: 1_000), DeltaLedger.strands(words: 40_000))
    }

    func testComplexityIsCapped() {
        XCTAssertEqual(DeltaLedger.strands(words: 500_000_000), 11)
    }

    /// The seed is hashed so no strand count or thickness can be decoded into
    /// how much he has written -- that would rebuild the census veto in
    /// graphics.
    func testSeedIsNotMonotonicInAnyInput() {
        func seedBytes(words: Int) -> [UInt8] {
            var s = DeltaLedger.Snapshot(); s.words = words
            return DeltaLedger.seed(for: s)
        }
        let a = seedBytes(words: 5_000), b = seedBytes(words: 5_500), c = seedBytes(words: 6_000)
        XCTAssertNotEqual(a, b)
        // If the first byte tracked word count in either direction, the mark
        // would be readable as a quantity.
        XCTAssertFalse(a[0] <= b[0] && b[0] <= c[0] && a[0] != c[0],
                       "seed bytes must not order with the underlying value")
    }

    /// Stable between milestones, so the mark does not shift every sentence.
    func testSeedIsStableWithinABucket() {
        func seedBytes(words: Int) -> [UInt8] {
            var s = DeltaLedger.Snapshot(); s.words = words
            return DeltaLedger.seed(for: s)
        }
        XCTAssertEqual(seedBytes(words: 5_000), seedBytes(words: 5_400))
    }

    func testHueIsStableAndBounded() {
        var s = DeltaLedger.Snapshot()
        XCTAssertEqual(DeltaLedger.hueAngle(for: s), 0, "no writing yet means no drift")
        s.centroid = [0.4, -0.2, 0.9]
        let angle = DeltaLedger.hueAngle(for: s)
        XCTAssertTrue((0...1).contains(angle))
        XCTAssertEqual(angle, DeltaLedger.hueAngle(for: s), "the same corpus is the same colour")
    }

    /// The ledger holds counts, dates and a direction. Never text.
    func testSnapshotCarriesNoText() {
        let fields = Set(Mirror(reflecting: DeltaLedger.Snapshot()).children.compactMap(\.label))
        for forbidden in ["summary", "text", "themes", "personality", "philosophy", "traits"] {
            XCTAssertFalse(fields.contains(forbidden),
                           "the treasure is his corpus, never a distillation of him")
        }
    }
}
