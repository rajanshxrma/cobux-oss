import XCTest
@testable import Cobux

/// Guards the Echo pairing — the first piece of Ebb to ship.
///
/// Everything here is about the vetoes in `docs/ebb.md` holding. The pairing
/// puts a private passage of his beside a book line, so the ways it can be
/// wrong are not cosmetic.
final class JournalPairFinderTests: XCTestCase {

    private func snap(_ text: String, _ tradition: BookTradition?) -> JournalPairFinder.HighlightSnapshot {
        .init(id: UUID(), text: text, bookTitle: "A Book", tradition: tradition)
    }

    /// Similarity stubbed by position so the statistics are exact.
    private func candidates(_ scores: [Double],
                            tradition: BookTradition = .stoicPractice)
    -> (pool: [(snapshot: JournalPairFinder.HighlightSnapshot, vector: [Float])],
        similarity: ([Float], [Float]) -> Float) {
        let pool = scores.enumerated().map {
            (snapshot: snap("line \($0.offset)", tradition), vector: [Float($0.offset)])
        }
        let byIndex = scores
        let similarity: ([Float], [Float]) -> Float = { _, b in
            Float(byIndex[Int(b[0])])
        }
        return (pool, similarity)
    }

    /// A line that stands clear of its own distribution pairs.
    func testAClearStandoutPairs() {
        let (pool, sim) = candidates([0.70, 0.71, 0.69, 0.70, 0.72, 0.70, 0.71, 0.69, 0.99])
        let pairing = JournalPairFinder.bestPairing(
            passage: "mine", passageVector: [0], candidates: pool, similarity: sim)
        XCTAssertNotNil(pairing)
        XCTAssertEqual(pairing?.highlightText, "line 8")
        XCTAssertGreaterThanOrEqual(pairing?.sigma ?? 0, JournalPairFinder.minimumSigma)
    }

    /// The whole point of relative selection: high absolute similarity that is
    /// merely typical is NOT an echo. Every one of these would clear a 0.7
    /// absolute floor, and none of them means anything.
    func testUniformlyHighSimilarityDoesNotPair() {
        let (pool, sim) = candidates([0.90, 0.91, 0.89, 0.90, 0.91, 0.90, 0.89, 0.90, 0.91])
        XCTAssertNil(JournalPairFinder.bestPairing(
            passage: "mine", passageVector: [0], candidates: pool, similarity: sim),
            "a fluent-but-typical match is exactly what the sigma gate exists to reject")
    }

    /// The tradition veto: therapy, devotion, memoir and belief never pair.
    func testVetoedTraditionsAreNotPaired() {
        for tradition in [BookTradition.therapy, .devotion, .memoir, .belief] {
            let (pool, sim) = candidates(
                [0.70, 0.71, 0.69, 0.70, 0.72, 0.70, 0.71, 0.69, 0.99], tradition: tradition)
            XCTAssertNil(JournalPairFinder.bestPairing(
                passage: "mine", passageVector: [0], candidates: pool, similarity: sim),
                "\(tradition) must never be paired against private writing")
        }
    }

    func testUntaggedBooksAreNotPaired() {
        let (pool, sim) = candidates([0.7, 0.7, 0.7, 0.7, 0.7, 0.7, 0.7, 0.7, 0.99])
        let untagged = pool.map { (snapshot: JournalPairFinder.HighlightSnapshot(
            id: $0.snapshot.id, text: $0.snapshot.text,
            bookTitle: $0.snapshot.bookTitle, tradition: nil), vector: $0.vector) }
        XCTAssertNil(JournalPairFinder.bestPairing(
            passage: "mine", passageVector: [0], candidates: untagged, similarity: sim))
    }

    /// Too small a pool cannot have a meaningful distribution.
    func testTinyPoolDoesNotPair() {
        let (pool, sim) = candidates([0.10, 0.99])
        XCTAssertNil(JournalPairFinder.bestPairing(
            passage: "mine", passageVector: [0], candidates: pool, similarity: sim))
    }

    /// A pool with no spread cannot single anything out, and dividing by that
    /// spread would manufacture a winner out of noise.
    func testFlatPoolDoesNotPair() {
        let (pool, sim) = candidates(Array(repeating: 0.8, count: 12))
        XCTAssertNil(JournalPairFinder.bestPairing(
            passage: "mine", passageVector: [0], candidates: pool, similarity: sim))
    }

    /// The failure the flat 2σ gate hid: at a realistic pool size the ARGMAX of
    /// pure noise clears 2σ almost always, purely by order statistics. A gate
    /// that a random pool passes is measuring pool size, not resemblance.
    func testALargeNoisyPoolDoesNotPair() {
        var seed: UInt64 = 12345
        func rand() -> Double {   // deterministic, so this test cannot flake
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }
        let scores = (0..<150).map { _ in 0.70 + rand() * 0.25 }
        let (pool, sim) = candidates(scores)
        XCTAssertNil(JournalPairFinder.bestPairing(
            passage: "mine", passageVector: [0], candidates: pool, similarity: sim),
            "noise must not pair, however large the pool")
    }

    /// The bar rises with pool size, because the maximum of many samples does.
    func testRequiredSigmaGrowsWithPoolSize() {
        XCTAssertLessThan(JournalPairFinder.requiredSigma(poolSize: 8),
                          JournalPairFinder.requiredSigma(poolSize: 150))
        XCTAssertGreaterThan(JournalPairFinder.requiredSigma(poolSize: 150), 3.0)
    }

    /// No absolute floor exists: a standout pairs even when every score is low.
    func testLowAbsoluteScoresStillPairIfOneStandsOut() {
        let (pool, sim) = candidates([0.10, 0.11, 0.09, 0.10, 0.12, 0.10, 0.11, 0.09, 0.95])
        XCTAssertNotNil(JournalPairFinder.bestPairing(
            passage: "mine", passageVector: [0], candidates: pool, similarity: sim),
            "selection is relative — there is deliberately no absolute threshold")
    }
}
