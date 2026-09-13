import SwiftUI
import SwiftData
import Charts
import CobuxCore

/// The largest missed opportunity identified in the pre-2.0.0 audit: every
/// `QuizAttempt`/`QuizAnswerRecord` is persisted and then never read again
/// anywhere in the app — there was no `@Query` for either type at all.
/// Everything here is straightforward reads of data that already exists;
/// no new model fields needed.
struct QuizAnalyticsView: View {
    @Environment(\.modelContext) private var modelContext
    /// Everything this screen draws, as plain values.
    ///
    /// This used to be four unbounded `@Query`s -- every `QuizAttempt`, every
    /// `QuizQuestion`, every `Theme` and every `QuizAnswerRecord` in the
    /// library, materialised on the main actor before the screen could draw --
    /// feeding six computed properties that `body` then read TWICE each (once
    /// to decide whether a section exists, once to fill it). `reviewForecast`
    /// alone ran fourteen filter passes over every due date, twice: twenty-eight
    /// full passes to draw one small chart.
    ///
    /// `DiagnosticsView`'s shape replaces it: a `@ModelActor` probe owns its own
    /// context on its own executor, does the whole read there, and returns ONE
    /// `Sendable` summary. No `@Model` object and no `ModelContext` crosses an
    /// actor boundary, which is the rule this codebase has already paid for
    /// twice.
    ///
    /// The one deliberate consequence: this is a snapshot taken when the screen
    /// opens, not a live query. That is right for an analytics screen -- it is
    /// pushed from Quiz Home, read, and left, and re-entering it re-runs the
    /// probe. Nothing on this screen can be edited from this screen, so there
    /// is no change here for a live query to reflect.
    @State private var summary: QuizAnalyticsSummary?
    private let seedingStatus = SeedingStatus.shared

    var body: some View {
        Group {
            if let summary {
                analyticsList(summary)
            } else {
                List {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            // Says which of the two waits this is, the way
                            // `DiagnosticsView` does -- a screen that is drawn
                            // but has nothing to say has not opened.
                            Text(seedingStatus.isSeeding
                                 ? "Waiting for your library to finish setting up…"
                                 : "Reading your quiz history…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle("Quiz Analytics")
            }
        }
        // Never read the library while the background seed/upgrade merge is in
        // flight -- the confirmed Build-5 crash class, previously handled by
        // gating `body` on the same flag. Keyed on it so the probe runs the
        // moment the merge lands.
        .task(id: seedingStatus.isSeeding) {
            guard !seedingStatus.isSeeding else { return }
            summary = await QuizAnalyticsProbe(modelContainer: modelContext.container).summary()
        }
    }

    private func analyticsList(_ summary: QuizAnalyticsSummary) -> some View {
        // Read once each, from a value already in hand. Every one of these was
        // a computed property that walked the store again at each reference.
        let retentionRate30Days = summary.retentionRate30Days
        let reviewForecast = summary.forecast
        let masteryByBook = summary.mastery
        let weakestTopics = summary.weakestTopics
        let completedAttempts = summary.recentAttempts
        return List {
            CobuxFormSection(title: "Retention") {
                if let rate = retentionRate30Days {
                    HStack {
                        Text("Last 30 days")
                        Spacer()
                        Text("\(Int(rate * 100))%")
                            .fontWeight(.semibold)
                            .foregroundStyle(rate >= 0.85 ? Color.cobuxGood : .primary)
                            .contentTransition(.numericText())
                            .animation(.easeOut(duration: 0.3), value: rate)
                    }
                } else {
                    Text("Answer a few questions to see your retention rate here.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            CobuxFormSection(title: "Review Forecast") {
                // A first visit used to get a flat, wordless 140pt chart --
                // fourteen empty days under a title, with nothing saying what
                // the panel is or why it is blank. The Retention section above
                // already answers that in one line when it has no number yet;
                // this now does the same rather than drawing a chart of zeros.
                if reviewForecast.allSatisfy({ $0.count == 0 }) {
                    Text("Once you've reviewed a card, it reappears here on the day it comes back around.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    Chart(reviewForecast) { day in
                        BarMark(
                            x: .value("Day", day.date, unit: .day),
                            y: .value("Due", day.count)
                        )
                        .foregroundStyle(Color.cobuxAccent)
                    }
                    .frame(height: 140)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 3)) { value in
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        }
                    }
                }
            }

            if !masteryByBook.isEmpty {
                Section {
                    ForEach(masteryByBook) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.bookTitle)
                                    .font(.subheadline)
                                Spacer()
                                if let mean = entry.meanRetrievability {
                                    Text("\(Int(mean * 100))%")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(mean >= 0.85 ? Color.cobuxGood : (mean >= 0.6 ? Color.primary : Color.cobuxWarning))
                                } else {
                                    Text("Not reviewed yet")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let mean = entry.meanRetrievability {
                                ProgressView(value: mean)
                                    .tint(mean >= 0.85 ? Color.cobuxGood : (mean >= 0.6 ? Color.cobuxAccent : Color.cobuxWarning))
                            }
                        }
                    }
                } header: {
                    Text("Mastery")
                } footer: {
                    Text("Predicted retention right now, per book — decays honestly the longer it's been since you last reviewed, even if you haven't opened the app.")
                }
            }

            if !weakestTopics.isEmpty {
                Section {
                    ForEach(weakestTopics) { topic in
                        HStack {
                            Text(topic.themeName)
                                .font(.subheadline)
                            Spacer()
                            Text("\(Int(topic.wrongRate * 100))% missed")
                                .font(.caption)
                                .foregroundStyle(Color.cobuxWarning)
                            Text("(\(topic.sampleSize))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Weakest Topics")
                } footer: {
                    Text("Topics from Wisdom Graph with the highest miss rate across at least 3 answered questions.")
                }
            }

            if !completedAttempts.isEmpty {
                CobuxFormSection(title: "Recent Attempts") {
                    // Already the newest 20 -- the probe applies the same
                    // `prefix(20)` this line used to, as a `fetchLimit`, so the
                    // rows shown are identical and the other 4,000 attempts are
                    // never read.
                    ForEach(completedAttempts) { attempt in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(attempt.scopeDescription)
                                    .font(.subheadline)
                                Text(attempt.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let score = attempt.scorePercent {
                                Text("\(Int(score * 100))%")
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
            }

            CobuxFormSection(title: "Spend") {
                HStack {
                    Text("Estimated this month")
                    Spacer()
                    Text(String(format: "$%.2f", UsageTracker.currentMonthEstimate()))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Quiz Analytics")
    }
}

// MARK: - The summary, and the probe that builds it

/// Everything `QuizAnalyticsView` draws, as `Sendable` values.
///
/// The whole point of this type is that it is what crosses the actor boundary
/// INSTEAD of the model objects. Nothing here holds a `@Model`, a
/// `PersistentIdentifier`, or a `ModelContext`.
struct QuizAnalyticsSummary: Sendable {
    struct ForecastDay: Identifiable, Sendable {
        let date: Date
        let count: Int
        var id: Date { date }
    }

    struct BookMastery: Identifiable, Sendable {
        let bookTitle: String
        /// Mean FSRS-predicted retrievability across this book's reviewed questions --
        /// nil means nothing in this book has been reviewed yet, not "0% mastered".
        /// Decays honestly with time since last review, same as any FSRS forgetting curve.
        let meanRetrievability: Double?
        var id: String { bookTitle }
    }

    struct TopicWeakness: Identifiable, Sendable {
        let themeName: String
        let wrongRate: Double
        let sampleSize: Int
        var id: String { themeName }
    }

    struct AttemptRow: Identifiable, Sendable {
        let id: UUID
        let scopeDescription: String
        let startedAt: Date
        let scorePercent: Double?
    }

    var retentionRate30Days: Double?
    var forecast: [ForecastDay] = []
    var mastery: [BookMastery] = []
    var weakestTopics: [TopicWeakness] = []
    /// Already limited to the newest 20 completed attempts -- the same slice the
    /// screen has always shown.
    var recentAttempts: [AttemptRow] = []
}

/// Reads the quiz store off the main actor and returns one plain value.
///
/// `DiagnosticsProbe`'s shape exactly: a `@ModelActor` owns a `ModelContext`
/// confined to its own serial executor, every model read happens there, and
/// only `QuizAnalyticsSummary` comes back.
@ModelActor
actor QuizAnalyticsProbe {
    func summary() -> QuizAnalyticsSummary {
        var result = QuizAnalyticsSummary()
        result.retentionRate30Days = retention30Days()
        result.forecast = forecast()
        result.mastery = mastery()
        result.weakestTopics = weakestTopics()
        result.recentAttempts = recentAttempts()
        return result
    }

    /// The number Anki users actually track — correct answers over answers
    /// actually given, not over the full assigned count (see `QuizAttempt.
    /// answeredCount` fix — ending a quiz early no longer distorts this).
    ///
    /// The 30-day window and the completed filter are now a PREDICATE rather
    /// than two array filters over every attempt ever recorded.
    private func retention30Days() -> Double? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
        let descriptor = FetchDescriptor<QuizAttempt>(
            predicate: #Predicate { $0.completedAt != nil && $0.startedAt >= cutoff })
        guard let attempts = try? modelContext.fetch(descriptor) else { return nil }
        var answered = 0
        var correct = 0
        for attempt in attempts {
            answered += attempt.answeredCount
            correct += attempt.correctCount
        }
        guard answered > 0 else { return nil }
        return Double(correct) / Double(answered)
    }

    /// Next 14 days of due cards, from the real FSRS `dueDate` field —
    /// distinct from any per-book due count since it spans every book.
    ///
    /// Two changes, both exact. The window is a predicate, so a library with
    /// years of scheduling ahead reads only the fortnight it draws. And the
    /// buckets are filled in ONE pass by computing each question's day offset,
    /// instead of fourteen filter passes over the whole list of due dates --
    /// which `body` then ran twice, once to ask whether the chart was all
    /// zeros and once to draw it.
    private func forecast() -> [QuizAnalyticsSummary.ForecastDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let horizon = calendar.date(byAdding: .day, value: 14, to: today) ?? today
        let distantPast = Date.distantPast

        let descriptor = FetchDescriptor<QuizQuestion>(
            predicate: #Predicate {
                !$0.isSuspended
                    && ($0.dueDate ?? distantPast) >= today
                    && ($0.dueDate ?? distantPast) < horizon
            })

        var counts = [Int](repeating: 0, count: 14)
        for question in (try? modelContext.fetch(descriptor)) ?? [] {
            guard let due = question.dueDate else { continue }
            let offset = calendar.dateComponents([.day],
                                                 from: today,
                                                 to: calendar.startOfDay(for: due)).day ?? 0
            guard offset >= 0, offset < counts.count else { continue }
            counts[offset] += 1
        }

        return (0..<14).map { offset in
            QuizAnalyticsSummary.ForecastDay(
                date: calendar.date(byAdding: .day, value: offset, to: today) ?? today,
                count: counts[offset])
        }
    }

    /// One entry per book that has at least one question, ranked by predicted
    /// retention. Single pass: the old form grouped, then per group ran a
    /// `filter`, a `map` and a `reduce` -- three more allocations per book.
    private func mastery() -> [QuizAnalyticsSummary.BookMastery] {
        struct Accumulator {
            var title = ""
            var scoreSum = 0.0
            var reviewedCount = 0
        }
        var byBook: [UUID: Accumulator] = [:]
        let now = Date.now

        for question in (try? modelContext.fetch(FetchDescriptor<QuizQuestion>())) ?? [] {
            guard let book = question.book else { continue }
            var accumulator = byBook[book.id] ?? Accumulator(title: book.title)
            if question.fsrsReps > 0, let lastReviewed = question.lastReviewedAt {
                let elapsedDays = max(0, now.timeIntervalSince(lastReviewed) / 86400)
                accumulator.scoreSum += FSRS.retrievability(
                    elapsedDays: elapsedDays,
                    stability: max(question.fsrsStability, 0.01))
                accumulator.reviewedCount += 1
            }
            byBook[book.id] = accumulator
        }

        return byBook.values.map { accumulator in
            QuizAnalyticsSummary.BookMastery(
                bookTitle: accumulator.title,
                // nil, not zero: "nothing reviewed yet" is not "0% mastered".
                meanRetrievability: accumulator.reviewedCount > 0
                    ? accumulator.scoreSum / Double(accumulator.reviewedCount)
                    : nil)
        }
        .sorted { ($0.meanRetrievability ?? -1) > ($1.meanRetrievability ?? -1) }
    }

    /// Reuses `QuizModeService.weakestThemes` -- the same canonical-`Theme`-based weak-topic
    /// detection the Weak Spots quiz mode pools from, so this panel and that mode always agree
    /// on what "weak" means, the same way the due-count unification made Quiz Home and Daily
    /// Review agree on what "due" means.
    ///
    /// `sampleSize` now comes back FROM `weakestThemes`, which already counted
    /// it. The view used to recompute it by filtering every answer record per
    /// topic, rebuilding the theme's highlight-id `Set` inside the filter
    /// closure -- so the set was constructed once per record, five times over.
    private func weakestTopics() -> [QuizAnalyticsSummary.TopicWeakness] {
        let themes = (try? modelContext.fetch(FetchDescriptor<Theme>())) ?? []
        let answerRecords = (try? modelContext.fetch(FetchDescriptor<QuizAnswerRecord>())) ?? []
        return QuizModeService.weakestThemes(themes: themes, answerRecords: answerRecords)
            .prefix(5)
            .map {
                QuizAnalyticsSummary.TopicWeakness(themeName: $0.theme.name,
                                                   wrongRate: $0.wrongRate,
                                                   sampleSize: $0.sampleSize)
            }
    }

    /// The newest 20 completed attempts -- the exact slice the screen shows,
    /// now as a `fetchLimit` rather than a `prefix` over every attempt ever
    /// recorded.
    private func recentAttempts() -> [QuizAnalyticsSummary.AttemptRow] {
        var descriptor = FetchDescriptor<QuizAttempt>(
            predicate: #Predicate { $0.completedAt != nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = 20
        return ((try? modelContext.fetch(descriptor)) ?? []).map {
            QuizAnalyticsSummary.AttemptRow(id: $0.id,
                                            scopeDescription: $0.scopeDescription,
                                            startedAt: $0.startedAt,
                                            scorePercent: $0.scorePercent)
        }
    }
}
