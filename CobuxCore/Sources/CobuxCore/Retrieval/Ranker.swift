import Foundation

/// Fixes the retrieval half of the citation bug (the other half is `CitationResolver`).
/// The old `SearchService.semanticSearch` did a flat top-12 over `books.flatMap(\.highlights)`
/// with no per-book cap and an absolute `minimumSimilarity: 0.4` floor that was a no-op —
/// mean-pooled `NLContextualEmbedding` vectors of arbitrary English sit in a narrow
/// 0.7-0.95 cosine band, so 0.4 rejected almost nothing. With the two medical textbooks
/// holding 1,310 of ~1,375 highlights (~95% of the corpus), any untargeted query drowned
/// the 4 self-help books' highlights in clinical text on sheer volume.
public struct RankableItem: Sendable, Equatable {
    public let id: String
    public let bookID: String
    public let rawScore: Float

    public init(id: String, bookID: String, rawScore: Float) {
        self.id = id
        self.bookID = bookID
        self.rawScore = rawScore
    }
}

public enum Ranker {

    /// z-normalizes similarity **within each book** before merging pools, so a book's raw
    /// score distribution (clinical text clusters differently from self-help prose) can't
    /// let one book's items dominate purely because its highlights all score in a tighter,
    /// higher absolute band.
    static func zNormalized(_ items: [RankableItem]) -> [RankableItem] {
        let byBook = Dictionary(grouping: items, by: \.bookID)
        var result: [RankableItem] = []
        result.reserveCapacity(items.count)

        for (_, group) in byBook {
            let scores = group.map { Double($0.rawScore) }
            let mean = scores.reduce(0, +) / Double(scores.count)
            let variance = scores.reduce(0) { $0 + pow($1 - mean, 2) } / Double(scores.count)
            let stddev = sqrt(variance)

            for item in group {
                let z: Float
                if stddev > 0.0001 {
                    z = Float((Double(item.rawScore) - mean) / stddev)
                } else {
                    // A single-item book, or a book whose highlights are all equidistant
                    // from the query — z-score is undefined, so keep the item eligible
                    // (0 = "average") rather than silently dropping a whole book to zero.
                    z = 0
                }
                result.append(RankableItem(id: item.id, bookID: item.bookID, rawScore: z))
            }
        }
        return result
    }

    /// Ranks candidates with a per-book cap and a relative (not absolute) threshold.
    /// - Parameters:
    ///   - items: raw-score candidates, one entry per highlight, already computed via
    ///     cosine similarity or any other scorer.
    ///   - topK: overall result size ceiling.
    ///   - relativeThresholdDelta: an item must score within this many normalized-score
    ///     units of the single best item in the whole pool to survive — replaces the old
    ///     absolute `0.4` floor, which was a no-op for this embedding model.
    public static func rank(
        items: [RankableItem],
        topK: Int,
        relativeThresholdDelta: Float = 1.0
    ) -> [RankableItem] {
        guard !items.isEmpty else { return [] }

        let bookCount = Set(items.map(\.bookID)).count
        let perBookCap = Int(ceil(Double(topK) / Double(max(bookCount, 1)))) + 2

        let normalized = zNormalized(items).sorted { $0.rawScore > $1.rawScore }
        guard let topScore = normalized.first?.rawScore else { return [] }

        var perBookCount: [String: Int] = [:]
        var result: [RankableItem] = []

        for item in normalized {
            guard result.count < topK else { break }
            guard item.rawScore >= topScore - relativeThresholdDelta else { continue }
            let countSoFar = perBookCount[item.bookID, default: 0]
            guard countSoFar < perBookCap else { continue }
            perBookCount[item.bookID] = countSoFar + 1
            result.append(item)
        }
        return result
    }
}
