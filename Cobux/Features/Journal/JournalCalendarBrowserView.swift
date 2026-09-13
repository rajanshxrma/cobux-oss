import SwiftUI

/// A single "the user asked to browse the whole calendar" event.
///
/// Exists for exactly the reason `ComposeSession` does, and its doc comment
/// says it better than a second paraphrase would: a Bool bound to
/// `.sheet(isPresented:)` can only ever transition false -> true once before
/// something has to set it back, so a dropped presentation latches it true and
/// every later tap is a silent no-op. An identity is new on every tap. The
/// linter enforces this (`latched-sheet-bool`), which is why the browser ships
/// its own session type rather than leaving the call site to invent a Bool.
struct JournalCalendarBrowserSession: Identifiable {
    let id = UUID()
}

/// The whole journal as a calendar — every month, back to the first thing he
/// ever wrote, with a date he can put a finger on.
///
/// `JournalCalendarStrip` is one month at a time and answers "what did this
/// month look like". It is deliberately not a date picker: a month is a single
/// row of bars, the numerals are sparse on purpose, and paging back four years
/// is 48 swipes. His ask was the other half — *"multiple months calendar
/// complete... so a user can search thru month and go back years and click on a
/// specific date"*. So this is the browser, and the strip stays exactly the
/// instrument it is. Neither one is the other's replacement.
///
/// **What this surface refuses to be.** A calendar is the single easiest place
/// in an app to accidentally build a guilt machine: intensity shading turns
/// into a contribution graph, a per-month count turns sixty months into a
/// league table, and a red or hollow empty day turns a quiet week into an
/// accusation. The standing ruling is that Cobux never grades him
/// (`docs/deferred.md`, the no-completion-state rulings). So there are exactly
/// two states here — a day has writing, or it is a plain numeral — and there is
/// no third. No per-month totals, no streak, no volume ramp, no "you missed
/// N days", no colour that means "worse".
///
/// Intensity is not an oversight; it is a scope line. It belongs on the strip,
/// where the frame is ONE month and a bar's height is read against its
/// neighbours in the same month. Spread the same encoding across five years of
/// months and the reader stops seeing a habit and starts seeing a scorecard.
///
/// **Ink and paper, same as the strip.** A day with writing is the month's own
/// hue (`Color.cobuxMonthHue`) — the numeral in the hue, on a soft capsule of
/// it. A day without is a quiet numeral and nothing else. Today carries a thin
/// hue ring in both cases, which is a *you are here* locator every calendar
/// has, not a nudge. Same `Capsule()` primitive the strip draws its days with,
/// so the two surfaces read as one section rather than two components that
/// happen to be about dates.
///
/// **Tapping an empty day does nothing.** That is the strip's live behaviour
/// (`JournalCalendarStrip.jump(to:)` guards on `isWritten`) and what an empty
/// day SHOULD do is a question still open for Rajan in `docs/deferred.md`. It
/// is matched here structurally rather than by a guard: a day without writing
/// is never wrapped in a `Button` at all, so there is no tap to swallow, no
/// disabled-button dimming, and nothing for VoiceOver to announce as an
/// unavailable control. The guard is kept anyway in `select(_:)`, so the two
/// files would still agree if a future edit changed one of them.
///
/// **Speed is the ship gate, so nothing here fetches.** See `written` and
/// `Slot` for the arithmetic; the short version is that a cell's whole render
/// cost is one `Set` lookup and one `Date ==`, and no month is built until it
/// is scrolled to.
///
/// **One upward timeline.** Rajan, ledger N62: *"all months are displayed top
/// being the recent month but the dates still go down ... I want the dates to
/// be also displayed from down to up, up being the latest date ... it's gonna
/// be the best way for a person's ongoing life and growth display."* So the
/// page has ONE direction of time. Today is the first cell at the very top,
/// and every scroll downward is a step back -- across months (newest first, as
/// before) and now also within them: a month's last week is its top row and
/// its first week is its bottom row. Weekday COLUMNS keep their left-to-right
/// order, so the header above the scroll still tells the truth about every
/// row, and a week still reads as a week. The seam between two months is
/// therefore continuous: scrolling down past "5 4 3 2 1" of September you meet
/// August's title and then "31 30", which is exactly the day before.
///
/// Two consequences, both deliberate. The blanks that align day 1 to its
/// weekday now sit at the bottom-left of a month and the blanks after its last
/// day at the top-right, which is just the same padding seen from the other
/// end. And the current month begins at today: its future days are not drawn,
/// because the top of the page IS now, and a row of numbers above "now" would
/// make the reader scroll past days that have not happened to reach the one
/// that has. (A day that has not happened is not information -- the strip
/// draws it as nothing for the same reason.) That is not a grade on the
/// future; it is where the timeline starts.
///
/// The month's title stays ABOVE its grid. The alternative -- the name at the
/// foot, so the month "grows up out of it" -- was weighed and refused: on open
/// the first thing under the weekday header would be an unlabelled row of
/// numerals, the year separators would have to move to the foot as well, and
/// the title's hue would prime the cells only after they had been read. A
/// heading is read before its body in whichever direction the body runs.
struct JournalCalendarBrowserView: View {
    /// The same per-day map `JournalCalendarStrip` renders from, handed
    /// straight down from `JournalListView`.
    ///
    /// **This is the fetch, and it has already happened.** `JournalListView`
    /// caches `dayStats` in `@State` and rebuilds it only when
    /// `dayStatsSignature` moves — precisely because recomputing it per render
    /// splits every entry's text and faults every attachment relationship, and
    /// that was measured as the reason typing in the search field stuttered.
    /// Re-fetching here would pay that cost a second time on the tap that is
    /// supposed to render a frame, and would create a second source of truth
    /// about which days have writing — a browser and a strip disagreeing about
    /// that is a worse bug than either being slow. A dictionary is
    /// copy-on-write, so handing it over costs nothing.
    let dayStats: [Date: JournalDayStat]

    /// Jump-to-day. Only days with writing ever fire it. `nil` keeps the whole
    /// browser inert, which is what a preview wants.
    var onDaySelected: ((Date) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// Every day that has writing, day-granular, built ONCE.
    ///
    /// The keys of `dayStats` are already `startOfDay` values (see
    /// `JournalListView.recomputeDayStats`), and every date this file
    /// constructs is put through the same `calendar.startOfDay(for:)` that
    /// `JournalCalendarStrip.daysIn` uses — so membership is an exact hash
    /// lookup, not a same-day comparison, and the two calendars can never
    /// disagree about what one day is.
    ///
    /// A `Set` rather than reading `dayStats` directly at render time for the
    /// obvious reason and one less obvious one: `JournalDayStat` carries word
    /// counts and attachment flags this surface deliberately does not show, and
    /// a view that cannot reach them cannot drift into showing them.
    @State private var written: Set<Date> = []

    /// The month the earliest entry falls in — the floor of the whole browser.
    ///
    /// Bounded to real writing on purpose. An endless scroll into months that
    /// predate his first entry would be an infinite corridor of blank days,
    /// which is both slow and the exact guilt shape this file is avoiding.
    @State private var earliestMonth: Date = Date()

    /// Newest year first, for the jump rail.
    @State private var years: [Int] = []

    /// What the list renders: newest month first, running back to
    /// `earliestMonth`. Rebuilt only when the anchor year changes.
    @State private var rows: [MonthRow] = []

    /// Where the list starts. The current year means "from this month", any
    /// earlier year means "from that December".
    ///
    /// This is a JUMP, not a filter — see `rebuildRows()` for why that
    /// distinction is what keeps the browser fast.
    @State private var anchorYear: Int = Calendar.current.component(.year, from: Date())

    private let calendar = Calendar.current

    /// Compared with `==` per cell rather than `calendar.isDateInToday`, which
    /// is a `DateComponents` round trip. Both sides are `startOfDay`, so the
    /// cheap comparison is also the exact one.
    private let today = Calendar.current.startOfDay(for: Date())

    /// One row of the grid. Scales with Dynamic Type like everything else here,
    /// and at the default size a cell is ~50 x 42pt in a 390pt screen — the
    /// whole cell is the tap target, not just the numeral, which is the lesson
    /// the strip paid for three times ("i wrote a big ass reminder on that").
    @ScaledMetric(relativeTo: .body) private var cellHeight: CGFloat = 42
    /// The day mark itself. A `Capsule` at a square frame is a circle, which is
    /// how this stays the strip's own shape vocabulary without a second shape.
    @ScaledMetric(relativeTo: .body) private var markSize: CGFloat = 34

    var body: some View {
        NavigationStack {
            // Inside the `NavigationStack`, not wrapping it — same reason
            // `JournalEntryComposeView` gives: Done stays reachable if a relock
            // lands while this sheet is open. `autoPromptsWhenTopmost` keeps its
            // default `true` because nothing is ever presented on top of this
            // sheet.
            //
            // The gate is not optional here. This browser reveals WHEN he
            // wrote, across years, at a glance — which is journal information
            // in its own right, and would otherwise be readable over his
            // shoulder on a locked journal. `armed: !dayStats.isEmpty` is the
            // same condition `JournalListView` passes as `!entries.isEmpty`,
            // computed from data already in hand: a journal with nothing in it
            // has nothing behind the gate, and must not demand Face ID.
            JournalLocked(armed: !dayStats.isEmpty) {
                browser
            }
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        // Keyed on the map's size rather than run bare, so a journal that gains
        // an entry while this sheet is somehow still up rebuilds instead of
        // going stale. Within one presentation it runs exactly once: the sheet
        // is driven by `.sheet(item:)`, so re-opening builds a fresh view with
        // a fresh identity rather than reusing this one.
        .task(id: dayStats.count) { load() }
    }

    // ------------------------------------------------------------- structure

    private var browser: some View {
        VStack(spacing: 0) {
            if years.count > 1 {
                yearRail
            }
            weekdayHeader
            Divider()
                .overlay(Color.cobuxLine)
            monthList
        }
    }

    /// Years, newest first. Present only when there is more than one, because a
    /// rail with a single chip is chrome that navigates nowhere.
    ///
    /// A horizontal scroll that is a SIBLING of the vertical one, never a child
    /// of it — two scroll owners inside each other fight over the same gestures,
    /// which is the documented journal-editor shake and what the
    /// `scroll-in-scroll` lint exists to catch.
    private var yearRail: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(years, id: \.self) { year in
                    Button {
                        guard year != anchorYear else { return }
                        anchorYear = year
                        rebuildRows()
                    } label: {
                        Text(String(year))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(year == anchorYear
                                             ? Color.cobuxAccent : Color.secondary)
                            .padding(.horizontal, CobuxSpacing.chipH)
                            .padding(.vertical, CobuxSpacing.chipV)
                            .background(year == anchorYear
                                        ? Color.cobuxAccent.opacity(0.14)
                                        : Color.cobuxSurface2,
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Jump to \(String(year))")
                }
            }
            .padding(.horizontal, CobuxSpacing.screenMargin)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
    }

    /// Once, above the scroll, rather than once per month. Twelve repetitions of
    /// the same seven letters per year is the kind of noise the strip was
    /// rebuilt four times to get rid of.
    ///
    /// Symbols come from the calendar and are rotated by `firstWeekday`, so a
    /// Monday-first locale gets a Monday-first grid without a second code path.
    private var weekdayHeader: some View {
        // Identified by POSITION, not by the letter. In English the symbols are
        // S M T W T F S -- two Ss and two Ts -- and `id: \.self` over that
        // silently hands two columns the same identity, which SwiftUI resolves
        // by dropping one and warning at runtime. The array is read once into a
        // local rather than through the computed property seven times.
        let symbols = weekdaySymbols
        return HStack(spacing: 2) {
            ForEach(symbols.indices, id: \.self) { index in
                Text(symbols[index])
                    .font(.caption2)
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, CobuxSpacing.screenMargin)
        .padding(.bottom, 8)
        .accessibilityHidden(true)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    /// Newest month at the top, running back through the years -- and inside
    /// each month, newest week at the top too (see `MonthGrid`), so the whole
    /// list is one line of time that runs upward.
    ///
    /// The direction is not arbitrary: the journal's own feed is newest-first
    /// (`JournalListView.dateSections` sorts `$0.key > $1.key`), so scrolling
    /// down means going back in time on both screens. It also happens to be the
    /// fastest possible arrangement — the month he most likely wants is the
    /// first item, so opening the browser needs no programmatic scroll into a
    /// lazy stack at all, and a lazy stack that is never asked to scroll to an
    /// unrealised row never has to realise the rows in between. Reversing the
    /// weeks inside a month changes none of that: the first row of the lazy
    /// stack is still the current month, and its first grid row is now the
    /// week that contains today.
    private var monthList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(rows) { row in
                    if let yearLabel = row.yearLabel {
                        yearSeparator(yearLabel)
                    }
                    MonthGrid(month: row.id,
                              title: row.title,
                              hue: Color.cobuxMonthHue(row.monthNumber,
                                                       dark: colorScheme == .dark),
                              written: written,
                              today: today,
                              cellHeight: cellHeight,
                              markSize: markSize,
                              colorScheme: colorScheme,
                              onSelect: select)
                }
            }
            .padding(.horizontal, CobuxSpacing.screenMargin)
            .padding(.top, 14)
            .padding(.bottom, 44)
        }
        // A new scroll for a new anchor, which lands at the top for free. The
        // alternative — asking a `ScrollViewReader` to scroll to a month four
        // years back — makes SwiftUI realise every month in between, which is
        // the one operation a lazy stack is here to avoid.
        .id(rows.first?.id)
    }

    /// The year, once, where the list crosses into it. With this here, month
    /// titles stay bare ("December", "November") instead of every one of them
    /// carrying a year the reader already knows — the same economy the strip's
    /// `monthLabel` reaches for when it drops the year inside the current one.
    private func yearSeparator(_ label: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(CobuxTypography.display(colorScheme, size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color.cobuxLine)
                .frame(height: 1)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    // --------------------------------------------------------------- actions

    /// Jump the feed to a day, then get out of the way.
    ///
    /// The guard is `JournalCalendarStrip.jump(to:)`'s, kept verbatim in
    /// behaviour: an empty day has nowhere to jump to. It is redundant today
    /// (an empty day is never wrapped in a `Button`) and deliberately so — two
    /// independent reasons a guilt-free rule holds is one more than one.
    private func select(_ day: Date) {
        guard written.contains(day) else { return }
        onDaySelected?(day)
        dismiss()
    }

    // ------------------------------------------------------------------ load

    /// One pass over the day map, at open, and never again.
    ///
    /// Everything expensive about a calendar is done here: the set of written
    /// days, the floor month, the year list. What is left for the render path
    /// is a `Set` lookup and a `Date ==` per cell.
    private func load() {
        var days = Set<Date>(minimumCapacity: dayStats.count)
        for (day, stat) in dayStats where stat.isWritten {
            days.insert(day)
        }
        written = days

        let thisMonth = startOfMonth(Date())
        earliestMonth = days.min().map(startOfMonth) ?? thisMonth
        let firstYear = calendar.component(.year, from: earliestMonth)
        let lastYear = calendar.component(.year, from: thisMonth)
        years = firstYear <= lastYear ? Array((firstYear...lastYear).reversed()) : [lastYear]
        anchorYear = lastYear
        rebuildRows()
    }

    /// The month rows, newest first, from the anchor back to the earliest.
    ///
    /// A jump rather than a filter, and the difference is the whole performance
    /// story. A filter ("show me 2023") would cut the list to twelve months and
    /// stop him scrolling from January 2023 into December 2022, which breaks
    /// "search thru month". A scroll-to ("take me to 2023") would make the lazy
    /// stack realise every month between here and there. Moving the START of
    /// the list does neither: the row he asked for is item zero, everything
    /// older is below him and is built only if he keeps scrolling, and nothing
    /// above him exists to be realised.
    private func rebuildRows() {
        let thisMonth = startOfMonth(Date())
        let currentYear = calendar.component(.year, from: thisMonth)
        var anchor = thisMonth
        if anchorYear < currentYear,
           let december = calendar.date(from: DateComponents(year: anchorYear, month: 12)) {
            anchor = december
        }
        let span = (calendar.dateComponents([.month], from: earliestMonth, to: anchor).month ?? 0) + 1
        let symbols = calendar.standaloneMonthSymbols

        var built: [MonthRow] = []
        built.reserveCapacity(max(1, span))
        var previousYear: Int?
        for offset in 0..<max(1, span) {
            guard let month = calendar.date(byAdding: .month, value: -offset, to: anchor) else { continue }
            let components = calendar.dateComponents([.year, .month], from: month)
            guard let year = components.year, let number = components.month else { continue }
            // The month name from the calendar's own symbols rather than a
            // `DateFormatter` per row: localised identically, and free.
            let title = symbols.indices.contains(number - 1) ? symbols[number - 1] : ""
            built.append(MonthRow(id: month,
                                  title: title,
                                  monthNumber: number,
                                  // Only where the list crosses a year, and
                                  // always on the first row so the reader is
                                  // never guessing which year they opened in.
                                  yearLabel: year != previousYear ? String(year) : nil))
            previousYear = year
        }
        rows = built
    }

    private func startOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    // ------------------------------------------------------------- the month

    private struct MonthRow: Identifiable, Equatable {
        /// The first instant of the month — also the scroll identity.
        let id: Date
        let title: String
        let monthNumber: Int
        /// Set only on the row that opens a year.
        let yearLabel: String?
    }

    /// One month, weekday-aligned, last week first.
    ///
    /// Its own `View` rather than a `@ViewBuilder` function so the grid
    /// arithmetic runs in `init` — once, when the month scrolls in — instead of
    /// on every evaluation of the parent's body. Nothing in here touches
    /// SwiftData, a `DateFormatter`, or `dayStats`.
    ///
    /// The weeks are laid out in the ordinary top-down way first -- leading
    /// blanks, the days, trailing blanks, multiples of seven -- and then the
    /// ROWS are reversed. Nothing inside a row moves, so a Monday-first locale
    /// keeps its Monday-first columns and the padding lands where the ruling in
    /// the type's doc comment says it must: before day 1 at the bottom-left,
    /// after the last day at the top-right, for every `firstWeekday`.
    private struct MonthGrid: View {
        let month: Date
        let title: String
        let hue: Color
        let written: Set<Date>
        let today: Date
        let cellHeight: CGFloat
        let markSize: CGFloat
        let colorScheme: ColorScheme
        let onSelect: (Date) -> Void

        /// A real day in the grid. `number` is carried rather than asked for
        /// per cell: inside a month, day-of-month IS the offset plus one, so
        /// the numeral costs no `Calendar` call at all.
        private struct Slot: Equatable {
            let date: Date
            let number: Int
        }

        /// The month's weeks, LAST WEEK FIRST, each exactly seven wide with
        /// `nil` for the blanks that pad the month's first and last weeks. The
        /// reversal is done here, once, so `body` walks the array in order and
        /// has no arithmetic to get wrong.
        private let weeks: [[Slot?]]

        init(month: Date, title: String, hue: Color, written: Set<Date>,
             today: Date, cellHeight: CGFloat, markSize: CGFloat,
             colorScheme: ColorScheme, onSelect: @escaping (Date) -> Void) {
            self.month = month
            self.title = title
            self.hue = hue
            self.written = written
            self.today = today
            self.cellHeight = cellHeight
            self.markSize = markSize
            self.colorScheme = colorScheme
            self.onSelect = onSelect

            let calendar = Calendar.current
            let weekday = calendar.component(.weekday, from: month)
            // Locale-correct by construction: the offset is measured against
            // the calendar's own `firstWeekday`, so a Monday-first region gets
            // a Monday-first month with no second implementation.
            let leading = (weekday - calendar.firstWeekday + 7) % 7
            var dayCount = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
            // The current month ends at today. `today` is `startOfDay`, `month`
            // is the month's first instant, and the anchor is never later than
            // this month, so the only month that contains `today` is the one
            // that gets cut -- and it is cut to today's own number, which makes
            // today the last slot built and therefore the first cell drawn.
            // Every other month is in the past and keeps every day.
            if let interval = calendar.dateInterval(of: .month, for: month),
               interval.contains(today) {
                dayCount = min(dayCount, calendar.component(.day, from: today))
            }

            var slots: [Slot?] = Array(repeating: nil, count: leading)
            slots.reserveCapacity(leading + dayCount + 6)
            for offset in 0..<dayCount {
                // `startOfDay` on top of the day arithmetic, exactly as
                // `JournalCalendarStrip.daysIn` does it. Adding days to a
                // month's first instant lands on midnight everywhere except a
                // DST-skip morning, and that one exception is the difference
                // between a day matching the written set and silently not.
                let day = calendar.date(byAdding: .day, value: offset, to: month)
                    .map { calendar.startOfDay(for: $0) }
                slots.append(day.map { Slot(date: $0, number: offset + 1) })
            }
            while slots.count % 7 != 0 { slots.append(nil) }
            // Chunk into weeks, then reverse the WEEKS -- never the days inside
            // one. `stride` over a length that is a multiple of seven gives
            // exactly `slots.count / 7` full rows.
            self.weeks = stride(from: 0, to: slots.count, by: 7)
                .map { Array(slots[$0..<$0 + 7]) }
                .reversed()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                // The month in its own hue. `cobuxMonthHue`'s whole premise is
                // that the journal "gains colour life that changes as you scroll
                // back through time" — this is the one screen where you scroll
                // back through five years of it at once.
                Text(title)
                    .font(CobuxTypography.display(colorScheme, size: 17, weight: .semibold))
                    .foregroundStyle(hue)

                // Top row is the month's newest week (in the current month,
                // the week that holds today), bottom row is the week of the
                // 1st. Identified by position: a row's slots are stable for
                // the life of the view, and two rows can never be equal.
                VStack(spacing: 2) {
                    ForEach(weeks.indices, id: \.self) { row in
                        HStack(spacing: 2) {
                            ForEach(0..<7, id: \.self) { column in
                                cell(weeks[row][column])
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        /// A day with writing is a button; a day without is not a control at
        /// all. See the type's doc comment for why that is structural rather
        /// than a `.disabled(...)`.
        @ViewBuilder
        private func cell(_ slot: Slot?) -> some View {
            if let slot {
                if written.contains(slot.date) {
                    Button {
                        onSelect(slot.date)
                    } label: {
                        mark(slot, hasEntries: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityLabel(slot, hasEntries: true))
                    .accessibilityHint("Opens that day in your journal")
                } else {
                    mark(slot, hasEntries: false)
                        .accessibilityLabel(accessibilityLabel(slot, hasEntries: false))
                }
            } else {
                // Keeps the week's geometry without pretending to be a date.
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: cellHeight)
                    .accessibilityHidden(true)
            }
        }

        /// Two states, and there is deliberately no third.
        ///
        /// A day without writing is a plain quiet numeral: no ring, no hollow
        /// circle, no red, no "nothing written" label sitting under it. A future
        /// day never reaches here at all -- the current month is built up to
        /// today and no later (see `init`) -- so there is no "you have not
        /// written here yet" to draw on a day that has not happened, which is
        /// the purest form of the thing this file will not do.
        private func mark(_ slot: Slot, hasEntries: Bool) -> some View {
            let isToday = slot.date == today
            return Text("\(slot.number)")
                .font(CobuxTypography.display(colorScheme, size: 15,
                                              weight: hasEntries ? .semibold : .regular))
                .monospacedDigit()
                // A two-digit numeral at AX5 must shrink rather than truncate:
                // "31" rendered as "3" would be a wrong date, not just an ugly
                // one.
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(hasEntries ? hue : Color.secondary.opacity(0.55))
                .frame(maxWidth: .infinity, minHeight: cellHeight)
                .background {
                    if hasEntries {
                        // `maxWidth/maxHeight`, never a fixed `width/height`.
                        // A column is roughly a seventh of the screen -- about
                        // 50pt -- and `markSize` is a @ScaledMetric that reaches
                        // ~80pt at the largest accessibility sizes. Pinned to a
                        // fixed size it would grow straight through its column
                        // and collide with its neighbours; capped, it is a 34pt
                        // circle at ordinary sizes and a taller pill at extreme
                        // ones, and it can never overlap the day beside it.
                        Capsule()
                            .fill(hue.opacity(0.16))
                            .frame(maxWidth: markSize, maxHeight: markSize)
                    }
                }
                .overlay {
                    // Today, in both states. A locator, not a nudge: it says
                    // where you are, the way the strip's baseline numeral does.
                    // The ring breathes -- the one thing on this page that
                    // moves, and it moves in BOTH states, so it stays a
                    // locator (a "you are here" that is awake, the way a map's
                    // own dot is) and never becomes a third state or a nudge
                    // at an unwritten day. Its own view, behind `.equatable()`,
                    // for the reason `SigilMark` exists: a parent pass must
                    // not be able to reach a `repeatForever` mid-flight.
                    if isToday {
                        TodayRing(hue: hue, markSize: markSize)
                            .equatable()
                    }
                }
                // The whole cell, not the 34pt mark inside it. The strip
                // shipped with an 8pt target inside a 44pt minimum and he
                // reported the calendar as unclickable three times.
                .contentShape(Rectangle())
        }

        private func accessibilityLabel(_ slot: Slot, hasEntries: Bool) -> String {
            let date = slot.date.formatted(date: .complete, time: .omitted)
            // Says what IS there, and stays silent about what is not — the
            // spoken surface follows the same rule as the drawn one.
            return hasEntries ? "\(date), has writing" : date
        }
    }

    /// Today's ring, breathing. Same `Capsule().strokeBorder(hue, 1.5)` at the
    /// same capped frame as before -- nothing about its shape or its two-state
    /// rule moved; only its opacity now eases 0.55 ↔ 1.0 over 2.5 s.
    ///
    /// `Equatable` on its two inputs and applied with `.equatable()`, so the
    /// month grid re-evaluating (a Dynamic Type change, a rebuild after
    /// `anchorYear` moves) does not re-apply the animated modifier inside a
    /// transaction -- the exact bug that killed the Sigil's float three builds
    /// running (`CobuxSigilView.swift`, "Why it stopped"). The phase is reset
    /// without animation and re-armed a turn later on every appearance, the
    /// way `SigilMark.restartAmbientMotion()` does it, because a `LazyVStack`
    /// cell that scrolls away and back may keep its `@State` while its
    /// in-flight animation was dropped.
    ///
    /// Reduce Motion is a gate, not a slowdown: the ring is drawn at full
    /// opacity with no animation attached at all, and a switch mid-flight
    /// lands it there with a `nil` animation. First frame: one stored Bool
    /// read, no work.
    private struct TodayRing: View, Equatable {
        let hue: Color
        let markSize: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.scenePhase) private var scenePhase
        @State private var breathing = false

        static func == (lhs: TodayRing, rhs: TodayRing) -> Bool {
            lhs.hue == rhs.hue && lhs.markSize == rhs.markSize
        }

        var body: some View {
            Capsule()
                .strokeBorder(hue, lineWidth: 1.5)
                .frame(maxWidth: markSize, maxHeight: markSize)
                .opacity(reduceMotion ? 1 : (breathing ? 1 : 0.55))
                .animation(reduceMotion ? nil
                           : .easeInOut(duration: 2.5).repeatForever(autoreverses: true),
                           value: breathing)
                .onAppear(perform: restartBreath)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { restartBreath() }
                }
        }

        @MainActor private func restartBreath() {
            guard !reduceMotion else { return }
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { breathing = false }
            Task { @MainActor in breathing = true }
        }
    }
}
