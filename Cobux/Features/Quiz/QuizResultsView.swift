import SwiftUI
import SwiftData
import WidgetKit

struct QuizResultsView: View {
    let attempt: QuizAttempt
    let onDone: () -> Void
    @Query private var books: [Book]
    @Query private var allAttempts: [QuizAttempt]
    @State private var showCelebration = false
    @State private var milestone = 0

    private var scorePercent: Int {
        Int((attempt.scorePercent ?? 0) * 100)
    }

    /// Answered-question totals per calendar day/week across ALL attempts,
    /// used for the personal-best callouts. A record only counts when there's
    /// real history to beat (a previous best > 0) — the first session ever
    /// shouldn't congratulate itself.
    private var personalBests: (day: Bool, dayTotal: Int, week: Bool, weekTotal: Int) {
        let calendar = Calendar.current
        var dayTotals: [Date: Int] = [:]
        var weekTotals: [Date: Int] = [:]
        for past in allAttempts {
            guard let completedAt = past.completedAt else { continue }
            dayTotals[calendar.startOfDay(for: completedAt), default: 0] += past.answeredCount
            if let weekStart = calendar.dateInterval(of: .weekOfYear, for: completedAt)?.start {
                weekTotals[weekStart, default: 0] += past.answeredCount
            }
        }

        let today = calendar.startOfDay(for: .now)
        let todayTotal = dayTotals[today] ?? 0
        let previousBestDay = dayTotals.filter { $0.key != today }.values.max() ?? 0

        let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: .now)?.start
        let thisWeekTotal = thisWeekStart.flatMap { weekTotals[$0] } ?? 0
        let previousBestWeek = weekTotals.filter { $0.key != thisWeekStart }.values.max() ?? 0

        return (
            day: previousBestDay > 0 && todayTotal > previousBestDay,
            dayTotal: todayTotal,
            week: previousBestWeek > 0 && thisWeekTotal > previousBestWeek,
            weekTotal: thisWeekTotal
        )
    }

    private var needsReviewAnswers: [QuizAnswerRecord] {
        attempt.answers.filter { !$0.isCorrect || $0.markedForReview || $0.confidenceRaw == 1 }
    }

    private var typeBreakdown: [(QuizQuestionType, Int, Int)] {
        let grouped = Dictionary(grouping: attempt.answers) { $0.question?.questionType ?? .recallMCQ }
        return grouped.map { type, answers in (type, answers.filter(\.isCorrect).count, answers.count) }
            .sorted { $0.1 > $1.1 }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if milestone > 0 {
                    milestoneBanner
                }

                scoreHeader

                if personalBests.day || personalBests.week {
                    personalBestSection
                }

                if !typeBreakdown.isEmpty {
                    typeBreakdownSection
                }

                if !needsReviewAnswers.isEmpty {
                    needsReviewSection
                }
            }
            .padding(16)
        }
        .navigationTitle("Results")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            // "End of any quiz/review session" per Fable's Watch companion ruling — the
            // results screen appearing is the natural signal a session just finished.
            WatchSyncService.sync(books: books)
            // The session just graded cards the Quick Check widget may still be
            // offering — reload it so a stale card can't collect a second,
            // schedule-skewing review from the home screen.
            WidgetCenter.shared.reloadTimelines(ofKind: "CobuxQuickCheckWidget")

            // Capture-and-clear immediately: this screen owns the milestone
            // moment for quiz sessions, and clearing now is what stops
            // ContentView's overlay from replaying it on the next foreground.
            milestone = StreakTracker.pendingMilestone
            if milestone > 0 {
                StreakTracker.clearPendingMilestone()
            }
            if attempt.answeredCount > 0 {
                showCelebration = true
            }
        }
        .overlay {
            if showCelebration {
                ConfettiView()
                    .ignoresSafeArea()
            }
        }
        .sensoryFeedback(.success, trigger: showCelebration)
        .toolbar {
            // This screen used to be a dead end -- back button hidden, no
            // replacement, the only way off was switching tabs entirely.
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done", action: onDone)
                    .fontWeight(.semibold)
            }
        }
    }

    private var milestoneBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "flame.fill")
                .font(.title2)
                .foregroundStyle(Color.cobuxWarning.gradient)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(milestone)-day streak milestone")
                    .font(.headline)
                Text("This session just crossed it. Keep the run alive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .cobuxCard()
    }

    private var personalBestSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if personalBests.day {
                Label("New best day — \(personalBests.dayTotal) questions answered", systemImage: "trophy.fill")
            }
            if personalBests.week {
                Label("New best week — \(personalBests.weekTotal) questions answered", systemImage: "calendar.badge.checkmark")
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Color.cobuxAccent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cobuxCard()
    }

    private var scoreHeader: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: attempt.scorePercent ?? 0)
                    .stroke(Color.cobuxAccent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack {
                    Text("\(scorePercent)%")
                        .font(.title)
                        .fontWeight(.bold)
                    // Denominator matches what scorePercent actually divides by
                    // (answeredCount, not the full assigned totalQuestions) --
                    // ending a quiz early no longer silently scores every
                    // un-reached question as wrong.
                    Text("\(attempt.correctCount)/\(attempt.answeredCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 140, height: 140)

            Text(attempt.scopeDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if attempt.skippedCount > 0 {
                Text("\(attempt.skippedCount) question(s) not reached")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 20)
    }

    private var typeBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By Question Type")
                .font(.headline)
            ForEach(typeBreakdown, id: \.0) { type, correct, total in
                HStack {
                    Text(label(for: type))
                    Spacer()
                    Text("\(correct)/\(total)")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
        .padding(16)
        .cobuxCard()
    }

    private var needsReviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Needs Review")
                .font(.headline)

            ForEach(needsReviewAnswers) { answer in
                if let question = answer.question {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(question.prompt)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(question.explanation)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cobuxCard()
                }
            }
        }
    }

    private func label(for type: QuizQuestionType) -> String {
        switch type {
        case .recallMCQ: return "Recall"
        case .exceptMCQ: return "Discrimination (EXCEPT)"
        case .trueFalse: return "True/False"
        case .application: return "Application"
        }
    }
}
