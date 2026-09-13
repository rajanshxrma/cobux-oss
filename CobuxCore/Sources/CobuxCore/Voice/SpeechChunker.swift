import Foundation

/// Cuts a streamed chat reply into speakable sentence chunks as it arrives, so voice mode can
/// start talking on the first sentence instead of waiting for the whole reply — this is the
/// single biggest perceived-latency lever per Fable's voice architecture ruling
/// (see the plan's "Fable's ruling — voice companion architecture" section).
///
/// Two things it must never speak: the trailing `<sources>...</sources>` block (citation
/// metadata `ChatView.completeReveal` already strips before display — `SpeechChunker` withholds
/// it from speech the same way, including a tag that arrives split across multiple network
/// deltas) and raw markdown syntax (belt-and-suspenders with the prompt instruction that asks
/// the model not to use markdown in spoken replies).
public final class SpeechChunker {

    /// A sentence long enough to speak as its own utterance is cut immediately once its
    /// terminator arrives. Text with no terminator gets force-cut at this length so one run-on
    /// sentence can't stall the whole session — Fable named this a judgment call to tune
    /// against real use, not a measured constant.
    public static let fallbackCutLength = 250

    /// A chunk shorter than this (an abbreviation artifact like "Dr." or "e.g." mistaken for a
    /// sentence end) merges into the next chunk instead of being spoken as its own utterance —
    /// unless it's the last chunk of the reply, where there's nothing left to merge into.
    public static let minSpeakableLength = 25

    private static let sourcesTag = "<sources>"

    /// Confirmed speakable text not yet cut into chunks — always tag-free by construction.
    private var pending = ""
    /// Text that might still turn into `sourcesTag`, held back until it's disproven or confirmed.
    private var tagWatch = ""
    /// A too-short trailing chunk carried forward to merge with the next one.
    private var carry = ""
    private var sourcesReached = false
    private var fullRawText = ""

    public init() {}

    /// The complete raw text seen so far, tag included — for handing to
    /// `CitationResolver.parse` once the stream ends so voice turns get `referencedBooks`
    /// persisted exactly like text turns.
    public var rawText: String { fullRawText }

    /// Feed one network delta in. Returns zero or more chunks now safe to speak.
    public func ingest(_ delta: String) -> [String] {
        guard !delta.isEmpty else { return [] }
        fullRawText += delta
        guard !sourcesReached else { return [] }

        tagWatch += delta
        absorbConfirmedText()
        return extractChunks(final: false)
    }

    /// Call once the stream ends. Flushes whatever's left — including a genuinely-short final
    /// chunk, since nothing remains to merge it with — and returns it as speakable chunks.
    public func finish() -> [String] {
        if !sourcesReached {
            pending += tagWatch
            tagWatch = ""
        }
        let chunks = extractChunks(final: true)
        return chunks
    }

    // MARK: - Tag withholding

    /// Moves everything in `tagWatch` that can no longer become `sourcesTag` into `pending`.
    /// If the full tag is found, everything from its start onward is discarded from speech
    /// forever (it's still captured in `fullRawText` for the citation parse).
    private func absorbConfirmedText() {
        if let tagRange = tagWatch.range(of: Self.sourcesTag) {
            pending += String(tagWatch[..<tagRange.lowerBound])
            tagWatch = ""
            sourcesReached = true
            return
        }

        let maxPrefixLength = Self.sourcesTag.count - 1
        let searchStart = tagWatch.index(tagWatch.endIndex, offsetBy: -min(maxPrefixLength, tagWatch.count))
        var confirmedEnd = tagWatch.endIndex
        var cursor = searchStart
        while cursor < tagWatch.endIndex {
            let candidate = String(tagWatch[cursor...])
            if Self.sourcesTag.hasPrefix(candidate) {
                confirmedEnd = cursor
                break
            }
            cursor = tagWatch.index(after: cursor)
        }

        pending += String(tagWatch[..<confirmedEnd])
        tagWatch = String(tagWatch[confirmedEnd...])
    }

    // MARK: - Sentence extraction

    private static let terminators: Set<Character> = [".", "!", "?"]
    /// Punctuation clause breaks are preferred over a bare word boundary when force-cutting a
    /// long unterminated run — a plain space is far more common near the budget edge and would
    /// otherwise always win, defeating the point of preferring a real clause break.
    private static let punctuationClauseBreaks: Set<Character> = [",", ";", ":"]

    private func extractChunks(final: Bool) -> [String] {
        var results: [String] = []

        while true {
            guard let cut = nextCutIndex(final: final) else { break }
            let raw = String(pending[pending.startIndex..<cut])
            pending = String(pending[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
            emit(sanitize(raw), final: false, into: &results)
        }

        if final {
            let remainder = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            pending = ""
            if !remainder.isEmpty || !carry.isEmpty {
                emit(sanitize(remainder), final: true, into: &results)
            }
        }

        return results
    }

    /// Finds the next safe cut point in `pending`: a sentence terminator confirmed by trailing
    /// whitespace (so "Mr." mid-stream isn't cut before we know if more text follows), or —
    /// once `pending` has run past `fallbackCutLength` with no terminator — the last clause
    /// break within budget, or a hard cut at the budget as a last resort.
    private func nextCutIndex(final: Bool) -> String.Index? {
        var searchIndex = pending.startIndex
        while searchIndex < pending.endIndex {
            let char = pending[searchIndex]
            if Self.terminators.contains(char) {
                let after = pending.index(after: searchIndex)
                if after == pending.endIndex {
                    // Terminator is right at the buffer's edge — could be the whole
                    // sentence, or more punctuation ("...", "?!") could still arrive.
                    if final { return after }
                    break
                }
                if pending[after].isWhitespace {
                    return pending.index(after: after)
                }
            }
            searchIndex = pending.index(after: searchIndex)
        }

        guard !final, pending.count > Self.fallbackCutLength else { return nil }

        let budgetIndex = pending.index(pending.startIndex, offsetBy: Self.fallbackCutLength)
        var punctuationIndex: String.Index?
        var wordBoundaryIndex: String.Index?
        var scan = pending.startIndex
        while scan <= budgetIndex {
            let char = pending[scan]
            if Self.punctuationClauseBreaks.contains(char) {
                punctuationIndex = pending.index(after: scan)
            } else if char.isWhitespace {
                wordBoundaryIndex = pending.index(after: scan)
            }
            scan = pending.index(after: scan)
        }
        return punctuationIndex ?? wordBoundaryIndex ?? budgetIndex
    }

    private func emit(_ text: String, final: Bool, into results: inout [String]) {
        let combined = carry.isEmpty ? text : "\(carry) \(text)"
        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !final && trimmed.count < Self.minSpeakableLength {
            carry = trimmed
            return
        }

        carry = ""
        results.append(trimmed)
    }

    // MARK: - Markdown stripping

    /// Defensive cleanup in case the model emits markdown despite the spoken-style prompt
    /// instruction telling it not to — strips the syntax and speaks the inner text.
    /// Compiled ONCE, at first use, instead of eleven times per spoken chunk.
    ///
    /// The old form handed a pattern STRING to a per-call helper, so every one
    /// of the eleven rules below compiled a fresh ICU regex -- by far the most
    /// expensive thing in the pass -- and `sanitize` runs on every chunk cut
    /// out of a streaming reply, i.e. continuously for the length of a voice
    /// turn. Eleven compilations per chunk, thrown away each time, on the one
    /// path whose entire purpose is starting to talk sooner.
    ///
    /// No `nonisolated(unsafe)`, and that is the point rather than an omission:
    /// `NSRegularExpression` is documented immutable and thread-safe once
    /// constructed, which is why Foundation declares it `Sendable`, so a shared
    /// `let` of them needs nothing said about it. Adding the annotation earns a
    /// warning ("unnecessary for a constant with `Sendable` type") and, worse,
    /// implies a hazard the type does not have.
    ///
    /// Order is preserved and load-bearing -- `**bold**` has to be stripped
    /// before `*italic*`, or the italic rule eats one asterisk of each pair.
    /// A pattern that somehow failed to compile drops out of the table, which
    /// is precisely what the old `try?` did per call: that one rule is skipped
    /// and every other still applies.
    private static let markdownRules: [(regex: NSRegularExpression, template: String)] = {
        let specs: [(pattern: String, template: String, options: NSRegularExpression.Options)] = [
            (#"\*\*(.+?)\*\*"#, "$1", []),
            (#"__(.+?)__"#, "$1", []),
            (#"\*(.+?)\*"#, "$1", []),
            (#"(?<!\w)_(.+?)_(?!\w)"#, "$1", []),
            (#"`([^`]+)`"#, "$1", []),
            (#"\[([^\]]+)\]\([^\)]+\)"#, "$1", []),
            (#"^#{1,6}\s*"#, "", [.anchorsMatchLines]),
            (#"^\s*[-*]\s+"#, "", [.anchorsMatchLines]),
            (#"^\s*\d+\.\s+"#, "", [.anchorsMatchLines]),
            (#"\n+"#, " ", []),
            (#" {2,}"#, " ", []),
        ]
        return specs.compactMap { spec in
            guard let regex = try? NSRegularExpression(pattern: spec.pattern, options: spec.options) else {
                return nil
            }
            return (regex, spec.template)
        }
    }()

    private func sanitize(_ text: String) -> String {
        var result = text

        for rule in Self.markdownRules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = rule.regex.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: rule.template)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
