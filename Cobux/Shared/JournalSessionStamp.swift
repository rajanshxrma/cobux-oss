import Foundation

/// The line a journal writing session opens with.
///
/// Rajan's rule: the automatic time should also carry the date, in
/// "January 1, 2026" form — except when that would just repeat a date the
/// entry already establishes, where the bare time is enough.
///
/// This lives here, shared, because there are THREE places that start a
/// journal entry — the in-app composer, the Siri/Shortcuts intent, and the
/// Cobux app inside iMessage — and only the composer implemented the rule.
/// The other two stamped a bare `"h:mm a"` with no date on any day, so an
/// entry dictated to Siri or written from Messages silently lost the date
/// formatting he asked for. Three private copies of a formatting rule is how
/// that happens; one shared implementation is how it stops.
enum JournalSessionStamp {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    /// Separate from `timeFormatter` so the same-day rule can drop the date
    /// alone while keeping the time.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    /// - Parameter previousSessionDate: when the entry was last written to.
    ///   `nil` for a brand-new entry, which always carries the full date.
    /// - Parameter ambient: weather/place, when it is fresh and enabled. It is
    ///   appended as TEXT, not stored as metadata, and that is the whole design:
    ///   journal entries are never deletable, so hidden per-entry metadata would
    ///   be permanent by construction and would ride into every backup and
    ///   export. This is characters in his own editor that he watches appear and
    ///   can delete with the backspace key like any other word he wrote.
    static func text(at date: Date,
                     previousSessionDate: Date?,
                     ambient: AmbientContext? = nil) -> String {
        let time = timeFormatter.string(from: date)
        let tail = ambient?.stampTail ?? ""
        if let previousSessionDate,
           Calendar.current.isDate(previousSessionDate, inSameDayAs: date) {
            return time + tail
        }
        return dateFormatter.string(from: date) + " · " + time + tail
    }

    /// Whether a line is one of these stamps.
    ///
    /// Load-bearing, and it exists because three separate files carried private
    /// copies of a stamp-matching regex -- the feed's `previewText`, another
    /// site in the same file, and `JournalHighlightSelector.stripStamp`. All
    /// three matched only `"Month D, YYYY · h:mm AM"`, so the moment a stamp
    /// gained a ` · 72° · Berlin` tail, every one of them would stop
    /// recognising it and every card in the feed would show the stamp line
    /// instead of the writing. This file's own doc comment already says how
    /// that class of bug happens: "three private copies of a formatting rule".
    /// One shared matcher is how it stops.
    ///
    /// Accepts every historical form as well as the new one, because entries
    /// written years ago must keep being recognised.
    static func isStampLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let matcher else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return matcher.firstMatch(in: trimmed, range: range) != nil
    }

    /// Compiled ONCE, at first use, instead of once per line examined.
    ///
    /// The old form built the pattern string and handed it to
    /// `range(of:options:.regularExpression)` on every single call. That call
    /// compiles a fresh ICU regex each time -- by far the most expensive thing
    /// in it -- and this function is not called occasionally: the journal feed's
    /// `previewText` walks a card's leading lines through it, inside a
    /// `ForEach`, for every card, on every body evaluation, and
    /// `JournalHighlightSelector` does the same again. Every one of those
    /// compiled the identical pattern from scratch and threw it away.
    ///
    /// `nonisolated(unsafe)` is honest rather than lazy: `NSRegularExpression`
    /// is documented immutable and thread-safe once constructed, and nothing
    /// here ever reassigns it. The alternative -- an actor or a lock -- would
    /// add contention to a pure function to protect a value that cannot change.
    ///
    /// Optional, not `try!`: a pattern that somehow failed to compile must not
    /// take the app down on a journal card. `isStampLine` then answers `false`,
    /// which degrades to "this line is ordinary writing" -- the card shows one
    /// extra line, and nothing is lost or hidden.
    private nonisolated(unsafe) static let matcher: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^(\w+ \d{1,2}, \d{4} · )?\d{1,2}:\d{2}\s?(AM|PM)"#
            + #"( · -?\d+°)?( · [\p{L}][\p{L} .'’-]*)*$"#,
        options: [.caseInsensitive]
    )
}
