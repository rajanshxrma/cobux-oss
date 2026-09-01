import SwiftUI

/// Several months of journaling history at once, each month a run of day
/// bubbles whose fill deepens with how much was written that day.
///
/// Rajan's ask: *"for the Journal tab the way the dates are displayed is kind
/// of stupid. There should be like a little calendar... marking a little dot
/// for the dates where I have actually journaled."* Then, on the first
/// version: *"the journaling calendar should be like the one we have in
/// sisyphus, current is kinda sad looking."*
///
/// The first attempt was a literal calendar: one month, a 7-column weekday
/// grid, a 5pt dot under each date number. It answered "did I write on the
/// 14th" — a question nobody asks — while making the only question that
/// matters, *what does my consistency actually look like*, require swiping
/// month by month and reconstructing it from memory. And a 5pt dot is a
/// boolean: a day with one line looks exactly like a day with eight entries.
///
/// This is a port of Sisyphus's `velocity` view (`frontend/js/views/
/// dashboard.js` + `.velocity-*` in `styles.css`), which solves the same
/// problem for job applications. Three ideas carry over, and all three are
/// why that one doesn't look sad:
///
/// 1. **Four months on screen at once**, so the shape is comparative — this
///    month against the last three — instead of one month in isolation.
/// 2. **Weekday alignment dropped.** A real calendar grid spends up to six
///    cells per month on leading blanks and forces a fixed 7-wide column, for
///    information ("the 3rd was a Tuesday") that is irrelevant here. Days just
///    run continuously and wrap, so every cell is real data.
/// 3. **Intensity, not presence.** The count sits inside the bubble and the
///    fill deepens across three tiers, so a heavy day and a barely-there day
///    stop looking identical.
///
/// Both of the original "read-only, four months" limits are gone, per his
/// follow-up asks: *"fix the Cobux journal calendar swipe thru past months
/// since earliest and all writing… also this calendar should be clickable to
/// go to that particular day."* The strip now pages horizontally -- each page
/// a season of four months, the newest page on screen first, swiping back
/// through every 4-month window down to the earliest entry on record -- and
/// a day that has entries is a button that jumps the list below to that day.
struct JournalCalendarStrip: View {
    /// Entries per day, keyed by `startOfDay`. A count rather than a `Set`
    /// because the fill tier is the whole point -- presence alone is what made
    /// the previous version flat.
    let entryCounts: [Date: Int]

    /// Jump-to-day, wired by `JournalListView` to scroll its own date
    /// sections. Only days that actually have entries fire it -- an empty
    /// day has nowhere to jump to. `nil` keeps the strip inert (previews).
    var onDaySelected: ((Date) -> Void)? = nil

    /// Months per page, oldest first within a page. Four fits an iPhone width
    /// without the rows becoming a wall, and covers a full season of habit.
    private static let monthsPerPage = 4

    private let calendar = Calendar.current

    /// Every 4-month window from the earliest entry through this month,
    /// oldest page first, aligned so the LAST page ends exactly on the
    /// current month -- landing on it first (`defaultScrollAnchor(.trailing)`)
    /// keeps the default view identical to the old fixed strip.
    private var pages: [[Date]] {
        let startOfThisMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: .now)
        ) ?? .now
        let earliestDay = entryCounts.keys.min() ?? startOfThisMonth
        let earliestMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: earliestDay)
        ) ?? startOfThisMonth
        let monthSpan = (calendar.dateComponents([.month], from: earliestMonth, to: startOfThisMonth).month ?? 0) + 1
        let pageCount = max(1, Int(ceil(Double(monthSpan) / Double(Self.monthsPerPage))))

        return (0..<pageCount).reversed().map { pageBack in
            let newestOffsetInPage = pageBack * Self.monthsPerPage
            return (0..<Self.monthsPerPage).reversed().compactMap { offsetWithinPage in
                let monthsBack = newestOffsetInPage + offsetWithinPage
                guard monthsBack < monthSpan else { return nil }
                return calendar.date(byAdding: .month, value: -monthsBack, to: startOfThisMonth)
            }
        }
    }

    var body: some View {
        ScrollView(.horizontal) {
            // Plain HStack, not lazy: page count stays small (a year of
            // journaling is three pages), and eager layout gives the whole
            // strip one stable height instead of jumping as pages load in.
            HStack(alignment: .top, spacing: 0) {
                ForEach(pages.indices, id: \.self) { pageIndex in
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(pages[pageIndex], id: \.self) { month in
                            monthRow(month)
                        }
                    }
                    .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        // Open on the newest page -- history is a swipe away, not the default.
        .defaultScrollAnchor(.trailing)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func monthRow(_ month: Date) -> some View {
        let days = days(in: month)
        let total = days.reduce(0) { $0 + (entryCounts[$1] ?? 0) }

        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(monthLabel(month))
                    .font(.caption.weight(.semibold))
                // The month's own total, so each row states its result rather
                // than making you count bubbles to compare months.
                Text("· \(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // `.adaptive` gives the wrap that CSS flex-wrap provides in
            // Sisyphus -- days flow and break by available width, with no
            // fixed column count to pad out.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 22), spacing: 4, alignment: .leading)],
                alignment: .leading,
                spacing: 4
            ) {
                ForEach(days, id: \.self) { day in
                    dayBubble(day)
                }
            }
        }
    }

    /// Every day of `month` up to today. Future days render nothing at all --
    /// an empty slot for a day that hasn't happened reads as a missed day.
    private func days(in month: Date) -> [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let count = calendar.range(of: .day, in: .month, for: month)?.count
        else { return [] }
        let today = calendar.startOfDay(for: .now)
        return (0..<count).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: interval.start) else { return nil }
            let start = calendar.startOfDay(for: day)
            return start <= today ? start : nil
        }
    }

    private func monthLabel(_ month: Date) -> String {
        let formatter = DateFormatter()
        // Year only when it isn't the current one -- across a 4-month window
        // that matters exactly at a January boundary.
        let sameYear = calendar.component(.year, from: month) == calendar.component(.year, from: .now)
        formatter.dateFormat = sameYear ? "MMMM" : "MMMM yyyy"
        return formatter.string(from: month)
    }

    @ViewBuilder
    private func dayBubble(_ day: Date) -> some View {
        let count = entryCounts[day] ?? 0
        if count > 0, let onDaySelected {
            Button {
                onDaySelected(day)
            } label: {
                dayBubbleFace(day, count: count)
            }
            .buttonStyle(.plain)
        } else {
            dayBubbleFace(day, count: count)
        }
    }

    @ViewBuilder
    private func dayBubbleFace(_ day: Date, count: Int) -> some View {
        let isToday = calendar.isDateInToday(day)

        ZStack {
            if count == 0 {
                // Hollow and faint: a day is legible as "nothing here" without
                // reading as a reprimand.
                Circle()
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            } else {
                Circle().fill(fill(for: count))
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(count >= 2 ? Color.white : Color.cobuxAccent)
            }
        }
        .frame(width: 22, height: 22)
        .overlay {
            if isToday {
                Circle()
                    .stroke(Color.primary.opacity(0.55), lineWidth: 1.5)
                    .padding(-2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(day: day, count: count))
    }

    /// Three tiers, matching Sisyphus's `v-lo`/`v-mid`/`v-hi`. Journaling is
    /// lower-volume than job applications, so the thresholds sit lower: one
    /// entry is a real day, three is a heavy one.
    private func fill(for count: Int) -> Color {
        switch count {
        case 1: Color.cobuxAccent.opacity(0.28)
        case 2: Color.cobuxAccent.opacity(0.62)
        default: Color.cobuxAccent
        }
    }

    private func accessibilityLabel(day: Date, count: Int) -> String {
        let date = day.formatted(date: .abbreviated, time: .omitted)
        switch count {
        case 0: return "\(date), no entries"
        case 1: return "\(date), 1 entry"
        default: return "\(date), \(count) entries"
        }
    }
}
