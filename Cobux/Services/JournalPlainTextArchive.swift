import Foundation

/// The journal rendered as one plain-text document — the copy that is still
/// readable in 2036 with no Cobux, no SwiftData, and nothing that has to be
/// decoded first.
///
/// Rajan's ask, verbatim: "there should be an option to create adn sincu cobux
/// journals to apple notes. a separte cobux folder that cobux app creates so if
/// by chance the ocbux journals are lost misatkenly thhey still in apple notes."
///
/// The folder half of that is not buildable and he has been told so: there is no
/// Notes framework in the iOS SDK and no note entity in AppIntents, so no app can
/// create a folder in Apple Notes or write into one. What IS buildable is the
/// other side of the same bridge — Apple's own Shortcuts app ships "Create Note"
/// and "Append to Note", so Cobux hands over the words and Apple's action does
/// the writing. This file is the words. `JournalArchiveIntent` is the handover.
///
/// Everything here is a pure function over plain values. Nothing in this file
/// touches SwiftData, `@Model`, or an actor — `Entry` is flattened from a
/// `PersonalWritingEntry` by the caller, on the thread of the context that
/// fetched it, and only plain values cross from there. That is the same
/// boundary `JournalAutoExportService` draws and for the same reason.
enum JournalPlainTextArchive {
    /// One entry as plain values. Deliberately not a `PersonalWritingEntry`:
    /// a `@Model` object belongs to the context that fetched it and cannot be
    /// carried past a suspension point, and the whole point of this type is
    /// that the rendering below is free to run anywhere.
    struct Entry: Sendable, Equatable {
        /// `modifiedDate ?? dateImported` — "when did this happen", the same
        /// single ordering date `JournalListView.sortedEntries` uses and for
        /// the reason its comment gives: an entry composed here has both
        /// equal, an imported one only reliably has `dateImported`.
        var date: Date
        var title: String
        /// The RAW source string, not `JournalSourceFamily`'s collapsed label.
        /// That type's own doc comment draws the line this follows: the family
        /// is a display decision ("the raw strings stay untouched in the
        /// data"), and an archive is data. "Notes(personal)" tells a reader
        /// in ten years which folder a note came out of; "notes" does not.
        var source: String
        var text: String
    }

    /// The line that ends every record.
    ///
    /// Three em dashes, not a rule of hyphens: a line starting with `-` is
    /// something Apple Notes may decide to turn into a bullet, and a separator
    /// that the destination reformats is not a separator. Nothing else in a
    /// journal entry ever looks like this line, so it is also what a future
    /// script would split on.
    static let recordSeparator = "\u{2014}\u{2014}\u{2014}"

    /// Sortable, unambiguous, and locale-proof: `en_US_POSIX` is not decoration
    /// here. A `DateFormatter` with a fixed `dateFormat` and the *user's* locale
    /// renders a Buddhist-calendar device's 2026 as 2569 and a Japanese-calendar
    /// device's as 8 — in the one field whose entire job is to sort and to still
    /// mean something in a decade.
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// The weekday, in the reader's own language — the opposite locale choice
    /// from `stampFormatter`, on purpose. The stamp is for sorting and the
    /// weekday is for reading, and it is the one part of a date a person cannot
    /// work out from the digits. Apple's own Journal leads with it.
    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter
    }()

    /// The whole document, oldest first.
    ///
    /// Oldest first is load-bearing, not a preference: the destination action is
    /// "Append to Note", which writes at the bottom, so ascending order is the
    /// only order in which a note assembled over months reads as one continuous
    /// book rather than as a stack of batches each running backwards.
    static func render(_ entries: [Entry]) -> String {
        entries
            .sorted { $0.date < $1.date }
            .map(record)
            .joined(separator: "\n\n")
    }

    /// One entry: a header line, the words exactly as they were written, and the
    /// separator.
    ///
    /// The body is **verbatim**, including the session stamp the app opens every
    /// entry with. The feed strips that stamp (`JournalListView.previewText`)
    /// because the row's title is already a time and two times stacked up read
    /// as a rendering fault. This is not the feed. The stamp carries the weather
    /// and the place when he had them on (`JournalSessionStamp` appends them as
    /// TEXT, by design), and a backup that quietly edits his words to look tidier
    /// is not a backup. A repeated time is a cosmetic cost; a lost line is not
    /// recoverable.
    ///
    /// The separator goes AFTER each record rather than between them, so the next
    /// scheduled append lands under a rule instead of butting onto the last
    /// sentence of the last one.
    private static func record(_ entry: Entry) -> String {
        var lines = [header(for: entry)]
        // Only for writing that came from somewhere else. The absence of a
        // provenance line is what "written in Cobux" looks like — the same
        // decision `JournalSourceFamily` makes for the pill, for the same
        // reason: it needs no explanation.
        if entry.source != "journal", !entry.source.isEmpty {
            lines.append("from \(entry.source)")
        }
        let body = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            lines.append("")
            lines.append(body)
        }
        lines.append("")
        lines.append(recordSeparator)
        return lines.joined(separator: "\n")
    }

    private static func header(for entry: Entry) -> String {
        let stamp = "\(stampFormatter.string(from: entry.date)) \u{00B7} \(weekdayFormatter.string(from: entry.date))"
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // A titleless entry is the normal case here, not an edge one: the
        // composer leaves `title` empty and lets the writing speak, and
        // `JournalListView.displayTitle` falls back to the time for exactly
        // that reason. The stamp alone IS the header then — never a dangling
        // em dash with nothing after it.
        guard !title.isEmpty else { return stamp }
        return "\(stamp) \u{2014} \(title)"
    }
}
