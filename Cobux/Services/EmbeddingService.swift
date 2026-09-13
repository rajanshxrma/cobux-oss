import Accelerate
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
/// only if the active model cannot produce a vector for this text — callers
/// must treat that as "no vector for this highlight" and degrade gracefully to
/// keyword search.
///
/// ONE model per process, and one model per install until it is deliberately
/// changed. Both models emit 512 floats, so a stored vector carries no
/// provenance of its own and `cosineSimilarity`'s length guard cannot tell
/// them apart -- a contextual query vector scored against a static stored
/// vector is noise with no error anywhere. The model in use is therefore
/// pinned per install (`pinnedModelKey`), and `SeedRunner` reconciles the pin
/// against `activeModel` at launch: a change discards every stored vector so
/// the ordinary backfill re-embeds under the new model. There is also no
/// per-text fallback between models any more: a text the contextual model
/// declines stays un-embedded (keyword search still finds it) rather than
/// being stored as a static vector nobody can later distinguish.
struct EmbeddingService {
    /// The models this service can run, identified by the string persisted
    /// per install. Never rename a case's raw value -- it IS the provenance
    /// record; renaming would read as a model change and re-embed everything.
    enum Model: String {
        /// `NLContextualEmbedding(language: .english)`, mean-pooled tokens.
        case contextual = "nlcontextual-en-v1"
        /// `NLEmbedding.sentenceEmbedding(for: .english)`.
        case sentence = "nlsentence-en"
        /// Neither model can run here. Nothing embeds; retrieval is keyword-only.
        case none = "none"
    }

    /// UserDefaults key holding the `Model.rawValue` every stored vector on
    /// this install was produced with. Written by `pinActiveModel()` only.
    static let pinnedModelKey = "cobux.embedding.modelID"

    /// Chosen once per process, deliberately, not per call. The contextual
    /// model wins whenever its assets are resident AND it loads; otherwise the
    /// static sentence model. Loading is done here, once, because
    /// `NLContextualEmbedding.load()` is expensive and the shared instance is
    /// reused across every call for the life of the process.
    static let activeModel: Model = {
        if sharedContextualEmbedder != nil { return .contextual }
        if sharedSentenceEmbedding != nil { return .sentence }
        return .none
    }()

    /// False only when neither model can run on this device. The backfills
    /// check this first so a device with no model does not burn a launch
    /// attempting -- and declining -- every row in the library.
    static var isAvailable: Bool { activeModel != .none }

    /// The model id recorded for this install's stored vectors, if any.
    static var pinnedModelID: String? {
        UserDefaults.standard.string(forKey: pinnedModelKey)
    }

    /// True when a pin exists and names a different model than the one this
    /// process embeds with -- every stored vector is then from the wrong
    /// model and must be discarded before it is compared against anything.
    /// No pin at all is NOT stale: that is the first launch of a build that
    /// records provenance, and the honest move is to record the current
    /// choice (see `SeedRunner.reconcileEmbeddingModel`).
    static func storedVectorsAreStale() -> Bool {
        guard let pinned = pinnedModelID else { return false }
        return pinned != activeModel.rawValue
    }

    /// Records `activeModel` as the provenance of every stored vector. Call
    /// only when that is true: on first record, or after a completed discard.
    static func pinActiveModel() {
        UserDefaults.standard.set(activeModel.rawValue, forKey: pinnedModelKey)
    }

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

    /// The static model, loaded once. It used to be re-created on every call
    /// (`NLEmbedding.sentenceEmbedding(for:)` reads the model from disk), which
    /// at backfill scale was a disk read per highlight.
    private static let sharedSentenceEmbedding: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)

    /// Embeds `text` with the active model, memoising the most recent query
    /// vectors. One chat send embeds the SAME user message several times on
    /// its way to a prompt -- once in `ChatView`'s off-main hop, once in
    /// `CrossChatMemory`, once per `semanticSearch` call in `buildContext`/
    /// `buildSplitContext` (which embeds its expanded retrieval query twice
    /// in one call), once in `relevantFigure`, once in
    /// `relevantPersonalWriting`. Each inference is a full CoreML forward
    /// pass behind `inferenceLock`, so the repeats were not just wasted CPU;
    /// they queued behind any backfill inference in flight. A tiny memo keyed
    /// on the trimmed text collapses them to one inference per distinct
    /// string. The models are deterministic, so a hit is exact.
    ///
    /// Storage writers that embed thousands of distinct texts once each
    /// (`SeedRunner`'s backfills) use `embedUncached` so they neither churn
    /// this memo nor evict the query a send is about to reuse.
    static func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let cached = cachedVector(for: trimmed) { return cached }
        guard let vector = embedUncached(trimmed) else { return nil }
        remember(vector, for: trimmed)
        return vector
    }

    /// `embed` without the memo -- for one-shot storage embeddings.
    ///
    /// A text the model declines whole is retried as a bounded prefix
    /// (`boundedPrefix`). Long imported journal entries are the case: the
    /// contextual model has a maximum sequence length and throws past it,
    /// and `SeedRunner.runEmbeddingBackfill` reads nil as "transient, retry
    /// next launch" -- so an entry of a few thousand words was declined on
    /// every launch and stayed nil forever, unreachable by the ranker. Rajan
    /// saw the result from the journal thread: "My earliest entry is
    /// September 7" about an archive that begins in 2022. The first two
    /// thousand characters of an entry are a fair vector for the whole; no
    /// vector at all is not.
    static func embedUncached(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let vector = inferVector(trimmed) { return vector }
        let prefix = boundedPrefix(trimmed)
        guard prefix.count < trimmed.count else { return nil }
        return inferVector(prefix)
    }

    /// One pass through the active model, no retry. The retry policy lives in
    /// `embedUncached` so both models share it.
    private static func inferVector(_ text: String) -> [Float]? {
        switch activeModel {
        case .contextual: return contextualEmbed(text)
        case .sentence: return sentenceEmbed(text)
        case .none: return nil
        }
    }

    /// The most characters a retry hands the model. Well under the contextual
    /// model's sequence limit for ordinary English, and long enough that an
    /// entry's opening -- where a journal entry says what it is about -- is
    /// captured whole.
    static let boundedPrefixCharacterLimit = 2_000

    /// `text` cut to at most `limit` characters at a sentence boundary --
    /// the last `.`, `!`, `?` or line break inside the limit -- falling back
    /// to the last space, then to a hard cut. Returns `text` unchanged when
    /// it already fits. Pure, so the macOS harness can assert the boundary
    /// rule without a model loaded.
    static func boundedPrefix(_ text: String, limit: Int = boundedPrefixCharacterLimit) -> String {
        guard text.count > limit else { return text }
        let window = String(text.prefix(limit))
        let terminators = CharacterSet(charactersIn: ".!?\n")
        if let cut = window.rangeOfCharacter(from: terminators, options: .backwards),
           window.distance(from: window.startIndex, to: cut.upperBound) >= limit / 4 {
            return String(window[..<cut.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let space = window.lastIndex(of: " "),
           window.distance(from: window.startIndex, to: space) >= limit / 4 {
            return String(window[..<space])
        }
        return window
    }

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        // vDSP, not a scalar loop: `semanticSearch` scores every embedded
        // highlight in the library per call -- 32,125 highlights across 156
        // seed books (scripts/check-corpus-scale.py, build 52), so ~16.4
        // million multiply-adds at 512 dimensions -- and this is the inner
        // loop of that. Same math, same guards, SIMD-wide.
        let dot = vDSP.dot(a, b)
        let magA = vDSP.sumOfSquares(a)
        let magB = vDSP.sumOfSquares(b)

        let denominator = magA.squareRoot() * magB.squareRoot()
        guard denominator > 0 else { return 0 }
        return dot / denominator
    }

    /// Bulk-decodes a stored vector: one `memcpy` into a correctly aligned
    /// `[Float]`, rather than the per-element `loadUnaligned` closure this
    /// replaced -- which ran 512 times per row, ~16.4 million times per chat
    /// send on a library of 32,125 highlights across 156 seed books
    /// (scripts/check-corpus-scale.py, build 52), for the same result roughly
    /// an order of magnitude slower. `EmbeddingCodec` is now the one decoder
    /// for this and for all three models' own `embedding` getters, so the
    /// ranking loops here and a getter read anywhere else cannot diverge.
    /// Alignment is a non-issue: the destination is Array-allocated and the
    /// source is copied byte-wise, so SwiftData's unaligned `Data` slices are
    /// handled by construction.
    ///
    /// An empty `Data` (the backfills' "tried, nothing to index" marker)
    /// decodes to an empty array; callers skip those. A trailing partial
    /// float, should storage ever hand one back, is ignored rather than read.
    static func decodeVector(_ data: Data) -> [Float] { EmbeddingCodec.decode(data) }

    /// Backfills `highlight.embedding` for any highlight that doesn't have one yet.
    /// Does NOT call `modelContext.save()` — SwiftData's autosave (enabled by
    /// default) typically persists these changes on its own. If the caller needs
    /// the write guaranteed immediately, call `try? modelContext.save()` after
    /// this returns.
    static func backfillMissingEmbeddings(highlights: [Highlight]) {
        for highlight in highlights where highlight.embedding == nil {
            if let vector = embedUncached(highlight.text) {
                highlight.embedding = vector
            }
        }
    }

    // MARK: - Query memo

    /// Bounded FIFO memo of recent query vectors. Sixteen entries covers a
    /// send's handful of distinct strings (the message, its expanded retrieval
    /// form, a follow-up) many times over, and costs 32KB at most.
    private static let queryCacheCapacity = 16
    private static let queryCacheLock = NSLock()
    nonisolated(unsafe) private static var queryCache: [String: [Float]] = [:]
    nonisolated(unsafe) private static var queryCacheOrder: [String] = []

    private static func cachedVector(for key: String) -> [Float]? {
        queryCacheLock.lock()
        defer { queryCacheLock.unlock() }
        return queryCache[key]
    }

    private static func remember(_ vector: [Float], for key: String) {
        queryCacheLock.lock()
        defer { queryCacheLock.unlock() }
        guard queryCache[key] == nil else { return }
        if queryCacheOrder.count >= queryCacheCapacity {
            let evicted = queryCacheOrder.removeFirst()
            queryCache.removeValue(forKey: evicted)
        }
        queryCache[key] = vector
        queryCacheOrder.append(key)
    }

    // MARK: - Inference

    /// Attempts Apple's on-device contextual embedding model. Only used when its
    /// assets are already resident on-device (`hasAvailableAssets`); we never call
    /// `requestAssets` here since that's an async network-capable download and
    /// would break the "simple synchronous call" contract of `embed(_:)`.
    /// One inference at a time. `NLContextualEmbedding` documents no
    /// thread-safety contract, and this shared instance is now genuinely
    /// called concurrently -- SeedRunner's backfills on their own executor,
    /// chat sends, and the journal card's detached selection. Undefined
    /// concurrent behaviour inside a CoreML session is a crash we cannot
    /// catch; a lock turns it into a queue. Contention is brief (one text per
    /// call) and every caller is already off the main thread or tolerates a
    /// short wait.
    private static let inferenceLock = NSLock()

    private static func contextualEmbed(_ text: String) -> [Float]? {
        guard let embedder = sharedContextualEmbedder else {
            return nil
        }
        inferenceLock.lock()
        defer { inferenceLock.unlock() }

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

    /// Apple's older static sentence embedding. Always available on-device for
    /// supported languages (English included); lower quality than the
    /// contextual model but never requires an asset download. Behind the same
    /// lock as the contextual path: `NLEmbedding` documents no thread-safety
    /// contract either, and the shared instance is now reused across callers.
    private static func sentenceEmbed(_ text: String) -> [Float]? {
        guard let embedding = sharedSentenceEmbedding else {
            return nil
        }
        inferenceLock.lock()
        defer { inferenceLock.unlock() }
        guard let vector = embedding.vector(for: text) else {
            return nil
        }
        return vector.map { Float($0) }
    }
}
