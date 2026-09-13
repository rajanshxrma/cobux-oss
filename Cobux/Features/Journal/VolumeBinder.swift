import Foundation

/// Selects and paginates a Bound Volume — the pure half of "the journal is
/// the book he is writing," made literal.
///
/// Everything here is value-in, value-out, so the rules live in the test
/// harness: which passages qualify, how months group, what the title says,
/// and where pages break. The renderer draws what this decides; it decides
/// nothing.
///
/// The selection is governed by the SAME gates that curate every ambient
/// surface — quiet words (whole entry) and the suppression store — plus the
/// existing passage-quality guards, because curation is the app choosing,
/// and the app's choices go through the choke point. Everywhere. Always.
///
/// The ONE gate deliberately not applied: the 14-day floor. The floor exists
/// because *unbidden* surfacing of fresh writing wounds; binding is his
/// deliberate act on a range he chose, and a floor would amputate every
/// season's final fortnight. Recorded here so it is never mistaken for an
/// oversight.
///
/// Vetoes carried from the ruling: no invented titles, themes, or chapter
/// names — months and dates are the only structure; no per-month counts
/// beside sections; nothing in the volume the app wrote except attribution
/// names and the colophon's artifact facts. And no redaction inside included
/// text: his book, his words — the real-names toggle governs the model's
/// retellings in chat, and a volume contains zero app-generated prose.
enum VolumeBinder {
    struct EntrySnapshot: Sendable {
        let id: UUID
        let date: Date
        /// Whether `date` is genuinely known. An import with no parsable date
        /// collapses onto `dateImported`; printing that as the day he wrote
        /// is a claim the book cannot support. No default on purpose — a
        /// default of `true` is exactly how Ebb's opener once laundered an
        /// unknown date into a confident one.
        let dateIsCertain: Bool
        let text: String
    }

    struct Passage: Equatable, Sendable {
        let entryID: UUID
        let date: Date
        let dateIsCertain: Bool
        let month: Int
        let year: Int
        let text: String
        var pairedLine: String?
        var pairedBookTitle: String?
    }

    /// A volume needs at least this many passages — a book, not a pamphlet.
    static let minimumPassages = 12

    /// The half-open range a From/Through month pair names: the first instant
    /// of `from`'s month up to, not including, the first instant of the month
    /// after `through`. Nil when the components are not months (the calendar
    /// would quietly fill a missing month with January), or when the range is
    /// inverted — a `Range` with its bounds crossed is a trap, not an empty
    /// result.
    static func range(from: DateComponents, through: DateComponents,
                      calendar: Calendar = .current) -> Range<Date>? {
        guard from.month != nil, through.month != nil, from.year != nil, through.year != nil,
              let start = calendar.date(from: DateComponents(year: from.year, month: from.month, day: 1)),
              let throughStart = calendar.date(from: DateComponents(year: through.year, month: through.month, day: 1)),
              let end = calendar.date(byAdding: DateComponents(month: 1), to: throughStart),
              start < end
        else { return nil }
        return start..<end
    }

    /// One passage per eligible entry, chronological, grouped by the
    /// calendar. Deterministic: same range + corpus → identical selection.
    ///
    /// An entry whose date is uncertain is filed under the month of the date
    /// it carries (its import date) — the same month the feed's sections and
    /// Ebb's era dividers file it under, so the three surfaces never disagree
    /// about where a piece of writing sits. The passage's own kicker then
    /// says "imported", so the section heading is never the only claim in
    /// view. The alternatives were refused: dropping the entry loses writing
    /// from a season he asked to bind, and an "Undated" chapter is an
    /// invented name, which the ruling vetoes.
    static func select(entries: [EntrySnapshot],
                       from: DateComponents, through: DateComponents,
                       suppressed: Set<UUID>,
                       calendar: Calendar = .current) -> [Passage] {
        guard let range = range(from: from, through: through, calendar: calendar) else { return [] }

        return entries
            .filter { range.contains($0.date) }
            .filter { !suppressed.contains($0.id) }
            .filter { JournalHighlightSelector.maySurface($0.text) }
            .sorted { $0.date < $1.date }
            .compactMap { entry in
                let body = JournalHighlightSelector.stripStamp(entry.text)
                let standalone = Set(body.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) })
                let candidates = JournalHighlightSelector.candidates(in: entry.text)
                guard let best = JournalHighlightSelector.best(
                    from: candidates, standaloneLines: standalone) else { return nil }
                return Passage(entryID: entry.id, date: entry.date,
                               dateIsCertain: entry.dateIsCertain,
                               month: calendar.component(.month, from: entry.date),
                               year: calendar.component(.year, from: entry.date),
                               text: best, pairedLine: nil, pairedBookTitle: nil)
            }
    }

    /// "June – August 2026", "November 2026 – January 2027", "June 2026".
    /// Months are the honest granularity — never day-precise ranges.
    static func title(from: DateComponents, through: DateComponents,
                      calendar: Calendar = .current) -> String {
        let months = calendar.monthSymbols
        guard let fm = from.month, let fy = from.year,
              let tm = through.month, let ty = through.year,
              (1...12).contains(fm), (1...12).contains(tm) else { return "" }
        if fy == ty && fm == tm { return "\(months[fm - 1]) \(fy)" }
        if fy == ty { return "\(months[fm - 1]) – \(months[tm - 1]) \(fy)" }
        return "\(months[fm - 1]) \(fy) – \(months[tm - 1]) \(ty)"
    }

    // -------------------------------------------------------- title page

    /// How the title page sets its title.
    struct TitleLayout: Equatable, Sendable {
        let fontSize: CGFloat
        /// The measured height of the title at `fontSize`, full width.
        let height: CGFloat
        let isSingleLine: Bool
    }

    /// The title face ladder: the approved 30pt, then two steps down.
    static let titleFontSizes: [CGFloat] = [30, 26, 22]

    /// The largest size on the ladder that sets the title on ONE line, else
    /// the floor with its measured two-line height so the renderer can lay
    /// the rule out under it rather than through it.
    ///
    /// The default three-month range names two months and a year; at 30pt
    /// "September – November 2026" needs two lines of a 396pt page, and the
    /// title used to be drawn into a one-line box. `measure` returns the
    /// height of `title` at a font size and the page's full width — the
    /// renderer's real text engine, or a fake in the harness.
    static func titleLayout(_ title: String,
                            sizes: [CGFloat] = titleFontSizes,
                            measure: (_ title: String, _ fontSize: CGFloat) -> CGFloat) -> TitleLayout {
        var floor = TitleLayout(fontSize: sizes.last ?? 22, height: 0, isSingleLine: false)
        for size in sizes {
            let height = measure(title, size)
            // One line of a serif face measures ~1.2em; two measure ~2.4em.
            if height <= size * 1.5 {
                return TitleLayout(fontSize: size, height: height, isSingleLine: true)
            }
            floor = TitleLayout(fontSize: size, height: height, isSingleLine: false)
        }
        return floor
    }

    // ------------------------------------------------------- pagination

    /// What lands on each page. Keep-together per unit: a passage never
    /// splits across pages — these are ≤200-character units by construction.
    enum Block: Equatable, Sendable {
        case monthSection(month: Int, year: Int)
        case passage(index: Int)
    }

    struct Page: Equatable, Sendable {
        var blocks: [Block]
    }

    /// Pure pagination math over unit heights. `height` is asked once per
    /// passage: the harness leaves it at the estimate, and the app passes
    /// the renderer's own `boundingRect` measurement — so the number that
    /// breaks the page is the number that draws it.
    static func paginate(passages: [Passage],
                         pageHeight: CGFloat = 612 - 64 - 72,
                         unitSpacing: CGFloat = 28,
                         height: (Passage) -> CGFloat = VolumeBinder.estimatedHeight(of:)) -> [Page] {
        var pages: [Page] = []
        var current: [Block] = []
        var used: CGFloat = 0
        var lastMonth: (Int, Int)? = nil

        func flush() {
            if !current.isEmpty { pages.append(Page(blocks: current)); current = [] }
            used = 0
        }

        for (index, passage) in passages.enumerated() {
            let key = (passage.month, passage.year)
            if lastMonth == nil || lastMonth! != key {
                // A month section opens on its own page.
                flush()
                current.append(.monthSection(month: passage.month, year: passage.year))
                flush()
                lastMonth = key
            }
            let height = height(passage)
            if used > 0 && used + unitSpacing + height > pageHeight {
                flush()
            }
            if used > 0 { used += unitSpacing }
            current.append(.passage(index: index))
            used += height
        }
        flush()
        return pages
    }

    /// Kicker + set body at 13pt/1.45 line height in a 288pt column, plus the
    /// paired line's extra when present. The harness's stand-in for the
    /// renderer's measurement, and an estimate that errs generous: measured
    /// prose at this size fits 31–38 characters a line, so 30 is assumed (the
    /// first version assumed 44, and pages it filled ran into the page number
    /// in print). The harness checks this against the real face.
    static func estimatedHeight(of passage: Passage) -> CGFloat {
        let charsPerLine: CGFloat = 30
        let lineHeight: CGFloat = 13 * 1.45
        let bodyLines = max(1, ceil(CGFloat(passage.text.count) / charsPerLine))
        var height: CGFloat = 8 + 6 + bodyLines * lineHeight
        if let paired = passage.pairedLine {
            let pairedLines = max(1, ceil(CGFloat(paired.count) / (charsPerLine + 6)))
            height += 12 + 1 + 8 + pairedLines * (11 * 1.4) + 4 + 9
        }
        return height
    }
}
