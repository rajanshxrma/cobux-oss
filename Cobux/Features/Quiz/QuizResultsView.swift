import SwiftUI
import SwiftData

struct QuizResultsView: View {
    let attempt: QuizAttempt
    let onDone: () -> Void
    @Query private var books: [Book]

    private var scorePercent: Int {
        Int((attempt.scorePercent ?? 0) * 100)
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
                scoreHeader

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
