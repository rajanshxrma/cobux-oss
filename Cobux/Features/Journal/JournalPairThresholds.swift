import Foundation

/// The one rule that says when a nearest-line match is real: the winner must
/// stand clear of its own pool's spread by more than noise alone would give.
///
/// Extracted from `JournalPairFinder` (build 60) so the Ebb deck builder --
/// which is compiled into the macOS assertion harness -- can share it without
/// dragging the finder's model types along. Foundation only, on purpose; the
/// finder delegates here and the two cannot drift.
enum JournalPairThresholds {
    /// The floor. A pairing qualifies by standing clear of ITS OWN spread
    /// (the model's cosine band is narrow and per-pool z-normalised), and 2σ
    /// is the least that ever reads as an echo rather than fluency.
    static let minimumSigma: Double = 2.0

    /// The bar a pool of `n` candidates must clear, which is NOT a constant:
    /// the winner is the argmax of the pool, and the maximum of n standardised
    /// samples drifts upward with n by order statistics alone. √(2 ln n) is
    /// the standard asymptotic for that expected maximum; the winner must beat
    /// it plus a margin. At n=8 ≈2.5σ; at n=150 ≈3.7σ.
    static func requiredSigma(poolSize: Int) -> Double {
        let n = Double(max(2, poolSize))
        return max(minimumSigma, (2 * Foundation.log(n)).squareRoot() + 0.4)
    }
}
