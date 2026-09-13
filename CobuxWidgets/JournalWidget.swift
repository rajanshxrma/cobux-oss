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
/// Face ID if the lock is on -- see `JournalListView.startingNewEntry`).
/// **No completion state anywhere in this widget. That is a ruling, not a
/// style choice.**
///
/// The number on the home families is `StreakTracker.currentStreak` -- the
/// app-wide "showing up" streak, advanced by a foreground, a chat send, a
/// quiz answer or a widget tap, never by writing specifically. It is captioned
/// "day streak", the same words every other surface uses for the same number
/// (`MilestoneCelebrationView`, `FlowCardViews`, `QuickCheckWidget`,
/// `CobuxWatch`). It used to read "days of writing", which was simply untrue:
/// someone who had never written an entry saw "12 days of writing" as a
/// statement about his own life, on the surface he looks at most. A widget may
/// be quiet or it may be wrong; it may not be wrong.
///
/// No accessory family shows it at all. That is his ruling, verbatim: the
/// journal lock-screen widget "show[s] the cobux streak in display and not the
/// journals itself". The lock screen is where he decides to write, so what it
/// says is "Journal" and what it does is open compose. The streak still lives
/// on this widget's home families and on the highlight widget's circular one.
///
/// Every family used to swap between "Written today" and "Write today", and the
/// circular one showed a literal checkmark once he had written. Rajan saw that
/// tick on his lock screen and rejected the whole frame: "this shows a tick
/// thats bad the jounral streak is meant for fun info display. that doest mean
/// it is supposed to be a work or task for a user to necesarily complete. if
/// they dont wanna they wont."
///
/// He is right, and the reasoning generalises to anything that counts days in
/// this app. A checkmark is the vocabulary of a to-do list: it says a task
/// existed, and by implication that its absence is a failure. This is a journal
/// -- someone who does not write today has not failed at anything, and a
/// checkmark quietly tells them they have. The streak is information about
/// their own life, offered because it is interesting, never because it is owed.
///
/// So: the widget states the number and invites. It never grades.
struct JournalWidgetEntry: TimelineEntry {
    let date: Date
    let streak: Int
}

struct JournalWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> JournalWidgetEntry {
        JournalWidgetEntry(date: .now, streak: 6)
    }

    func getSnapshot(in context: Context, completion: @escaping (JournalWidgetEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<JournalWidgetEntry>) -> Void) {
        // Refresh at the next local midnight: the one value shown here (the
        // day streak) is day-scoped, so the only moment it can go stale on its
        // own is the date rolling over.
        let next = Calendar.current.nextDate(
            after: .now,
            matching: DateComponents(hour: 0, minute: 1),
            matchingPolicy: .nextTime
        ) ?? Date.now.addingTimeInterval(3600)
        completion(Timeline(entries: [currentEntry()], policy: .after(next)))
    }

    private func currentEntry() -> JournalWidgetEntry {
        // `hasWrittenJournalToday` is deliberately NOT read any more -- see the
        // no-completion-state ruling above. Nothing in this widget may know
        // whether today is "done".
        JournalWidgetEntry(date: .now, streak: StreakTracker.currentStreak)
    }
}

struct JournalWidgetView: View {
    var entry: JournalWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline:
            lockScreenBody
                // Whole-surface tap -> straight into compose, same destination
                // the home-screen families use. An accessory family is far too
                // small for two targets, so the entire widget is the action.
                .widgetURL(CobuxDeepLink.journalURL(newEntry: true))
        default:
            homeScreenBody
                .widgetURL(CobuxDeepLink.journalURL(newEntry: true))
        }
    }

    /// The lock screen is where the daily habit is actually decided: it is the
    /// screen he sees most, and journaling is the thing he does every day. The
    /// widget existed only on the home screen, which meant unlocking, finding
    /// it, then tapping -- the same friction the home-screen widget was built
    /// to remove, just moved one surface earlier.
    ///
    /// No accessory family reports a number. They are monochrome, tiny, and
    /// glanced at rather than read, so each says only what it is and what it
    /// does -- see this file's own doc comment for why the streak in
    /// particular is off the lock screen.
    @ViewBuilder
    private var lockScreenBody: some View {
        switch family {
        case .accessoryCircular:
            // One glyph, nothing else. Rajan asked for this shape by name:
            // "iOS lock screen widget like snap has a small icon snap camera
            // widget but for Cobux journal." Snap's lock-screen widget is a
            // bare camera icon whose entire meaning is "tap here and you are
            // already shooting" -- it reports nothing, it just opens.
            //
            // It used to stack the pencil over the streak count, which made a
            // one-inch circle into a small dashboard: two things to read
            // before the one thing to do. He flagged that -- the widget
            // "show[s] the cobux streak in display and not the journals
            // itself" -- and the rectangular and inline families below have
            // since been cleared of it for the same reason. The streak has not
            // been lost: it is on this widget's home families and on the
            // highlight widget's circular family, so the lock screen can still
            // carry a number without this one having to be it.
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 22, weight: .semibold))
            }
            .accessibilityLabel("Journal, write an entry")

        case .accessoryInline:
            // One line, no styling of its own -- the OS owns inline rendering.
            // It read "Journal · 12 days", which on a lock screen is read as
            // twelve days of journaling and was nothing of the kind.
            Label("Journal", systemImage: "square.and.pencil")

        default:
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    // Was "\(entry.streak) days of writing" -- see above.
                    Text("Journal")
                        .font(.headline)
                        .lineLimit(1)
                    Text("Tap to write")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var homeScreenBody: some View {
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

            // The streak IS the display. It used to be a subtitle under a
            // "Written today" / "Write today" status line, which is what made
            // the widget read as a chore with a done state.
            Text(entry.streak > 0 ? "\(entry.streak)" : "Journal")
                .font(family == .systemSmall ? .largeTitle.bold() : .system(size: 44, weight: .bold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            // "day streak", not "days of writing". The number is the app-wide
            // streak, so it is captioned with the app-wide words -- the same
            // ones Flow, the milestone card, Quick Check and the Watch use for
            // this exact value.
            Text(entry.streak > 0 ? "day streak" : "Tap to write")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct CobuxJournalWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CobuxJournalWidget", provider: JournalWidgetProvider()) { entry in
            JournalWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Journal")
        .description("One tap and you're writing. The streak rides along, just for the fun of it.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryCircular, .accessoryRectangular, .accessoryInline
        ])
    }
}
