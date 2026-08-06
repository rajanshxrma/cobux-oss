import SwiftUI
import SwiftData
import Charts

/// The largest missed opportunity identified in the pre-2.0.0 audit: every
/// `QuizAttempt`/`QuizAnswerRecord` is persisted and then never read again
/// anywhere in the app — there was no `@Query` for either type at all.
/// Everything here is straightforward reads of data that already exists;
/// no new model fields needed.
struct QuizAnalyticsView: View {
    @Query(sort: \QuizAttempt.startedAt, order: .reverse) private var attempts: [QuizAttempt]
    @Query private var questions: [QuizQuestion]

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
