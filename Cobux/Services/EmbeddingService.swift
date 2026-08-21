import NaturalLanguage
import CoreML
import Foundation

/// On-device semantic embedding for highlight text. No network, no API key, no cost.
///
/// Prefers `NLContextualEmbedding` (iOS 17+, higher quality, contextual token
/// vectors averaged into a single sentence-level vector). If that model's assets
/// aren't available on-device (and we deliberately don't trigger an async asset
/// download here, to keep `embed(_:)` simple and synchronous), falls back to the
/// older, always-available `NLEmbedding.sentenceEmbedding(for:)`. Returns `nil`
/// only if neither path can produce a vector (e.g. unsupported language) —
/// callers must treat that as "no vector for this highlight" and degrade
/// gracefully to keyword search.
struct EmbeddingService {
    /// Loading `NLContextualEmbedding` is expensive; reuse one loaded instance
    /// across calls instead of constructing and loading it per highlight.
    private static let sharedContextualEmbedder: NLContextualEmbedding? = {
        guard let embedder = NLContextualEmbedding(language: .english),
              embedder.hasAvailableAssets else {
            return nil
        }
        do {
            try embedder.load()
            return embedder
        } catch {
            return nil
        }
    }()

    static func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let vector = contextualEmbed(trimmed) {
            return vector
        }
        return sentenceEmbed(trimmed)
    }

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dot: Float = 0
        var magA: Float = 0
        var magB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }

        let denominator = magA.squareRoot() * magB.squareRoot()
        guard denominator > 0 else { return 0 }
        return dot / denominator
    }

    /// Backfills `highlight.embedding` for any highlight that doesn't have one yet.
    /// Does NOT call `modelContext.save()` — SwiftData's autosave (enabled by
    /// default) typically persists these changes on its own. If the caller needs
    /// the write guaranteed immediately, call `try? modelContext.save()` after
    /// this returns.
    static func backfillMissingEmbeddings(highlights: [Highlight]) {
        for highlight in highlights where highlight.embedding == nil {
            if let vector = embed(highlight.text) {
                highlight.embedding = vector
            }
        }
    }

    /// Attempts Apple's on-device contextual embedding model. Only used when its
    /// assets are already resident on-device (`hasAvailableAssets`); we never call
    /// `requestAssets` here since that's an async network-capable download and
    /// would break the "simple synchronous call" contract of `embed(_:)`.
    private static func contextualEmbed(_ text: String) -> [Float]? {
        guard let embedder = sharedContextualEmbedder else {
            return nil
        }

        do {
            let result = try embedder.embeddingResult(for: text, language: .english)

            var sum: [Float] = []
            var tokenCount = 0
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                if sum.isEmpty {
                    sum = [Float](repeating: 0, count: vector.count)
                }
                // `sum` is sized from the FIRST token vector; every real
                // `NLContextualEmbedding` model should emit a fixed dimensionality
                // per call, but nothing here actually guarantees a later vector
                // can't come back longer -- `min(...)` makes that an ignored
                // trailing component instead of an index-out-of-range crash,
                // which is what a bare `0..<vector.count` would do.
                for i in 0..<min(vector.count, sum.count) {
                    sum[i] += Float(vector[i])
                }
                tokenCount += 1
                return true
            }

            guard tokenCount > 0, !sum.isEmpty else { return nil }
            let count = Float(tokenCount)
            return sum.map { $0 / count }
        } catch {
            return nil
        }
    }

    /// Fallback: Apple's older static sentence embedding. Always available
    /// on-device for supported languages (English included); lower quality than
    /// the contextual model but never requires an asset download.
    private static func sentenceEmbed(_ text: String) -> [Float]? {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            return nil
        }
        guard let vector = embedding.vector(for: text) else {
            return nil
        }
        return vector.map { Float($0) }
    }
}
