import Foundation

/// The pure decision logic behind grading a typed/spoken free-recall answer (`.application`
/// questions, and free-recall cloze cards) -- replaces the old `confidence == 3` self-rating,
/// where the user's own guess about whether they were right WAS the correctness signal.
///
/// Deliberately pure: the actual embedding + cosine similarity computation lives in
/// `EmbeddingService` (app target, depends on `NaturalLanguage`) -- CobuxCore has no UIKit/
/// SwiftUI/platform-framework dependency by design, so it only ever sees the resulting
/// `Float` score, the same split already established by `Ranker` (which ranks precomputed
/// scores, never touches an embedding API itself).
public enum FreeRecallGrader {
    /// `NLContextualEmbedding` cosine similarity between a genuinely correct paraphrase and
    /// its reference text sits comfortably above this in spot-checks against this app's own
    /// Ranker tests (0.7-0.95 band for related text) -- a real, but not measured-at-scale,
    /// judgment call. Ship as a documented constant, tune against real answers once Rajan has
    /// used this for a while, same spirit as `SpeechChunker`'s own thresholds.
    public static let defaultThreshold: Float = 0.72

    public static func isCorrect(similarity: Float, threshold: Float = defaultThreshold) -> Bool {
        similarity >= threshold
    }
}
