import Foundation

/// Decides whether an embedding-based free-recall verdict is uncertain enough to need a
/// second opinion from an on-device language model, per Fable's ruling on Apple-Intelligence-
/// tier grading (2026-08-06): the embedding grader is blind to negation/polarity ("inhibits
/// mTOR" and "does not inhibit mTOR" embed almost identically), so a confidently-wrong answer
/// containing a negator must not silently pass on similarity alone.
///
/// Pure and host-testable by design -- `FoundationModels`/Apple Intelligence can't run in CI
/// or any simulator, so every decidable rule about WHEN to escalate lives here, tested with
/// golden cases, and only the actual language-model call (not yet built -- see the ruling's
/// build order) stays a thin, untestable edge.
public enum GradeArbitration {
    /// Case-insensitive, whole-word. Deliberately conservative (a short, common list) --
    /// false positives here just mean an extra on-device call, not a wrong grade; false
    /// negatives are the actual risk (a real negation the embedding grader gets wrong).
    static let negatorTokens: Set<String> = [
        "not", "no", "never", "without", "except", "absent", "none", "neither", "nor", "cannot"
    ]

    /// How far below/above the pass threshold a similarity score counts as "uncertain" --
    /// invented, not measured (same honesty as `FreeRecallGrader.defaultThreshold`). Wider
    /// below than above: a near-miss below threshold is more likely a real partial answer
    /// worth a second opinion than a near-hit above it is likely a false positive.
    static let uncertainBandBelow: Float = 0.10
    static let uncertainBandAbove: Float = 0.05

    public static func needsArbitration(
        score: Float,
        threshold: Float = FreeRecallGrader.defaultThreshold,
        answerText: String,
        referenceText: String
    ) -> Bool {
        if score >= threshold - uncertainBandBelow, score <= threshold + uncertainBandAbove {
            return true
        }
        if score >= threshold, containsNegator(answerText) != containsNegator(referenceText) {
            return true
        }
        return false
    }

    static func containsNegator(_ text: String) -> Bool {
        let words = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return !negatorTokens.isDisjoint(with: Set(words))
    }
}
