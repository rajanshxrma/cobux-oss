import SwiftUI

/// What one day of writing weighed, for one calendar cell.
///
/// A count alone lies: one 2,000-word entry at 2 AM is not three one-liners,
/// and an entry-count scale caps out at three and then flattens everything
/// above it. Volume is the honest signal.
struct JournalDayStat: Equatable {
    var words: Int = 0
    var entries: Int = 0
    var seconds: Int = 0
    var hasAttachment: Bool = false

    var isWritten: Bool { entries > 0 }
}

/// A page from a reading journal — ink on paper, where the ink is his writing.
///
/// Three shapes preceded this one, and the reasoning matters:
///
/// 1. A literal calendar with a 5pt dot per day. A dot is a boolean, so a day
///    with one line looked exactly like a day with eight.
/// 2. A port of Sisyphus's `velocity` strip: days running continuously,
///    weekday alignment dropped on purpose, four months at once. That fixed
///    intensity — and was ported from a *desktop dashboard* without checking a
///    phone. At 390pt a 31-day run wraps into ragged rows: a first row of
///    nothing but empty circles, a partial second, one stranded bubble. He
///    called it congested beside a screenshot of Sisyphus looking clean, and
///    both things were true at once.
/// 3. A plain 7-column grid. Correct, and generic.
///
/// This is 3 with the ideas that make it Cobux's rather than any calendar's,
/// per Fable's design ruling:
///
/// - **Absence is paper, not a hole.** An unwritten day is a faint numeral on
///   the background. No ring, no hollow circle. Half the congestion in both
///   screenshots was thirty-one rings of nothing.
/// - **Runs are continuous ink.** Consecutive written days merge into one
///   capsule across a week row, so the grid shows the *shape* of a habit
///   instead of scattered dots. Week rows break runs, which is honest —
///   calendar semantics survive.
/// - **Intensity is volume.** Tier thresholds are the 33rd and 66th percentile
///   of his own nonzero days, so the scale stays true as his habits change
///   rather than being hardcoded to somebody's guess.
/// - **Set in the type he writes in.** Serif numerals from the same display
///   face his entries render in.
///
/// Interaction is unchanged, because he asked for it twice: tap a written day
/// to jump the list to it, swipe back through months to the earliest entry.
/// A month of writing, as a skyline.
///
/// The fourth version of this component, and the first that changes the FRAME
/// rather than the surface. The first three all made one element do two jobs at
/// once -- be a tappable calendar control AND be a data mark -- and everything
/// Rajan disliked followed from that. A cell that must hold a legible numeral
/// needs ~40pt, so a month needs six rows, so the strip ate half the screen
/// above his own writing. "How much did I write" then had to ride on the
/// least precise channel available, the alpha of a big blob. And because a
/// grid's row breaks are arbitrary, a streak running Saturday into Sunday got
/// visually severed -- so connector hairlines were bolted on to recover it,
/// adding noise to fix noise. His verdict on the result: "this journal
/// connecting dots ui stilllooks ugly... u didnt think enough considering what
/// would benefit a human better."
///
/// So: one row of thin bars, one bar per day, height = words written. A dense
/// month reads as a city; a quiet 2022 month reads honestly as a plain. Streaks
/// are contiguous by construction, because a month is a single row and no wrap
/// can break a run. This is the chart language a young user already reads
/// fluently -- Health, Screen Time, Wrapped -- set in Cobux's own serif and
/// seasonal colour rather than borrowed whole.
///
/// The reference he compared against (Sisyphus's velocity chart) wins on three
/// things, all kept here: marks small enough to aggregate rather than parse,
/// empty days that are nearly invisible, and no grid at all. It is beaten on
/// four: volume as height rather than a boolean count, seasonal colour,
/// jump-to-day on tap, and one earned connector -- the streak underline.
/// (It used to say "the scrub". The scrub was removed on build 50 for taking
/// the pan that month paging needs; leaving the claim standing would have made
/// this doc comment the next reader's booby trap.)
struct JournalCalendarStrip: View {
    /// Per-day stats, keyed by `startOfDay`.
    let dayStats: [Date: JournalDayStat]

    /// The live journalling streak. Declared BEFORE `onDaySelected`
    /// deliberately: a trailing closure binds to the last parameter, so putting
    /// an Int after the closure breaks every call site.
    var streak: Int = 0

    /// Jump-to-day, wired by `JournalListView`. Only written days fire it --
    /// an empty day has nowhere to jump to. `nil` keeps the view inert.
    var onDaySelected: ((Date) -> Void)? = nil

    /// Opens the whole-journal calendar (`JournalCalendarBrowserView`), wired
    /// by `JournalListView`. Fired by a tap on the month's NAME. Rajan, build
    /// 57: "clicking on a calendar that we have in our Cobux app, it should
    /// actually open a whole view of a big calendar like on Google Calendar or
    /// Apple Calendar -- it shows you the whole months and the little dates
    /// that you can click on." The strip itself stays as it is ("for now it's
    /// OK, it actually looks pretty good"); the title is the door. `nil`
    /// renders the title as plain text.
    var onBrowseMonths: (() -> Void)? = nil

    /// Full-height bar. Scales with text size like everything else here.
    @ScaledMetric(relativeTo: .body) private var barMax: CGFloat = 52
    /// The gap between two days' bars. Named rather than inlined because two
    /// things now have to agree on it: the row's layout, and the hit test that
    /// turns a tap's x-position back into a day.
    private let barSpacing: CGFloat = 3
    /// The display face resolves differently per theme, so it has to come from
    /// the environment rather than a hardcoded scheme.
    @Environment(\.colorScheme) private var colorScheme

    private let calendar = Calendar.current


    /// The word count a full-height bar represents: the 90th percentile of his
    /// own writing days across his whole history.
    ///
    /// Personal calibration -- the same idea the old p33/p66 tiers had, since a
    /// heavy day for him is not a heavy day for anyone else -- but spent on a
    /// channel that can actually carry it. p90 rather than the maximum, so one
    /// 3,000-word night cannot flatten every other day into a stub; floored at
    /// 20 so a brand-new journal's first short entry does not max the scale.
    ///
    /// Resolved ONCE, in `init`, and stored.
    ///
    /// This was a computed property, and it is read from `height(for:)` --
    /// twice on a single line there -- which runs once per written day's bar,
    /// up to thirty-one bars per month page. Every one of those reads filtered,
    /// mapped and SORTED his entire journalling history, not the visible month:
    /// up to sixty-two full sorts of every day he has ever written, per month
    /// page, every time one rendered. Swiping back through a few years of
    /// months repeated that per page.
    ///
    /// The value cannot change while the view value exists -- it is a pure
    /// function of `dayStats`, which is a `let` -- so computing it per read was
    /// never buying correctness. A new `dayStats` makes a new strip, which
    /// recomputes it. Same number, one traversal. (The same trick, for the same
    /// reason, as `MonthGrid.init` in `JournalCalendarBrowserView`.)
    private let barScale: Int

    /// `onBrowseMonths` sits BEFORE `onDaySelected` for the reason `streak`'s
    /// comment gives: the trailing closure at every call site is jump-to-day,
    /// and it has to keep binding to the last parameter.
    init(dayStats: [Date: JournalDayStat],
         streak: Int = 0,
         onBrowseMonths: (() -> Void)? = nil,
         onDaySelected: ((Date) -> Void)? = nil) {
        self.dayStats = dayStats
        self.streak = streak
        self.onBrowseMonths = onBrowseMonths
        self.onDaySelected = onDaySelected
        self.barScale = Self.computeBarScale(from: dayStats)
    }

    private static func computeBarScale(from dayStats: [Date: JournalDayStat]) -> Int {
        let volumes = dayStats.values.filter(\.isWritten).map(\.words).sorted()
        guard !volumes.isEmpty else { return 20 }
        let index = min(volumes.count - 1, Int(Double(volumes.count - 1) * 0.9))
        return max(20, volumes[index])
    }

    /// Every month from the earliest entry through this one, oldest first so
    /// the newest sits at the trailing edge where the scroll anchors.
    private var months: [Date] {
        let thisMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: .now)
        ) ?? .now
        let earliest = dayStats.keys.min() ?? thisMonth
        let earliestMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: earliest)
        ) ?? thisMonth
        let span = (calendar.dateComponents([.month], from: earliestMonth, to: thisMonth).month ?? 0) + 1
        return (0..<max(1, span)).reversed().compactMap {
            calendar.date(byAdding: .month, value: -$0, to: thisMonth)
        }
    }

    /// Constant for every month now -- one row of bars rather than four to six
    /// rows of cells -- so the six-row worst case, and the chrome-allowance
    /// guesswork that once clipped August 30 and 31 off the bottom, are gone
    /// structurally rather than by tuning a constant.
    /// Derived from the page's own parts, not guessed.
    ///
    /// It was `barMax + 78`, and the page it has to hold measures
    /// `44 + 6 + 18 + 6 + barMax + 6 + 14` = `barMax + 94` -- the month-header
    /// row is 44pt because the chevrons carry 44pt hit targets, the caption
    /// line is ~18pt and the baseline numerals row is a declared 14pt. The
    /// page was overflowing its own frame by about sixteen points, and a
    /// `ScrollView(.horizontal)` clips vertical overflow, so the bottom of the
    /// baseline was being cut. That is half of what "congested" looks like from
    /// the outside: elements pressed together AND one of them shaved.
    ///
    /// Written as a sum of the same constants the page lays out with, so a
    /// spacing change moves both together instead of leaving this behind.
    private var pageHeight: CGFloat {
        let headerRow: CGFloat = 44        // set by the chevrons' 44pt targets
        let captionRow: CGFloat = 18       // the month summary line
        let baselineRow: CGFloat = 14      // declared in `baseline(days:hue:)`
        let steps = JournalFeedRhythm.withinObject * 3
        return headerRow + captionRow + baselineRow + steps + barMax
    }

    var body: some View {
        // The streak line and the calendar are ONE object -- the streak is a
        // fact about the days below it, not a separate banner -- so they sit at
        // the head rhythm's tightest step.
        VStack(alignment: .leading, spacing: JournalFeedRhythm.withinObject) {
            streakBanner
            monthPages
        }
    }

    /// The streak, ALWAYS visible, outside the paged scroll.
    ///
    /// It used to live inside `monthSummary`, gated on three conditions at
    /// once: a non-zero streak, the page being the current month, AND that
    /// month having entries -- the summary's own "Nothing written" guard
    /// returns before the streak line is ever appended. So paging back to
    /// August hid it, and a fresh month hid it too. Rajan reported it missing
    /// three times: "did you fix the Journal streak because the Journal streak
    /// is also not available", then "streak in journal section not visible
    /// still."
    ///
    /// It is the number he actually watches, so it does not belong buried in a
    /// comma-separated line on one page of a horizontally-scrolling strip. Here
    /// it sits above the pages and survives every one of them.
    @ViewBuilder
    private var streakBanner: some View {
        if streak > 0 {
            let hue = Color.cobuxMonthHue(calendar.component(.month, from: .now),
                                          dark: colorScheme == .dark)
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(.caption)
                    .foregroundStyle(hue)
                Text("\(streak)")
                    .font(CobuxTypography.display(colorScheme, size: 17, weight: .semibold))
                    .monospacedDigit()
                Text(streak == 1 ? "day straight" : "days straight")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, CobuxSpacing.screenMargin)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Writing streak, \(streak) \(streak == 1 ? "day" : "days") straight")
        }
    }

    /// The month currently on screen, driven both ways: paging updates it,
    /// and the chevrons write it to page programmatically.
    @State private var visibleMonth: Date?

    private var monthPages: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 0) {
                ForEach(months, id: \.self) { month in
                    monthPage(month)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $visibleMonth)
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.trailing)
        .frame(height: pageHeight)
    }

    /// Steps one month in either direction.
    ///
    /// Chevrons exist because the swipe cannot be the ONLY path: Journal is a
    /// navigation push, so the system's edge-pan owns roughly the first 20
    /// points of the left screen edge -- a back-swipe through months that
    /// starts there pops the whole screen instead. Rajan: "a user might just
    /// go back in app instead of swiping back thru the calendar months." The
    /// swipe stays (it is still the fluent path); the chevrons are the path
    /// that cannot be stolen.
    private func step(_ direction: Int) {
        let current = visibleMonth ?? months.last
        guard let current, let index = months.firstIndex(of: current) else { return }
        let target = months.indices.contains(index + direction) ? months[index + direction] : current
        withAnimation(.easeInOut(duration: 0.3)) { visibleMonth = target }
    }

    @ViewBuilder
    private func monthPage(_ month: Date) -> some View {
        let days = daysIn(month)
        let hue = Color.cobuxMonthHue(calendar.component(.month, from: month),
                                      dark: colorScheme == .dark)

        // One object: this month's name, what he wrote in it, and the bars that
        // show when. `JournalFeedRhythm.withinObject`, so the steps inside the
        // calendar read as clearly tighter than the gap to the card above or
        // below it -- which is what makes it look like one thing instead of
        // four stacked ones.
        VStack(alignment: .leading, spacing: JournalFeedRhythm.withinObject) {
            // Set in the face he writes in. This was system `.title3`, which
            // was a miss against this file's own stated philosophy.
            HStack(alignment: .firstTextBaseline) {
                // The month's name is the door to every month. A tap on the
                // bars is jump-to-day and a pan is month paging, both fought
                // for and both kept; the title was the one part of the
                // calendar that did nothing when tapped, and it is where a
                // finger goes to "open the calendar". A small chevron says it
                // opens; the face and size are unchanged so the strip still
                // reads as the instrument he approved.
                if let onBrowseMonths {
                    Button(action: onBrowseMonths) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(monthLabel(month))
                                .font(CobuxTypography.display(colorScheme, size: 22, weight: .semibold))
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(monthLabel(month)). Open the full calendar")
                } else {
                    Text(monthLabel(month))
                        .font(CobuxTypography.display(colorScheme, size: 22, weight: .semibold))
                }
                Spacer()
                // The glyph stays footnote-sized; the TARGET is 44pt. A bare
                // footnote chevron is roughly 8×12pt of hit area, and these
                // buttons exist precisely for the case where the swipe is
                // stolen -- so sighted users missing them most of the time
                // defeated their whole reason to exist. `contentShape` makes
                // the padding tappable, not just the ink.
                HStack(spacing: 0) {
                    Button { step(-1) } label: {
                        Image(systemName: "chevron.left")
                            .font(.footnote.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(months.first == month)
                    .accessibilityLabel("Earlier month")
                    Button { step(1) } label: {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(months.last == month)
                    .accessibilityLabel("Later month")
                }
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }

            Text(monthSummary(month))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)

            chart(days: days, hue: hue, month: month)
            baseline(days: days, hue: hue)
        }
        .padding(.horizontal, CobuxSpacing.screenMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ------------------------------------------------------------- the bars

    @ViewBuilder
    private func chart(days: [Date], hue: Color, month: Date) -> some View {
        // Measured, because the tap below resolves a day from WHERE the tap
        // landed rather than from which bar was hit. The `.frame(height:)`
        // underneath pins the reader to exactly the height the bars already
        // occupied, so this measures without moving anything.
        GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: barSpacing) {
                ForEach(days, id: \.self) { day in
                    bar(day, hue: hue)
                        .frame(maxWidth: .infinity)
                        .frame(height: barMax, alignment: .bottom)
                        .contentShape(Rectangle())
                        .accessibilityLabel(accessibilityLabel(day: day, stat: dayStats[day] ?? .init()))
                        // VoiceOver keeps its per-bar activation. The pointer
                        // gesture moved to the row below, and an element whose
                        // only action came from a tap gesture it no longer
                        // carries is one a VoiceOver user can no longer
                        // double-tap to jump -- so the action is stated here
                        // rather than inherited.
                        .accessibilityAction { jump(to: day) }
                }
            }
            .frame(height: barMax)
            .overlay(alignment: .bottomTrailing) { streakUnderline(days: days, hue: hue, month: month) }
            // ONE tap target for the whole row, not thirty-one.
            //
            // Every bar used to carry its own `.onTapGesture`. On a 390pt phone
            // a month is 31 bars of ~8pt inside ~350pt of chart -- under a fifth
            // of the 44pt minimum -- and the 3pt gaps between them belonged to
            // nobody, so a tap that missed did nothing at all. He reported the
            // calendar as not clickable three times ("i wrote a big ass reminder
            // on that"). Resolving the day from the tap's x-position makes every
            // point of a column live -- gap included, and the full `barMax`
            // height whatever height that day's bar actually drew.
            //
            // Still a TAP, and deliberately nothing else -- see the note below.
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                guard let day = day(at: location.x, width: proxy.size.width, days: days) else { return }
                jump(to: day)
            }
            // NO scrub gesture here.
            //
            // It was a `LongPressGesture` sequenced before a zero-distance
            // `DragGesture`, attached to a chart that fills the page width -- so it
            // competed with the horizontal ScrollView for the very same pan, and
            // paging through months stopped working. Rajan reported it on build 50
            // the day it shipped: "the journal calendar isn't swipable to past
            // months anymore".
            //
            // Swiping back through months is something he has asked for repeatedly
            // and is the strip's main job; scrubbing was an addition. When a nicety
            // and a primary function want the same gesture, the primary function
            // keeps it. Tapping a bar still jumps the feed to that day.
            //
            // A tap does not consume a drag, which is why going from 31 of them
            // to 1 is strictly safer for paging than what it replaced.
        }
        .frame(height: barMax)
    }

    /// Which day a tap at `x` landed on, counting the gap beside a bar as part
    /// of that bar's column.
    ///
    /// The pitch includes `barSpacing` because the HStack's own arithmetic
    /// does: n equal bars plus n-1 gaps inside `width` puts column i at
    /// `i * (width + spacing) / n`. Dividing by the day count alone drifts by
    /// `i * spacing / n` -- about 3pt by the end of a 31-day month, a third of
    /// a bar -- which would jump the feed to the 30th when he tapped the 31st.
    private func day(at x: CGFloat, width: CGFloat, days: [Date]) -> Date? {
        guard width > 0, !days.isEmpty else { return nil }
        let pitch = (width + barSpacing) / CGFloat(days.count)
        let index = min(days.count - 1, max(0, Int(x / pitch)))
        return days[index]
    }

    /// Jump the feed to a day, from a tap or from VoiceOver.
    ///
    /// An empty day stays inert, exactly as before: it has nowhere to jump to,
    /// and what an empty day SHOULD do is a question for Rajan rather than an
    /// answer this file invents.
    private func jump(to day: Date) {
        guard dayStats[day]?.isWritten ?? false else { return }
        onDaySelected?(day)
    }

    @ViewBuilder
    private func bar(_ day: Date, hue: Color) -> some View {
        let stat = dayStats[day] ?? JournalDayStat()
        let isFuture = day > calendar.startOfDay(for: .now)
        let isToday = calendar.isDateInToday(day)

        if stat.isWritten {
            Capsule()
                .fill(hue)
                .frame(height: height(for: stat.words))
                        } else if isFuture {
            // Nothing drawn. The column keeps its slot so the month's geometry
            // is stable, but a day that has not happened is not information.
            Color.clear.frame(height: 4)
        } else if isToday {
            // Today, still unwritten: a hollow marker rather than grain. The
            // spot is waiting, which is the one nudge this surface makes.
            Capsule()
                .strokeBorder(hue, lineWidth: 1.5)
                .frame(height: 10)
                        } else {
            // Paper grain. An unwritten day used to print a grey serif numeral
            // -- thirty-one pieces of text whose entire message was "nothing".
            Capsule()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 4)
                        }
    }

    /// Square-rooted, not linear: perceptually honest, and it keeps one huge
    /// night from flattening an otherwise steady month into stubs.
    private func height(for words: Int) -> CGFloat {
        let ratio = min(Double(words), Double(barScale)) / Double(barScale)
        return 10 + (barMax - 10) * CGFloat(ratio.squareRoot())
    }

    /// The one connector that survived, and the only one that ever meant
    /// anything: a single unbroken line under the live run, ending at today.
    /// Every previous connector joined two adjacent cells and died at the row
    /// edge, so it said nothing a reader could not already see. This says
    /// don't break this line.
    @ViewBuilder
    private func streakUnderline(days: [Date], hue: Color, month: Date) -> some View {
        if streak >= 2,
           calendar.isDate(month, equalTo: .now, toGranularity: .month),
           let todayIndex = days.firstIndex(where: { calendar.isDateInToday($0) }) {
            // Clamped to the month's first day: a streak that began last month
            // draws from the edge rather than off it.
            let span = min(streak, todayIndex + 1)
            GeometryReader { proxy in
                let column = proxy.size.width / CGFloat(days.count)
                let trailing = CGFloat(days.count - 1 - todayIndex) * column
                Capsule()
                    .fill(hue)
                    .frame(width: max(0, column * CGFloat(span) - 3), height: 3)
                    .offset(x: -trailing, y: 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .allowsHitTesting(false)
        }
    }

    // -------------------------------------------------------- date anchors

    /// Sparse numerals instead of thirty-one. Enough to locate a bar, few
    /// enough to stay quiet. Today always names itself, in the month's hue.
    @ViewBuilder
    private func baseline(days: [Date], hue: Color) -> some View {
        // Same spacing as the bars, from the same constant: the numerals only
        // locate a bar if the two rows share a pitch.
        HStack(alignment: .top, spacing: barSpacing) {
            ForEach(days, id: \.self) { day in
                let number = calendar.component(.day, from: day)
                let isToday = calendar.isDateInToday(day)
                Group {
                    if isToday {
                        Text("\(number)")
                            .font(CobuxTypography.display(colorScheme, size: 11, weight: .semibold))
                            .foregroundStyle(hue)
                    } else if number % 7 == 1 {
                        Text("\(number)")
                            .font(CobuxTypography.display(colorScheme, size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 14)
        .allowsHitTesting(false)
    }


    // ---------------------------------------------------------------- dates

    private func daysIn(_ month: Date) -> [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let count = calendar.range(of: .day, in: .month, for: month)?.count
        else { return [] }
        return (0..<count).compactMap {
            calendar.date(byAdding: .day, value: $0, to: interval.start)
                .map { calendar.startOfDay(for: $0) }
        }
    }

    /// Two formatters for the process rather than one per label.
    ///
    /// This is read from `body` (the month header above each page of the
    /// strip), so the old shape built a `DateFormatter` -- locale, calendar and
    /// time zone resolved on construction -- every time the strip
    /// re-evaluated, which while a finger is moving is constantly. Two objects
    /// because the format genuinely differs; mutating one shared formatter's
    /// `dateFormat` per call would reintroduce the cost it is avoiding and make
    /// it unsafe to share.
    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM"
        return formatter
    }()

    private static let monthYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    private func monthLabel(_ month: Date) -> String {
        let sameYear = calendar.component(.year, from: month) == calendar.component(.year, from: .now)
        return (sameYear ? Self.monthFormatter : Self.monthYearFormatter).string(from: month)
    }

    private func monthSummary(_ month: Date) -> String {
        let days = daysIn(month)
        let stats = days.compactMap { dayStats[$0] }.filter(\.isWritten)
        guard !stats.isEmpty else { return "Nothing written" }
        let words = stats.reduce(0) { $0 + $1.words }
        // "best run 11" was jargon -- he asked what it meant, which is the only
        // evidence a label needs to be wrong. Say the thing itself.
        var line = "\(words.formatted()) words · \(stats.count) day\(stats.count == 1 ? "" : "s")"
        let run = bestRun(days)
        if run > 1 { line += " · \(run) in a row" }
        // The streak is NOT appended here any more -- it lives in
        // `streakBanner`, above the pages, where it is visible on every month
        // instead of only this one. Printing it here as well would say the same
        // number twice on the current month's page.
        return line
    }

    /// Longest consecutive written stretch in the month. Counted across the
    /// real calendar -- which the skyline now also DRAWS correctly, since a
    /// month is one unbroken row and no week wrap can sever a run.
    private func bestRun(_ days: [Date]) -> Int {
        var best = 0, current = 0
        for day in days.sorted() {
            if dayStats[day]?.isWritten ?? false {
                current += 1
                best = max(best, current)
            } else {
                current = 0
            }
        }
        return best
    }

    private func accessibilityLabel(day: Date, stat: JournalDayStat) -> String {
        let date = day.formatted(date: .abbreviated, time: .omitted)
        guard stat.isWritten else { return "\(date), nothing written" }
        var parts = ["\(date)", "\(stat.words) words",
                     "\(stat.entries) entr\(stat.entries == 1 ? "y" : "ies")"]
        if stat.hasAttachment { parts.append("has an attachment") }
        return parts.joined(separator: ", ")
    }
}
