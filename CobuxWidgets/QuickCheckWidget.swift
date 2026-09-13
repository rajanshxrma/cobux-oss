import WidgetKit
import SwiftUI
import SwiftData

/// The Quick Check widget — one due quiz card living directly on the home
/// screen. Tap Reveal to see the answer, grade it with ✓/✗, and the REAL
/// FSRS schedule updates from the widget process (same `FSRSService` the app
/// uses), the streak records, and the next due card slides in. The point is
/// the Duolingo-widget loop: the cost of one review rounds to zero because
/// there's nothing to open.
///
/// State shared with the intents through App-Group defaults:
/// - `quickCheckQuestionID` — the card currently on the widget
/// - `quickCheckRevealed` — whether its answer is showing
enum QuickCheckState {
    static let questionIDKey = "quickCheckQuestionID"
    static let revealedKey = "quickCheckRevealed"
    static let widgetKind = "CobuxQuickCheckWidget"

    static var defaults: UserDefaults? { UserDefaults(suiteName: CobuxSchema.appGroupID) }

    static var currentQuestionID: UUID? {
        defaults?.string(forKey: questionIDKey).flatMap(UUID.init(uuidString:))
    }

    static var isRevealed: Bool { defaults?.bool(forKey: revealedKey) ?? false }

    static func setCurrent(_ id: UUID?) {
        if let id {
            defaults?.set(id.uuidString, forKey: questionIDKey)
        } else {
            defaults?.removeObject(forKey: questionIDKey)
        }
        defaults?.set(false, forKey: revealedKey)
    }

    static func reveal() {
        defaults?.set(true, forKey: revealedKey)
    }

    /// The widget's due pool: introduced, due-now, gradeable cards, most
    /// overdue first. The provider uses it for pick + count; the grade intent
    /// re-validates its card against `isGradeable` below.
    static func duePool(in context: ModelContext, now: Date = .now) -> [QuizQuestion] {
        // Predicate excludes suspended and never-introduced (nil dueDate)
        // rows, and the fetch SORTS BY dueDate BEFORE applying the limit:
        // this runs in the widget extension's ~30MB world against a library
        // that can hold thousands of questions, and an unsorted limited
        // fetch would take an arbitrary 500 rows — on exactly the heavy
        // library the cap exists for, genuinely due cards could fall outside
        // it and the widget would show "Nothing due" while cards are due.
        var descriptor = FetchDescriptor<QuizQuestion>(
            predicate: #Predicate { $0.isSuspended == false && $0.dueDate != nil },
            sortBy: [SortDescriptor(\.dueDate, order: .forward)]
        )
        descriptor.fetchLimit = 500
        let candidates = (try? context.fetch(descriptor)) ?? []
        return candidates.filter { isGradeable($0, now: now) }
    }

    /// The single definition of "this card may be graded from the widget" —
    /// used by `duePool` and re-checked by `GradeQuickCheckIntent` at tap
    /// time, so a card suspended or already reviewed in-app since the
    /// timeline was built is never double-graded.
    static func isGradeable(_ question: QuizQuestion, now: Date = .now) -> Bool {
        !question.isSuspended &&
        question.correctAnswerIndex != nil &&
        (question.dueDate.map { $0 <= now } ?? false)
    }
}

struct QuickCheckEntry: TimelineEntry {
    let date: Date
    let prompt: String
    let answer: String
    let revealed: Bool
    let bookTitle: String
    let coverColorHex: String
    let dueCount: Int
    let streak: Int
    /// False = nothing due right now; the widget shows the all-clear state.
    let hasCard: Bool
}

struct QuickCheckProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickCheckEntry {
        QuickCheckEntry(
            date: .now,
            prompt: "Secure attachment develops when a caregiver is consistently ____.",
            answer: "responsive",
            revealed: false,
            bookTitle: "Attached",
            coverColorHex: "#6366F1",
            dueCount: 3,
            streak: 5,
            hasCard: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickCheckEntry) -> Void) {
        completion(buildEntry(isSnapshot: true) ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickCheckEntry>) -> Void) {
        let entry = buildEntry(isSnapshot: false) ?? emptyEntry()
        // One entry, refreshed hourly — due-ness only changes with time or
        // with grading, and grading reloads explicitly via the intents.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 60))))
    }

    private func emptyEntry() -> QuickCheckEntry {
        QuickCheckEntry(
            date: .now, prompt: "", answer: "", revealed: false,
            bookTitle: "", coverColorHex: "#6366F1",
            dueCount: 0, streak: StreakTracker.currentStreak, hasCard: false
        )
    }

    private func buildEntry(isSnapshot: Bool) -> QuickCheckEntry? {
        guard let container = CobuxSchema.makeAppGroupContainer() else { return nil }
        let context = ModelContext(container)

        let pool = QuickCheckState.duePool(in: context)
        guard !pool.isEmpty else {
            if !isSnapshot {
                QuickCheckState.setCurrent(nil)
            }
            return emptyEntry()
        }

        // Keep showing the card the user may be mid-reveal on; only pick a
        // fresh one when the stored card is gone from the pool (graded,
        // deleted, or no longer due). Snapshot builds (widget gallery) must
        // never write state — re-pointing or un-revealing the live card from
        // a gallery render would be baffling.
        let current: QuizQuestion
        if let storedID = QuickCheckState.currentQuestionID,
           let stored = pool.first(where: { $0.id == storedID }) {
            current = stored
        } else {
            current = pool[0]
            if !isSnapshot {
                QuickCheckState.setCurrent(current.id)
            }
        }

        let answer: String = {
            guard let index = current.correctAnswerIndex,
                  current.choices.indices.contains(index) else { return current.explanation }
            return current.choices[index]
        }()

        return QuickCheckEntry(
            date: .now,
            prompt: current.prompt,
            answer: answer,
            revealed: QuickCheckState.isRevealed,
            bookTitle: current.book?.title ?? "",
            coverColorHex: current.book?.coverColorHex ?? "#6366F1",
            dueCount: pool.count,
            streak: StreakTracker.currentStreak,
            hasCard: true
        )
    }
}

struct QuickCheckWidgetView: View {
    var entry: QuickCheckEntry
    @Environment(\.widgetFamily) private var family

    private var accent: Color { Color(hex: entry.coverColorHex) }

    var body: some View {
        Group {
            if entry.hasCard {
                cardBody
            } else {
                nothingDueBody
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [accent.opacity(0.16), Color(.systemBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Quick Check", systemImage: "brain.head.profile")
                    .font(.system(size: 9, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(accent)
                Spacer()
                if entry.dueCount > 1 {
                    Text("\(entry.dueCount) due")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }

            Text(entry.prompt)
                .font(family == .systemMedium ? .footnote : .caption2)
                .fontWeight(.medium)
                .lineLimit(entry.revealed ? 2 : (family == .systemMedium ? 3 : 4))
                .minimumScaleFactor(0.8)

            Spacer(minLength: 0)

            if entry.revealed {
                Text(entry.answer)
                    .font(family == .systemMedium ? .footnote : .caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(accent)
                    .lineLimit(2)

                // `.contentShape(Rectangle())` on each label below: a
                // `.bordered` button DRAWS a full-width capsule, so these look
                // like wide targets, but SwiftUI hit-tests the LABEL's drawn
                // content -- the icon and the word -- and a widget tap that
                // lands on no button launches the app. So aiming at the middle
                // of a visibly-wide "Got it" button opened Cobux instead of
                // grading the card. Not user-reported; found by the linter
                // written for the same defect on the highlight widget.
                HStack(spacing: 8) {
                    Button(intent: GradeQuickCheckIntent(gotIt: false)) {
                        Label("Missed", systemImage: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .tint(.cobuxWarning)

                    Button(intent: GradeQuickCheckIntent(gotIt: true)) {
                        Label("Got it", systemImage: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .tint(.cobuxGood)
                }
            } else {
                Button(intent: RevealQuickCheckIntent()) {
                    Label("Reveal", systemImage: "eye")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .tint(accent)
            }
        }
        .padding(2)
    }

    /// What the widget says when there is nothing waiting: the fact, and
    /// nothing about the person.
    ///
    /// It used to say "All clear" under a green `checkmark.seal.fill`. That is
    /// a completion state -- a seal of approval, on his home screen, for a
    /// queue he never agreed to owe -- and it is the exact frame he rejected on
    /// the journal widget: "this shows a tick thats bad the jounral streak is
    /// meant for fun info display. that doest mean it is supposed to be a work
    /// or task for a user to necesarily complete." `JournalWidget`'s doc
    /// comment works that reasoning out in full and it generalises here without
    /// changing a word: a tick says a task existed, and by implication that its
    /// absence is a failure.
    ///
    /// So the glyph is a book in `.secondary` and the line states the queue's
    /// state, not a verdict on him. Deliberately NOT swapped for a different
    /// grade -- a softer badge would be the same frame in a quieter voice. The
    /// streak line below is untouched: he asked for that one by name, as "fun
    /// info display".
    private var nothingDueBody: some View {
        VStack(spacing: 6) {
            Image(systemName: "book.closed")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Nothing due")
                .font(.caption.weight(.semibold))
            if entry.streak > 0 {
                Label("\(entry.streak)-day streak", systemImage: "flame.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.cobuxWarning)
            } else {
                Text("No cards due right now")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CobuxQuickCheckWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: QuickCheckState.widgetKind, provider: QuickCheckProvider()) { entry in
            QuickCheckWidgetView(entry: entry)
        }
        .configurationDisplayName("Quick Check")
        .description("One due quiz card on your home screen — reveal, grade, next. Real reviews without opening the app.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
