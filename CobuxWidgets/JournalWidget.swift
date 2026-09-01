import WidgetKit
import SwiftUI

/// One tap from the home screen into writing a journal entry.
///
/// Rajan's reminder was "Cobux journal widget direct" -- the emphasis on
/// *direct*. Journaling is the daily habit this app is increasingly built
/// around, but reaching it meant launching the app, finding the More tab,
/// tapping Journal, then tapping compose. Four taps for the thing done every
/// day, while a highlight (browsed, not authored) had a widget from early on.
///
/// So the widget's whole surface is the write action: tapping anywhere opens
/// `cobux://journal/new`, which lands directly in the compose sheet (behind
/// Face ID if the lock is on -- see `JournalListView.startingNewEntry`). It
/// shows the streak because that's the one number that makes a daily habit
/// feel worth continuing, and the same `StreakTracker` the app and Flow read,
/// never a second source of truth.
struct JournalWidgetEntry: TimelineEntry {
    let date: Date
    let streak: Int
    let wroteToday: Bool
}

struct JournalWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> JournalWidgetEntry {
        JournalWidgetEntry(date: .now, streak: 6, wroteToday: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (JournalWidgetEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<JournalWidgetEntry>) -> Void) {
        // Refresh at the next local midnight: both values shown here
        // ("N-day streak", "written today") are day-scoped, so the only moment
        // they can go stale on their own is the date rolling over.
        let next = Calendar.current.nextDate(
            after: .now,
            matching: DateComponents(hour: 0, minute: 1),
            matchingPolicy: .nextTime
        ) ?? Date.now.addingTimeInterval(3600)
        completion(Timeline(entries: [currentEntry()], policy: .after(next)))
    }

    private func currentEntry() -> JournalWidgetEntry {
        JournalWidgetEntry(
            date: .now,
            streak: StreakTracker.currentStreak,
            wroteToday: StreakTracker.hasWrittenJournalToday
        )
    }
}

struct JournalWidgetView: View {
    var entry: JournalWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 8) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil")
                    .font(.caption.weight(.bold))
                Text("JOURNAL")
                    .font(.caption2.weight(.bold))
                    .kerning(1.5)
            }
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Text(entry.wroteToday ? "Written today" : "Write today")
                .font(family == .systemSmall ? .headline : .title3.bold())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if entry.streak > 0 {
                Label("\(entry.streak)-day streak", systemImage: "flame.fill")
                    .font(.caption)
                    .foregroundStyle(entry.wroteToday ? Color.orange : .secondary)
                    .lineLimit(1)
            } else {
                Text("A fresh start")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // Whole-surface tap -> straight into compose. Built through
        // `CobuxDeepLink` rather than a hand-written string, same rule the
        // highlight widget already follows.
        .widgetURL(CobuxDeepLink.journalURL(newEntry: true))
    }
}

struct CobuxJournalWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CobuxJournalWidget", provider: JournalWidgetProvider()) { entry in
            JournalWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Journal")
        .description("Write today's entry in one tap, and keep your streak in sight.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
