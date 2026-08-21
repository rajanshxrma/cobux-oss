import Foundation

/// Fixes the wrong-citation-chip bug: `SearchService.swift` previously derived "referenced
/// books" from retrieval (`unionBooks ∩ referencedBookIDs`) — which books were *searched*,
/// not which books the model actually *answered from*. Once the prompt-caching commit
/// (`d475eb2`) put every book's chapter summaries into the always-cached prefix, the model
/// could correctly answer from a book that retrieval never selected, producing a correct
/// answer with wrong citation chips (medical-book chips on a relationship-advice answer).
///
/// The fix asks the model to declare its own sources at the end of its reply — ground
/// truth about what it actually used, not an inference from retrieval. Cost is ~15 output
/// tokens per turn (~$0.0002), and it fixes both the general chat path and Symposium mode,
/// which shared the identical bug via the older `buildContext`.
public enum CitationResolver {

    /// Appended to the system prompt so every reply ends with a parseable, invisible tag.
    /// `PromptAssembly` is responsible for actually splicing this into the real prompt.
    public static let instructionSuffix = """
    At the very end of your reply, on its own line, list the exact titles of every book you \
    actually drew on to answer — nothing else, no commentary. Format exactly as:
    <sources>Title One|Title Two</sources>
    If you didn't use any specific book (e.g. you only answered from general knowledge or \
    couldn't find anything relevant), emit <sources></sources> with nothing between the tags. \
    Never list a title you did not actually use, and never omit one you did.
    """

    public struct ParsedReply: Sendable, Equatable {
        public let displayText: String
        public let declaredTitles: [String]
    }

    /// Strips the `<sources>...</sources>` tag from the raw model output and returns both
    /// the clean display text and the declared titles, trimmed and de-duplicated.
    public static func parse(rawReply: String) -> ParsedReply {
        guard let openRange = rawReply.range(of: "<sources>", options: .backwards),
              let closeRange = rawReply.range(of: "</sources>", options: .backwards),
              openRange.upperBound <= closeRange.lowerBound else {
            return ParsedReply(displayText: rawReply.trimmingCharacters(in: .whitespacesAndNewlines), declaredTitles: [])
        }

        let inner = String(rawReply[openRange.upperBound..<closeRange.lowerBound])
        let titles = inner
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var display = rawReply
        display.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
        let cleaned = display.trimmingCharacters(in: .whitespacesAndNewlines)

        var seen = Set<String>()
        let deduped = titles.filter { seen.insert($0.lowercased()).inserted }

        return ParsedReply(displayText: cleaned, declaredTitles: deduped)
    }

    /// The invariant that must hold once this fix is live: the model can only declare a
    /// title that actually exists in the user's library. A hallucinated or mis-typed title
    /// from the model is dropped rather than shown as a chip — silently, not as an error,
    /// since a missing chip is a much smaller failure than a wrong or nonexistent one.
    public static func resolve(declaredTitles: [String], libraryTitles: [String]) -> [String] {
        // `uniqueKeysWithValues:` traps on a duplicate key -- and it isn't just
        // theoretical, it already happened: a re-entrant seeding race (fixed
        // separately) could write two `Book` rows sharing a title, and this ran
        // on EVERY chat reply, so a device with a duplicate crashed on every
        // single message. `uniquingKeysWith:` keeps the first occurrence and
        // never traps, which is exactly the previously-fixed duplicate-Book
        // scenario's correct behavior (both entries map to the same real title
        // anyway).
        let libraryLower = Dictionary(libraryTitles.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let resolved = declaredTitles.compactMap { libraryLower[$0.lowercased()] }
        // The runtime invariant Phase 0 promised: citedTitles ⊆ booksThatContributedToThisPrompt.
        // `libraryTitles` IS that contributing set -- callers are responsible for scoping it
        // correctly (the whole library for general/Symposium chat, one book for a scoped
        // thread) -- so this should be true by construction. Asserting it here (debug-only,
        // no-op in release) turns a future regression in this function, or a caller passing
        // the wrong candidate set, into an immediate crash in a debug build instead of a
        // silently wrong citation chip reaching a real user.
        assert(
            Set(resolved).isSubset(of: Set(libraryTitles)),
            "CitationResolver.resolve returned a title absent from its own libraryTitles input"
        )
        return resolved
    }
}
