import SwiftUI
import SwiftData
import ActivityKit
import CobuxCore

struct QuizSessionView: View {
    @Bindable var attempt: QuizAttempt
    let questions: [QuizQuestion]
    /// Pops all the way back past this session AND its Results screen in one
    /// step (see the call site in `QuizScopeBuilderView`) — Results used to be
    /// a dead end with no way out except switching tabs.
    let onDone: () -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var currentIndex = 0
    @State private var selectedChoice: Int?
    /// Original-index order to render this question's choices in — computed
    /// fresh per presentation so choices don't always render in stored order
    /// (which trained answer position rather than content on repeat sessions).
    @State private var choiceOrder: [Int] = []
    @State private var applicationAnswerText = ""
    @State private var hasSubmitted = false
    @State private var confidence: Int?
    @State private var currentQuestionStart = Date()
    @State private var remainingSeconds: Int
    @State private var timer: Timer?
    @State private var showExitConfirm = false
    @State private var showResults = false
    @State private var markedForReview = false
    @State private var liveActivity: Activity<CobuxQuizActivityAttributes>?

    init(attempt: QuizAttempt, questions: [QuizQuestion], onDone: @escaping () -> Void) {
        self.attempt = attempt
        self.questions = questions
        self.onDone = onDone
        _remainingSeconds = State(initialValue: attempt.timeLimitSeconds ?? 0)
        // Set eagerly (not just in .onAppear) so the very first render already
        // has choices to show instead of a blank flash before onAppear fires.
        _choiceOrder = State(initialValue: Self.shuffledOrder(for: questions.first))
    }

    private var currentQuestion: QuizQuestion? {
        guard questions.indices.contains(currentIndex) else { return nil }
        return questions[currentIndex]
    }

    private var isExamMode: Bool { attempt.mode == .examSimulation }

    /// The book's own living color for a single-book session, falling back to the
    /// app-wide accent for Daily Review (`attempt.book == nil`, spans every book) --
    /// same promise as chat threads, never reached quiz sessions either.
    private var sessionAccent: Color {
        guard let hex = attempt.book?.coverColorHex else { return .cobuxAccent }
        return Color(hex: hex)
    }

    /// `.application` questions have no objective grading — confidence IS the
    /// correctness signal (`recordCurrentAnswer`) — so the self-rating must be
    /// collected even in exam mode, which otherwise intentionally suppresses
    /// it for objectively-gradable question types.
    private var requiresConfidenceToAdvance: Bool {
        !isExamMode || currentQuestion?.questionType == .application
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let question = currentQuestion {
                ScrollView {
                    QuestionCardView(
                        question: question,
                        choiceOrder: choiceOrder,
                        selectedChoice: $selectedChoice,
                        applicationAnswerText: $applicationAnswerText,
                        hasSubmitted: hasSubmitted,
                        showFeedback: hasSubmitted && !isExamMode,
                        accentColor: sessionAccent
                    )
                    .padding()
                }

                Spacer(minLength: 0)

                footer
            } else {
                ProgressView()
            }
        }
        .navigationTitle(attempt.scopeDescription)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("End Quiz") { showExitConfirm = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    markedForReview.toggle()
                } label: {
                    Image(systemName: markedForReview ? "flag.fill" : "flag")
                }
            }
        }
        .alert("End quiz early?", isPresented: $showExitConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("End Quiz", role: .destructive) { finishAttempt() }
        } message: {
            Text("Progress on \(attempt.answers.count) answered question(s) is still saved.")
        }
        .navigationDestination(isPresented: $showResults) {
            QuizResultsView(attempt: attempt, onDone: onDone)
        }
        .onAppear {
            // choiceOrder for the first question is already set in init.
            if isExamMode { startTimer(); startLiveActivity() }
        }
        .onDisappear { timer?.invalidate() }
        .onChange(of: scenePhase) { _, newPhase in
            // Wall-clock deadline means backgrounding can't gift free time —
            // just recompute where we actually are the moment we're active again.
            guard newPhase == .active, isExamMode, let deadline = attempt.deadline else { return }
            remainingSeconds = max(0, Int(deadline.timeIntervalSinceNow))
            if remainingSeconds == 0 { finishAttempt() }
        }
        .sensoryFeedback(trigger: hasSubmitted) { oldValue, newValue in
            guard newValue, !isExamMode, let question = currentQuestion else { return nil }
            if question.questionType == .application { return nil }
            return (selectedChoice == question.correctAnswerIndex) ? .success : .error
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Question \(min(currentIndex + 1, questions.count)) of \(questions.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if isExamMode {
                    Label(timeString(remainingSeconds), systemImage: "timer")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(remainingSeconds < 30 ? .red : .secondary)
                }
            }
            ProgressView(value: Double(currentIndex), total: Double(max(questions.count, 1)))
                .tint(sessionAccent)
        }
        .padding()
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 12) {
            if hasSubmitted, requiresConfidenceToAdvance {
                confidenceRow
            }

            Button {
                if hasSubmitted {
                    advance()
                } else {
                    submitAnswer()
                }
            } label: {
                Text(submitButtonLabel)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(canSubmit ? sessionAccent : Color.secondary.opacity(0.3))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: CobuxRadius.card))
            }
            .disabled(!canSubmit)
        }
        .padding()
    }

    private var submitButtonLabel: String {
        if !hasSubmitted { return "Submit Answer" }
        if requiresConfidenceToAdvance && confidence == nil { return "Rate your confidence above" }
        return currentIndex == questions.count - 1 ? "Finish" : "Next Question"
    }

    private var canSubmit: Bool {
        guard let question = currentQuestion else { return false }
        if !hasSubmitted {
            if question.questionType == .application { return !applicationAnswerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return selectedChoice != nil
        }
        if requiresConfidenceToAdvance { return confidence != nil }
        return true
    }

    private var confidenceRow: some View {
        HStack(spacing: 10) {
            Text("How confident were you?")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            confidenceChip(1, label: "Guessed")
            confidenceChip(2, label: "Unsure")
            confidenceChip(3, label: "Confident")
        }
    }

    private func confidenceChip(_ value: Int, label: String) -> some View {
        Button {
            confidence = value
        } label: {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(confidence == value ? sessionAccent : Color.secondary.opacity(0.12))
                .foregroundStyle(confidence == value ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func submitAnswer() {
        hasSubmitted = true
    }

    /// Fresh shuffle per presentation — repeat sessions shouldn't train answer
    /// position instead of content. `application` questions have no fixed
    /// choices to shuffle; `trueFalse`'s 2-choice shuffle is harmless (still
    /// only "True"/"False" either order) so it isn't special-cased out.
    private static func shuffledOrder(for question: QuizQuestion?) -> [Int] {
        guard let question, question.questionType != .application else { return [] }
        return Array(question.choices.indices).shuffled()
    }

    private func advance() {
        recordCurrentAnswer()

        if currentIndex == questions.count - 1 {
            finishAttempt()
            return
        }

        currentIndex += 1
        selectedChoice = nil
        applicationAnswerText = ""
        hasSubmitted = false
        confidence = nil
        markedForReview = false
        currentQuestionStart = .now
        choiceOrder = Self.shuffledOrder(for: currentQuestion)

        updateLiveActivity()
    }

    private func recordCurrentAnswer() {
        guard let question = currentQuestion else { return }

        let isCorrect: Bool
        switch question.questionType {
        case .application:
            // Embedding-graded against question.explanation ("what a strong answer would
            // touch on", per the generation prompt -- or "Answer: X" for free-recall cloze
            // cards, see ClozeService). Replaces the old confidence == 3 self-rating, where
            // the user's own guess about whether they were right WAS the correctness signal
            // -- real grading now, confidence stays collected as its own separate signal.
            isCorrect = gradeApplicationAnswer(applicationAnswerText, against: question.explanation)
        default:
            isCorrect = selectedChoice != nil && selectedChoice == question.correctAnswerIndex
        }

        let record = QuizAnswerRecord(attempt: attempt, question: question)
        record.selectedAnswerIndex = selectedChoice
        record.isCorrect = isCorrect
        record.confidenceRaw = confidence
        record.timeSpentSeconds = Date().timeIntervalSince(currentQuestionStart)
        record.markedForReview = markedForReview
        record.presentedChoiceOrder = choiceOrder
        if question.questionType == .application {
            record.answerText = applicationAnswerText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        modelContext.insert(record)

        attempt.answers.append(record)
        attempt.answeredCount += 1
        if isCorrect { attempt.correctCount += 1 }

        updateMemory(for: question, isCorrect: isCorrect)

        // FSRS runs alongside the existing HighlightMemory/Leitner update,
        // not replacing it -- HighlightMemory stays in the schema and still
        // drives the per-book due counts on QuizHomeView, while FSRS state
        // on the question itself drives Daily Review. Both being live
        // simultaneously is intentional, not a leftover.
        //
        // Reads question.book, not attempt.book -- Daily Review attempts are
        // created with book: nil (they span the whole library), so keying
        // off attempt.book silently dropped the exam cap for every card
        // reviewed through Daily Review instead of its own book's quiz flow,
        // even when that exact card's book had a real exam date set.
        if let examDate = question.book?.examDate {
            // Exam Countdown: nothing scheduled past exam day, and the
            // retention target rises as it approaches -- both computed fresh
            // per review since "days left" changes every day the app is used.
            let daysLeft = ExamCountdown.daysLeft(from: .now, to: examDate)
            FSRSService.recordReview(
                for: question,
                isCorrect: isCorrect,
                confidence: confidence,
                desiredRetention: ExamCountdown.desiredRetention(daysLeft: daysLeft),
                maxIntervalDays: ExamCountdown.maxIntervalDays(daysLeft: daysLeft)
            )
        } else {
            FSRSService.recordReview(for: question, isCorrect: isCorrect, confidence: confidence)
        }
    }

    /// On-device, free, no network call -- `EmbeddingService` is the exact same primitive
    /// already used for search retrieval (`SearchService.semanticSearch`), reused here to
    /// score a typed/spoken answer against the reference explanation. Falls back to marking
    /// the answer wrong (not a crash, not silently "correct") if either side can't be
    /// embedded -- e.g. an empty answer, or a language the on-device model doesn't support.
    private func gradeApplicationAnswer(_ answer: String, against reference: String) -> Bool {
        guard let answerVector = EmbeddingService.embed(answer),
              let referenceVector = EmbeddingService.embed(reference) else {
            return false
        }
        let similarity = EmbeddingService.cosineSimilarity(answerVector, referenceVector)
        return FreeRecallGrader.isCorrect(similarity: similarity)
    }

    private func updateMemory(for question: QuizQuestion, isCorrect: Bool) {
        for highlight in question.sourceHighlights {
            let memory = highlight.memory ?? {
                let created = HighlightMemory(highlight: highlight)
                highlight.memory = created
                modelContext.insert(created)
                return created
            }()
            memory.recordAnswer(correct: isCorrect, confidence: confidence)
        }
    }

    private func finishAttempt() {
        timer?.invalidate()
        if hasSubmitted == false, currentQuestion != nil, attempt.answers.count <= currentIndex {
            // Reached via "End Quiz" mid-question — don't record a
            // half-finished answer, just stop where they are.
        }
        attempt.completedAt = .now
        attempt.skippedCount = max(0, questions.count - attempt.answers.count)
        attempt.timeTakenSeconds = Int(Date().timeIntervalSince(attempt.startedAt))
        try? modelContext.save()
        if !attempt.answers.isEmpty {
            StreakTracker.recordActivityToday()
        }
        endLiveActivity()
        showResults = true
    }

    // MARK: - Live Activity (exam mode only)

    private func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = CobuxQuizActivityAttributes(scopeDescription: attempt.scopeDescription, totalQuestions: questions.count)
        let endDate = attempt.deadline ?? Date().addingTimeInterval(TimeInterval(remainingSeconds))
        let state = CobuxQuizActivityAttributes.ContentState(currentQuestionIndex: currentIndex, correctCount: attempt.correctCount, endDate: endDate)
        liveActivity = try? Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
    }

    private func updateLiveActivity() {
        guard let liveActivity else { return }
        let endDate = attempt.deadline ?? Date().addingTimeInterval(TimeInterval(remainingSeconds))
        let state = CobuxQuizActivityAttributes.ContentState(currentQuestionIndex: currentIndex, correctCount: attempt.correctCount, endDate: endDate)
        Task { await liveActivity.update(.init(state: state, staleDate: nil)) }
    }

    private func endLiveActivity() {
        guard let liveActivity else { return }
        Task { await liveActivity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Wall-clock deadline, not a decrementing counter — a counter simply stops
    /// while the app is suspended, silently gifting free time on any
    /// backgrounding. Comparing against `Date()` every tick can't drift that
    /// way regardless of how long the app was away.
    private func startTimer() {
        let deadline = Date().addingTimeInterval(TimeInterval(remainingSeconds))
        attempt.deadline = deadline
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            let remaining = max(0, Int(deadline.timeIntervalSinceNow))
            remainingSeconds = remaining
            if remaining == 0 {
                timer?.invalidate()
                finishAttempt()
            }
        }
    }

    private func timeString(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct QuestionCardView: View {
    let question: QuizQuestion
    /// Original-index render order for this presentation — see
    /// `QuizSessionView.shuffledOrder(for:)`.
    let choiceOrder: [Int]
    @Binding var selectedChoice: Int?
    @Binding var applicationAnswerText: String
    let hasSubmitted: Bool
    let showFeedback: Bool
    var accentColor: Color = .cobuxAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(question.prompt)
                .font(.title3)
                .fontWeight(.semibold)

            if question.questionType == .application {
                TextEditor(text: $applicationAnswerText)
                    .frame(minHeight: 100)
                    .padding(8)
                    .cobuxCard()
                    .disabled(hasSubmitted)

                if hasSubmitted {
                    Text(question.explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding()
                        .background(accentColor.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: CobuxRadius.card))
                }
            } else {
                ForEach(choiceOrder, id: \.self) { index in
                    choiceRow(index)
                }

                if showFeedback {
                    Text(question.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        }
    }

    private func choiceRow(_ index: Int) -> some View {
        let isSelected = selectedChoice == index
        let isCorrectChoice = question.correctAnswerIndex == index

        return Button {
            guard !hasSubmitted else { return }
            selectedChoice = index
        } label: {
            HStack {
                Text(question.choices[index])
                Spacer()
                if showFeedback, isCorrectChoice {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if showFeedback, isSelected, !isCorrectChoice {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            .padding()
            .background(rowBackground(isSelected: isSelected, isCorrectChoice: isCorrectChoice))
            .clipShape(RoundedRectangle(cornerRadius: CobuxRadius.structural))
            .overlay(
                RoundedRectangle(cornerRadius: CobuxRadius.structural)
                    .stroke(isSelected ? accentColor : Color.secondary.opacity(0.15), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(hasSubmitted)
    }

    private func rowBackground(isSelected: Bool, isCorrectChoice: Bool) -> Color {
        if showFeedback {
            if isCorrectChoice { return .green.opacity(0.12) }
            if isSelected { return .red.opacity(0.12) }
        }
        return isSelected ? accentColor.opacity(0.08) : Color.secondary.opacity(0.06)
    }
}
