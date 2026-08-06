import Foundation

/// Restructures the chat system prompt so the cacheable stable prefix and the citation
/// candidate pool can never diverge again. `d475eb2` (prompt caching) put every book's
/// full chapter summaries into an unconditional, always-cached prefix — good for cache
/// hit rate, but it let the model answer from books that were structurally ineligible
/// for a citation chip (the model could read a book's summary without that book ever
/// entering the retrieval-derived `unionBooks` set). The fix: cache only a lightweight
/// chapter **index** (titles, not full summaries) in the stable prefix — cheap, still a
/// byte-stable cache key, and it doesn't let a book "answer" without also being visible
/// to the citation logic. Full chapter summaries move to the dynamic, relevance-gated
/// section, which is exactly the section `Ranker` scores per turn.
public struct BookIndexEntry: Sendable, Equatable {
    public let title: String
    public let author: String
    public let chapterTitles: [String]

    public init(title: String, author: String, chapterTitles: [String]) {
        self.title = title
        self.author = author
        self.chapterTitles = chapterTitles
    }
}

public enum PromptAssembly {

    /// The byte-stable cacheable prefix: base instructions + a lightweight index of every
    /// book's title/author/chapter titles (NOT full summaries). Identical across a
    /// session regardless of the user's question, so Anthropic's prompt caching applies —
    /// but thin enough that it can't smuggle in an entire book's content the way the old
    /// unconditional full-summary block did.
    public static func stablePrefix(baseInstructions: String, library: [BookIndexEntry]) -> String {
        var out = baseInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        out += "\n\n## User's Book Library — Index\n"
        for book in library {
            out += "\n- \"\(book.title)\" by \(book.author)"
            if !book.chapterTitles.isEmpty {
                out += " (\(book.chapterTitles.count) chapters: \(book.chapterTitles.joined(separator: "; ")))"
            }
        }
        out += "\n\n" + CitationResolver.instructionSuffix
        return out
    }

    /// The dynamic, per-turn section: only the relevance-ranked highlights/summaries for
    /// *this* question, scored by `Ranker`. This is where retrieval and "what the model
    /// can actually answer from" stay coupled — the invariant the old unconditional
    /// stable-prefix block broke.
    public static func dynamicContext(rankedSnippets: [(bookTitle: String, text: String)]) -> String {
        guard !rankedSnippets.isEmpty else {
            return "## Relevant passages for this question\n(none matched closely enough — answer only from general knowledge if appropriate, and declare no sources.)"
        }
        var out = "## Relevant passages for this question\n"
        for snippet in rankedSnippets {
            out += "\n### From \"\(snippet.bookTitle)\"\n\(snippet.text)\n"
        }
        return out
    }

    /// Minimum prefix length below which Anthropic's prompt caching doesn't apply at all
    /// (Sonnet 5's cacheable-prefix floor is 1024 tokens; this is a rough char-based proxy
    /// since CobuxCore has no tokenizer dependency — real token counts should use the
    /// Anthropic `count_tokens` endpoint at the call site, not this estimate).
    public static let approxCacheableCharFloor = 3000

    public static func isLikelyCacheable(stablePrefix: String) -> Bool {
        stablePrefix.count >= approxCacheableCharFloor
    }
}
