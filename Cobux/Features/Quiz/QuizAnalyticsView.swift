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
    @Query(sort: \QuizAttempt.startedAt, order: .reverse) private var attempts: [QuizAttempt]
    @Query private var questions: [QuizQuestion]
    @Query private var themes: [Theme]
    @Query private var answerRecords: [QuizAnswerRecord]

    private var completedAttempts: [QuizAttempt] {
        attempts.filter { $0.completedAt != nil }
    }

    private var last30DaysAttempts: [QuizAttempt] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
        return completedAttempts.filter { $0.startedAt >= cutoff }
    }

    /// The number Anki users actually track — correct answers over answers
    /// actually given, not over the full assigned count (see `QuizAttempt.
    /// answeredCount` fix — ending a quiz early no longer distorts this).
    private var retentionRate30Days: Double? {
        let totalAnswered = last30DaysAttempts.reduce(0) { $0 + $1.answeredCount }
        guard totalAnswered > 0 else { return nil }
        let totalCorrect = last30DaysAttempts.reduce(0) { $0 + $1.correctCount }
        return Double(totalCorrect) / Double(totalAnswered)
    }

    private struct ForecastDay: Identifiable {
        let date: Date
        let count: Int
        var id: Date { date }
    }

    /// Next 14 days of due cards, from the real FSRS `dueDate` field —
    /// distinct from any per-book due count since it spans every book.
    private var reviewForecast: [ForecastDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let dueDates = questions.compactMap { $0.isSuspended ? nil : $0.dueDate }

        return (0..<14).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let count = dueDates.filter { $0 >= day && $0 < nextDay }.count
            return ForecastDay(date: day, count: count)
        }
    }

    private struct BookMastery: Identifiable {
        let bookTitle: String
        /// Mean FSRS-predicted retrievability across this book's reviewed questions --
        /// nil means nothing in this book has been reviewed yet, not "0% mastered".
        /// Decays honestly with time since last review, same as any FSRS forgetting curve.
        let meanRetrievability: Double?
        var id: String { bookTitle }
    }

    /// One entry per book that has at least one question with real review history.
    private var masteryByBook: [BookMastery] {
        let byBook = Dictionary(grouping: questions.filter { $0.book != nil }, by: { $0.book!.id })
        return byBook.compactMap { _, bookQuestions -> BookMastery? in
            guard let title = bookQuestions.first?.book?.title else { return nil }
            let reviewed = bookQuestions.filter { $0.fsrsReps > 0 && $0.lastReviewedAt != nil }
            guard !reviewed.isEmpty else {
                return BookMastery(bookTitle: title, meanRetrievability: nil)
            }
            let scores = reviewed.map { question -> Double in
                let elapsedDays = max(0, Date.now.timeIntervalSince(question.lastReviewedAt ?? .now) / 86400)
                return FSRS.retrievability(elapsedDays: elapsedDays, stability: max(question.fsrsStability, 0.01))
            }
            return BookMastery(bookTitle: title, meanRetrievability: scores.reduce(0, +) / Double(scores.count))
        }
        .sorted { ($0.meanRetrievability ?? -1) > ($1.meanRetrievability ?? -1) }
    }

    private struct TopicWeakness: Identifiable {
        let themeName: String
        let wrongRate: Double
        let sampleSize: Int
        var id: String { themeName }
    }

    /// Reuses `QuizModeService.weakestThemes` -- the same canonical-`Theme`-based weak-topic
    /// detection the Weak Spots quiz mode pools from, so this panel and that mode always agree
    /// on what "weak" means, the same way the due-count unification made Quiz Home and Daily
    /// Review agree on what "due" means.
    private var weakestTopics: [TopicWeakness] {
        QuizModeService.weakestThemes(themes: themes, answerRecords: answerRecords)
            .prefix(5)
            .map { entry in
                let sampleSize = answerRecords.filter { record in
                    guard let question = record.question else { return false }
                    let highlightIDs = Set(entry.theme.highlights.map(\.id))
                    return !Set(question.sourceHighlights.map(\.id)).isDisjoint(with: highlightIDs)
                }.count
                return TopicWeakness(themeName: entry.theme.name, wrongRate: entry.wrongRate, sampleSize: sampleSize)
            }
    }

    var body: some View {
        List {
            Section("Retention") {
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

            Section("Review Forecast") {
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
                Section("Recent Attempts") {
                    ForEach(completedAttempts.prefix(20)) { attempt in
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

            Section("Spend") {
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
