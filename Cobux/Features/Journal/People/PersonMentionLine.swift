import Foundation

/// The one sentence in an entry that names a person — found live, at render
/// time, by a string search. Pure Foundation, no SwiftUI, no SwiftData, so it
/// runs in the qgate harness unchanged.
///
/// This is what makes a person's page a page ABOUT them rather than a filtered
/// feed (`docs/people-in-the-journal.md` §3): under each entry card, in the
/// passage face, the first sentence that says their name, verbatim. No stored
/// offset — the search is a few microseconds per entry and the text is the
/// only truth, so a later edit to the entry can never leave a stale quote.
///
/// Rules:
/// - Session stamps are machinery, not writing. Every stamp line
///   (`JournalSessionStamp.isStampLine`) is dropped before the search, not only
///   the head one — "Continue Entry" appends a stamp mid-text.
/// - A form matches as a whole word, case-insensitively: "Priya" is found in
///   "Priya's" and "with Priya," and never inside "Priyanka".
/// - Sentences come from Foundation's sentence enumeration, so "Dr." and
///   "e.g." do not split a sentence the way a naive `.`-split would.
/// - Under six words the sentence is a fragment, not a sentence, and the
///   result is nil rather than a quote that reads like a caption.
/// - A very long sentence is cut at a word boundary after the mention and
///   marked with "…" so the card never carries a paragraph.
enum PersonMentionLine {
    /// Fewer words than this and a sentence is a fragment; the page shows
    /// nothing under the card rather than a stub.
    static let minimumWords = 6
    /// Longest quote the card carries before it is trimmed to a fragment
    /// ending in "…".
    static let maximumCharacters = 240

    /// The first sentence in `text` that names the person, or nil.
    ///
    /// `forms` is the display name plus confirmed aliases; any of them counts.
    static func first(naming forms: [String], in text: String) -> String? {
        let patterns = forms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap(wholeWordMatcher)
        guard !patterns.isEmpty else { return nil }
        let body = stripStamps(text)
        guard !body.isEmpty else { return nil }

        var found: String?
        (body as NSString).enumerateSubstrings(
            in: NSRange(location: 0, length: (body as NSString).length),
            options: [.bySentences, .localized]
        ) { sentence, _, _, stop in
            guard let sentence else { return }
            let candidate = sentence
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { return }
            let range = NSRange(candidate.startIndex..., in: candidate)
            guard let hit = patterns.lazy
                .compactMap({ $0.firstMatch(in: candidate, range: range) })
                .first else { return }
            guard wordCount(candidate) >= minimumWords else { return }
            found = trimmed(candidate, around: hit.range)
            stop.pointee = true
        }
        return found
    }

    /// Every session stamp line removed, the rest joined as it was.
    static func stripStamps(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !JournalSessionStamp.isStampLine(String($0)) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private

    /// One compiled matcher per form, held across calls. `NSCache` is
    /// thread-safe, so the detached task that walks a page's entries and
    /// the harness share it without a lock; a page's forms are one or two
    /// strings, so the cache is tiny and the compile happens once per name.
    nonisolated(unsafe) private static let matchers = NSCache<NSString, NSRegularExpression>()

    private static func wholeWordMatcher(_ form: String) -> NSRegularExpression? {
        let key = form.lowercased() as NSString
        if let cached = matchers.object(forKey: key) { return cached }
        let escaped = NSRegularExpression.escapedPattern(for: form)
        // Letters and digits on either side mean it is part of a longer word;
        // an apostrophe after ("Priya's") is still the name.
        // lint-ok: formatter-constructed-per-render -- compiled once per form and cached above; never on a render path
        guard let matcher = try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}])" + escaped + "(?![\\p{L}\\p{N}])",
            options: [.caseInsensitive]) else { return nil }
        matchers.setObject(matcher, forKey: key)
        return matcher
    }

    private static func wordCount(_ sentence: String) -> Int {
        sentence.split(whereSeparator: \.isWhitespace).count
    }

    /// Cuts an over-long sentence to a window that keeps the mention, ending
    /// (and, when the head was cut, starting) on a word boundary with "…".
    private static func trimmed(_ sentence: String, around mention: NSRange) -> String {
        let ns = sentence as NSString
        guard ns.length > maximumCharacters else { return sentence }
        // Keep the mention inside the window: start a little before it when
        // it sits deep in the sentence, otherwise from the head.
        let lead = 60
        var start = max(0, mention.location - lead)
        var end = min(ns.length, start + maximumCharacters)
        if end == ns.length { start = max(0, end - maximumCharacters) }
        // Word boundaries: never cut inside a word.
        if start > 0 {
            let head = ns.substring(with: NSRange(location: start, length: end - start))
            if let space = head.firstIndex(where: \.isWhitespace) {
                // UTF-16 offsets throughout: `start` and `end` index the
                // NSString, and a Character count would drift on emoji.
                start += head.utf16.distance(from: head.utf16.startIndex, to: space) + 1
            }
        }
        if end < ns.length {
            let window = ns.substring(with: NSRange(location: start, length: end - start))
            if let space = window.lastIndex(where: \.isWhitespace) {
                end = start + window.utf16.distance(from: window.utf16.startIndex, to: space)
            }
        }
        var piece = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if start > 0 { piece = "…" + piece }
        if end < ns.length { piece += "…" }
        return piece
    }
}
