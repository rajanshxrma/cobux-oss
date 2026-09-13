import SwiftUI
import SwiftData
import WidgetKit

struct QuizResultsView: View {
    let attempt: QuizAttempt
    let onDone: () -> Void
    @Environment(\.modelContext) private var modelContext
    /// Questions retired from this screen, so the card leaves at once
    /// instead of waiting for the next fetch.
    @State private var retiredQuestionIDs: Set<UUID> = []
    @State private var showCelebration = false
    @State private var milestone = 0
    /// Computed ONCE, in `.task`, after the first frame -- `nil` until then,
    /// so the section is simply absent rather than drawn from a guess.
    ///
    /// This was `@Query private var allAttempts: [QuizAttempt]` -- every
    /// attempt ever recorded, materialised whole and re-fetched on every store
    /// save for as long as this screen was up -- feeding a computed property
    /// that rebuilt both dictionaries on EVERY body evaluation (and `body`
    /// read it up to three times per pass). Now a single fetch of two columns
    /// (`completedAt`, `answeredCount`) over completed attempts, folded once.
    @State private var personalBests: PersonalBests?

    private var scorePercent: Int {
        Int((attempt.scorePercent ?? 0) * 100)
    }

    struct PersonalBests: Equatable {
        var day = false
        var dayTotal = 0
        var week = false
        var weekTotal = 0
    }

    /// Answered-question totals per calendar day/week across ALL completed
    /// attempts, used for the personal-best callouts. A record only counts
    /// when there's real history to beat (a previous best > 0) — the first
    /// session ever shouldn't congratulate itself.
    ///
    /// The window is deliberately NOT narrowed to this week: "best day" and
    /// "best week" are compared against every earlier day and week he has,
    /// so the predicate is `completedAt != nil` and the bound is the two
    /// columns, not the row count. `@MainActor` explicitly, the way
    /// `BookDetailView.loadContents` is: it reads the main context and
    /// assigns `@State` (SE-0338).
    @MainActor
    private func computePersonalBests() -> PersonalBests {
        var descriptor = FetchDescriptor<QuizAttempt>(
            predicate: #Predicate { $0.completedAt != nil })
        descriptor.propertiesToFetch = [\.completedAt, \.answeredCount]
        let completed = (try? modelContext.fetch(descriptor)) ?? []

        let calendar = Calendar.current
        var dayTotals: [Date: Int] = [:]
        var weekTotals: [Date: Int] = [:]
        for past in completed {
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

        return PersonalBests(
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

                if let personalBests, personalBests.day || personalBests.week {
                    personalBestSection(personalBests)
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
            // The context, not a `@Query books` held only to reach it.
            WatchSyncService.sync(modelContext: modelContext)
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
        // After the first frame, once. The ring, the score and the breakdown
        // are drawn from `attempt` alone; the record callout lands a beat
        // later if there is one.
        .task {
            await Task.yield()
            personalBests = computePersonalBests()
        }
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

    private func personalBestSection(_ personalBests: PersonalBests) -> some View {
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
                    // The ring's unfilled track. Ten points wide is not a
                    // hairline, so a translucent `.secondary` read as a murky
                    // grey band on the near-black ground; `cobuxLine` is the
                    // real token and carries its own dark value.
                    .stroke(Color.cobuxLine, lineWidth: 10)
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
                if let question = answer.question, !retiredQuestionIDs.contains(question.id) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(question.prompt)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(question.explanation)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        // Ledger M6 (Fable's ruling D on his "include more
                        // features like this", 11 Aug; filed for 53, built in
                        // 58). "Never again" means SUSPEND, the state FSRS and
                        // every due-count already honour -- not delete, and not
                        // a bury that resurfaces. Quiet text, no confirmation:
                        // the question is his to retire.
                        Button {
                            question.isSuspended = true
                            try? modelContext.save()
                            withAnimation(.easeOut(duration: 0.25)) {
                                _ = retiredQuestionIDs.insert(question.id)
                            }
                        } label: {
                            Label("Never ask me this again", systemImage: "eye.slash")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.cobuxAccent)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                        .accessibilityHint("Retires this question from every quiz")
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
