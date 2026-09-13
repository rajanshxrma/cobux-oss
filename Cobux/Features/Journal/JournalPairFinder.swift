import Foundation

/// Finds the book line closest in meaning to something he wrote.
///
/// This is the "Echo" half of the Ebb design (`docs/ebb.md`) and the first piece
/// of it to ship. `JournalHighlightSelector.Pick` has declared a `.resonance`
/// case with the kicker "Your words × your books" since the card was written,
/// `JournalHighlightCard` has always had a rendering branch for it, and nothing
/// ever constructed one. The seam was cut and never connected.
///
/// Everything here is a pure function over value types so it can be reasoned
/// about and tested without a device, an embedder, or SwiftData.
enum JournalPairFinder {

    /// A book highlight, flattened for cross-actor work.
    struct HighlightSnapshot: Sendable {
        let id: UUID
        let text: String
        let bookTitle: String
        let tradition: BookTradition?
    }

    /// A passage of his beside the highlight nearest it.
    struct Pairing: Sendable, Equatable {
        let passage: String
        let highlightText: String
        let bookTitle: String
        /// How far above this passage's own mean score the winner sat, in
        /// standard deviations. Never rendered -- kept so the calibration dump
        /// can be read by a human before this is trusted.
        let sigma: Double
    }

    /// Which shelves may be paired against at all.
    ///
    /// A veto, not a preference (see `docs/ebb.md`). The originally proposed
    /// "therapy threshold" was shown to be a no-op that quietly filtered the
    /// pool down to the most despairing entries. Strategy, method, counsel,
    /// stoic practice and narrative can meet a private passage without the
    /// pairing itself becoming a diagnosis; therapy, devotion, memoir and
    /// belief cannot, and stay out until a human has read real pairs.
    static let pairableTraditions: Set<BookTradition> = [
        .stoicPractice, .strategy, .method, .counsel, .narrative,
    ]

    /// How far above its own distribution a pairing must stand.
    ///
    /// NOT an absolute cosine floor. `SearchService` already documents that
    /// absolute similarity floors "don't mean anything for this embedding
    /// model" -- arbitrary English sits in a 0.7-0.95 band -- which is why
    /// `CobuxCore.Ranker` z-normalises per pool. Every fixed 0.62/0.70/0.72
    /// threshold proposed for this feature dies on that fact. A pairing
    /// qualifies by standing clear of ITS OWN spread, which is also what
    /// separates a real echo from a merely fluent one.
    static let minimumSigma: Double = JournalPairThresholds.minimumSigma

    /// The bar a pool of `n` candidates must clear, which is NOT a constant.
    ///
    /// A flat 2σ looked principled and was not. The winner is the ARGMAX of the
    /// pool, and the maximum of n samples drifts upward with n purely by order
    /// statistics -- for n≈150 the expected maximum of standardised noise is
    /// already above 3σ, so a fixed 2σ was cleared almost every time by pools
    /// that contained nothing remarkable at all. The gate was measuring the
    /// size of the pool, not the strength of the match.
    ///
    /// √(2 ln n) is the standard asymptotic for that expected maximum, so this
    /// asks the winner to beat what noise alone would produce, plus a margin.
    /// At n=8 it is ≈2.5σ; at n=150 ≈3.7σ.
    static func requiredSigma(poolSize: Int) -> Double {
        JournalPairThresholds.requiredSigma(poolSize: poolSize)
    }

    /// The best pairing for one passage, or nothing.
    ///
    /// - Parameters:
    ///   - passageVector: the freshly embedded passage. Fresh on both sides is
    ///     load-bearing: comparing a vector stored months ago against one made
    ///     now can silently mismatch dimensions, which `cosineSimilarity`
    ///     reports as zero rather than as an error. Embedding both sides in one
    ///     pass makes that structurally impossible.
    ///   - candidates: sampled highlights with their fresh vectors.
    static func bestPairing(passage: String,
                            passageVector: [Float],
                            candidates: [(snapshot: HighlightSnapshot, vector: [Float])],
                            similarity: (([Float], [Float]) -> Float)) -> Pairing? {
        let eligible = candidates.filter {
            guard let tradition = $0.snapshot.tradition else { return false }
            return pairableTraditions.contains(tradition)
        }
        guard eligible.count >= 8 else { return nil }

        let scores = eligible.map { Double(similarity(passageVector, $0.vector)) }
        guard let bestIndex = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return nil }

        let mean = scores.reduce(0, +) / Double(scores.count)
        let variance = scores.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(scores.count)
        let deviation = variance.squareRoot()
        // A pool with no spread cannot single anything out, and dividing by it
        // would manufacture a winner from noise.
        guard deviation > 0.0001 else { return nil }

        let sigma = (scores[bestIndex] - mean) / deviation
        guard sigma >= requiredSigma(poolSize: scores.count) else { return nil }

        // And it must beat the runner-up, not merely the average. Two book
        // lines that are equally close to a passage mean the passage is
        // generic, and pairing it with whichever edged the other is a
        // coincidence presented as recognition.
        let runnerUp = scores.enumerated()
            .filter { $0.offset != bestIndex }
            .map(\.element)
            .max() ?? scores[bestIndex]
        guard (scores[bestIndex] - runnerUp) / deviation >= 0.5 else { return nil }

        let winner = eligible[bestIndex].snapshot
        return Pairing(passage: passage,
                       highlightText: winner.text,
                       bookTitle: winner.bookTitle,
                       sigma: sigma)
    }
}
