import Foundation
import NaturalLanguage

/// On-device cloze-card generation — the free tier that makes Quiz usable at real scale
/// on Utkarsh's capped key and works on his iPhone 13 (no Apple Intelligence required,
/// just `NaturalLanguage`, already a dependency via the app's `EmbeddingService`).
///
/// Cobux's medical seed highlights are authored in a consistent shape: an optional
/// `headword — body` split, plus 4-5 author-curated tags that name the key concepts in
/// that highlight. One highlight is really 4-6 independently testable facts. The old
/// Claude-generated question bank covered ~8% of that (9 questions per ~28-highlight
/// Robbins chapter). Cloze generation mines the tags/text structure directly instead —
/// roughly 5,000 cards at $0.00 versus ~700 paid, because it needs no model call at all.
public struct ClozeSourceHighlight: Sendable, Equatable {
    public let id: String
    public let text: String
    public let tags: [String]

    public init(id: String, text: String, tags: [String]) {
        self.id = id
        self.text = text
        self.tags = tags
    }
}

public struct ClozeCard: Sendable, Equatable {
    public let sourceHighlightID: String
    /// The visible stem with the answer span replaced by `ClozeGenerator.blankMarker`.
    public let stem: String
    public let answer: String
    public let distractors: [String]
    /// True when fewer than 3 real distractors were found — the card degrades to a
    /// free-recall prompt (typed/spoken answer, embedding-graded) rather than a forced MCQ.
    public let isFreeRecall: Bool
}

public enum ClozeGenerator {

    public static let blankMarker = "_____"

    /// A candidate answer span is rejected below this length — not a real testable fact.
    static let minAnswerLength = 3
    /// A blank consuming more than this fraction of the stem gives away too little context.
    static let maxBlankFraction = 0.40
    static let minDistractorsForMCQ = 3
    static let maxCardsPerHighlight = 3
    static let distractorSimilarityRange: ClosedRange<Float> = 0.55...0.85

    // MARK: Headword / body split

    static func splitHeadwordBody(_ text: String) -> (headword: String?, body: String) {
        for separator in [" — ", " – ", " - "] {
            if let range = text.range(of: separator) {
                let headword = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let body = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard !headword.isEmpty, !body.isEmpty else { continue }
                return (headword, body)
            }
        }
        return (nil, text)
    }

    // MARK: Candidate span extraction + scoring

    struct Candidate {
        let span: String
        let score: Int
    }

    /// Finds capitalized-word runs and named entities via `NLTagger` as fallback
    /// candidates for highlights whose tags don't literally appear in the body text.
    static func nlCandidateSpans(in body: String) -> [String] {
        var spans: [String] = []
        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass])
        tagger.string = body

        // NLTag for the .nameType scheme returns `.other` (a real, non-nil value) for
        // ordinary words that aren't part of any recognized name — only these three
        // specific tags actually mean "this is a named entity."
        let entityTags: Set<NLTag> = [.personalName, .placeName, .organizationName]
        tagger.enumerateTags(in: body.startIndex..<body.endIndex, unit: .word, scheme: .nameType, options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if let tag, entityTags.contains(tag) {
                spans.append(String(body[range]))
            }
            return true
        }

        // Capitalized single words the NER pass might miss (acronyms, proper nouns NER
        // doesn't recognize as a named-entity category, e.g. "LC3", "TORCH").
        tagger.enumerateTags(in: body.startIndex..<body.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            let word = String(body[range])
            if tag == .noun, word.count > 1, word.first?.isUppercase == true {
                spans.append(word)
            }
            return true
        }

        return spans
    }

    static func scoredCandidates(body: String, tags: [String], headword: String?) -> [Candidate] {
        var candidates: [Candidate] = []
        let bodyLower = body.lowercased()

        // +3: tags are author-curated key concepts — the highest-confidence source,
        // and the one that requires no NLP at all.
        for tag in tags {
            guard bodyLower.contains(tag.lowercased()) else { continue }
            candidates.append(Candidate(span: tag, score: 3))
        }

        // +2: named entities / capitalized spans not already covered by a tag match.
        let tagSpansLower = Set(candidates.map { $0.span.lowercased() })
        for span in nlCandidateSpans(in: body) where !tagSpansLower.contains(span.lowercased()) {
            candidates.append(Candidate(span: span, score: 2))
        }

        // +1 short-span bonus, -5 for the headword itself (would make the blank trivial
        // since the headword is often still visible as this card's own title elsewhere).
        var scored = candidates.map { c -> Candidate in
            var score = c.score
            if c.span.split(separator: " ").count <= 4 { score += 1 }
            if let headword, c.span.caseInsensitiveCompare(headword) == .orderedSame { score -= 5 }
            return Candidate(span: c.span, score: score)
        }

        // -5 if the same exact span (case-insensitive) occurs more than once in the body —
        // blanking one occurrence would leave the answer sitting in plain sight elsewhere.
        let occurrenceCounts = Dictionary(grouping: scored, by: { $0.span.lowercased() }).mapValues(\.count)
        scored = scored.map { c in
            let occurrences = countOccurrences(of: c.span, in: body)
            return occurrences > 1 ? Candidate(span: c.span, score: c.score - 5) : c
        }
        _ = occurrenceCounts // computed for clarity/debuggability, not otherwise consumed

        // De-duplicate by span (case-insensitive), keeping the highest score.
        var best: [String: Candidate] = [:]
        for c in scored {
            let key = c.span.lowercased()
            if let existing = best[key], existing.score >= c.score { continue }
            best[key] = c
        }

        // Score first, then span as the tie-break. `Dictionary.values` has no
        // stable order and the old sort compared only score, so equal-scored
        // candidates shuffled between RUNS -- `prefix(maxCardsPerHighlight)`
        // then sometimes kept one and sometimes the other, which surfaced as
        // a coin-flip test failure at the ship gate. A quiz deck that deals
        // differently on identical input is the same bug wearing a nicer
        // name; generation is now a pure function of its inputs.
        return best.values.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.span < $1.span
        }
    }

    static func countOccurrences(of span: String, in text: String) -> Int {
        guard !span.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: span, options: .caseInsensitive, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }

    // MARK: Distractor selection

    /// Picks distractors from sibling highlights' tags in the same chapter, using a
    /// caller-supplied similarity function (real usage: `EmbeddingService.cosineSimilarity`
    /// over `NLContextualEmbedding` vectors — injected here so this stays host-testable
    /// with a deterministic fake rather than requiring real embeddings in unit tests).
    static func distractors(
        forAnswer answer: String,
        siblingTags: [String],
        similarity: (String, String) -> Float,
        max: Int = 4
    ) -> [String] {
        var seen = Set<String>([answer.lowercased()])
        var result: [String] = []
        for tag in siblingTags {
            guard seen.insert(tag.lowercased()).inserted else { continue }
            let score = similarity(answer, tag)
            guard distractorSimilarityRange.contains(score) else { continue }
            result.append(tag)
            if result.count >= max { break }
        }
        return result
    }

    // MARK: Public entry point

    /// Generates up to `maxCardsPerHighlight` cloze cards from one highlight, using its
    /// sibling highlights (same chapter) as the distractor pool.
    public static func generate(
        from highlight: ClozeSourceHighlight,
        siblingHighlights: [ClozeSourceHighlight],
        similarity: (String, String) -> Float
    ) -> [ClozeCard] {
        let (headword, body) = splitHeadwordBody(highlight.text)
        let candidates = scoredCandidates(body: body, tags: highlight.tags, headword: headword)
        guard !candidates.isEmpty else { return [] }

        let siblingTags = siblingHighlights
            .filter { $0.id != highlight.id }
            .flatMap(\.tags)

        var cards: [ClozeCard] = []
        for candidate in candidates.prefix(maxCardsPerHighlight) {
            let answer = candidate.span
            guard answer.count >= minAnswerLength else { continue }

            let occurrences = countOccurrences(of: answer, in: body)
            guard occurrences >= 1 else { continue }

            var stem = body
            while let range = stem.range(of: answer, options: .caseInsensitive) {
                stem.replaceSubrange(range, with: blankMarker)
            }

            let blankFraction = Double(answer.count) / Double(max(body.count, 1))
            guard blankFraction <= maxBlankFraction else { continue }

            let picked = distractors(forAnswer: answer, siblingTags: siblingTags, similarity: similarity)
            let isFreeRecall = picked.count < minDistractorsForMCQ

            cards.append(ClozeCard(
                sourceHighlightID: highlight.id,
                stem: stem,
                answer: answer,
                distractors: picked,
                isFreeRecall: isFreeRecall
            ))
        }
        return cards
    }
}
