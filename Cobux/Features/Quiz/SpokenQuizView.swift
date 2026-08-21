import SwiftUI
import SwiftData
import UIKit
import WidgetKit
import CobuxCore

/// Eyes-free quizzing -- listens to the question read aloud, listens for a spoken answer,
/// grades it the same way `.application` questions are (embedding similarity against
/// `question.explanation`), speaks the result, moves on. Visual language mirrors
/// `VoiceModeView` deliberately -- one voice surface, one look, even though the underlying
/// controller (`SpokenQuizController`) is a separate simpler loop with no network call.
struct SpokenQuizView: View {
    let attempt: QuizAttempt
    let questions: [QuizQuestion]
    let onDone: () -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var books: [Book]

    @State private var controller: SpokenQuizController?
    @State private var showPermissionAlert = false
    @State private var isEnding = false
    /// `SpokenQuizController.onError` used to be wired to a no-op closure --
    /// every failure path in the controller (mic gone mid-call, on-device
    /// speech recognition unavailable, audio session setup failing) returns
    /// BEFORE advancing `state`, so silently dropping the message left the
    /// screen frozen on whatever icon was showing with no explanation and no
    /// way forward except the "End" button the user had no reason to know to
    /// tap. Surfacing it and ending the session (progress-so-far still
    /// saved, same as a manual End) turns a silent hang into a clear,
    /// recoverable failure.
    @State private var voiceErrorMessage: String?
    @State private var showVoiceErrorAlert = false

    var body: some View {
        ZStack {
            backgroundGradient

            VStack {
                HStack {
                    Spacer()
                    Button(action: endSession) {
                        Label("End", systemImage: "xmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                .padding(16)

                if let controller {
                    Text("Question \(min(controller.currentIndex + 1, questions.count)) of \(questions.count) · \(controller.correctCount) correct")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                stateIcon

                Spacer()

                captionArea
                    .padding(.bottom, 40)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: setUpAndRequestPermissions)
        .onDisappear {
            isEnding = true
            controller?.end()
        }
        .alert("Permission Needed", isPresented: $showPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                dismiss()
            }
            Button("Cancel", role: .cancel) { dismiss() }
        } message: {
            Text("Spoken quiz needs microphone and speech recognition access. Enable them in Settings to continue.")
        }
        .alert("Spoken Quiz Interrupted", isPresented: $showVoiceErrorAlert) {
            Button("OK", role: .cancel) { endSession() }
        } message: {
            Text(voiceErrorMessage ?? "Something interrupted the spoken quiz. Your progress so far is saved.")
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(colors: CobuxColor.voiceGradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }

    private var stateIcon: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.cobuxAccent.opacity(0.35), Color.cobuxAccent.opacity(0.12)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: 180, height: 180)
                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))

            iconImage
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(.white)
        }
        .animation(.easeOut(duration: 0.25), value: controller?.state)
    }

    @ViewBuilder
    private var iconImage: some View {
        switch controller?.state ?? .idle {
        case .idle, .done:
            Image(systemName: "mic.slash.fill")
        case .speakingQuestion, .speakingFeedback:
            Image(systemName: "waveform.circle.fill")
                .symbolEffect(.pulse, options: .repeating)
        case .listening:
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, options: .repeating)
        case .grading:
            ProgressView().tint(.white).scaleEffect(1.5)
        }
    }

    private var captionArea: some View {
        Group {
            switch controller?.state ?? .idle {
            case .idle:
                Text("Spoken Quiz reads each question aloud, listens for your answer, and grades it as you speak -- no screen needed.")
            case .speakingQuestion:
                Text(controller?.currentQuestion?.prompt ?? "")
            case .listening:
                Text((controller?.liveTranscript.isEmpty ?? true) ? "Listening…" : (controller?.liveTranscript ?? ""))
            case .grading:
                Text("Grading…")
            case .speakingFeedback:
                Text(controller?.lastFeedback ?? "")
            case .done:
                Text("Session complete.")
            }
        }
        .font(.title3)
        .foregroundStyle(.white.opacity(0.92))
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .frame(minHeight: 80)
        .animation(.easeOut(duration: 0.2), value: controller?.liveTranscript)
    }

    private func setUpAndRequestPermissions() {
        let sessionController = SpokenQuizController(questions: questions) { question, isCorrect, spokenAnswer in
            recordAnswer(question: question, isCorrect: isCorrect, spokenAnswer: spokenAnswer)
        }
        sessionController.onError = { message in
            // Same isEnding guard `requestPermissions`'s own completion uses
            // just below -- a trailing error callback racing an already
            // user-initiated end (or one this same closure just triggered)
            // must not resurrect the alert on a view that's on its way out.
            guard !isEnding else { return }
            voiceErrorMessage = message
            showVoiceErrorAlert = true
        }
        sessionController.onFinished = {
            finishAttempt()
        }
        controller = sessionController

        sessionController.requestPermissions { granted in
            guard !isEnding else { return }
            if !granted {
                showPermissionAlert = true
                return
            }
            sessionController.start()
        }
    }

    private func recordAnswer(question: QuizQuestion, isCorrect: Bool, spokenAnswer: String) {
        let record = QuizAnswerRecord(attempt: attempt, question: question)
        record.isCorrect = isCorrect
        record.answerText = spokenAnswer
        modelContext.insert(record)
        attempt.answers.append(record)
        attempt.answeredCount += 1
        if isCorrect { attempt.correctCount += 1 }

        // Same exam-cap-aware path QuizSessionView.recordCurrentAnswer uses -- without this,
        // a card from a book with an exam date, reviewed through Spoken Quiz, could be
        // scheduled past the exam. Spoken Quiz pulls from the same due queue Daily Review
        // does, so this was a live path, not a theoretical one.
        if let examDate = question.book?.examDate {
            let daysLeft = ExamCountdown.daysLeft(from: .now, to: examDate)
            FSRSService.recordReview(
                for: question,
                isCorrect: isCorrect,
                confidence: nil,
                desiredRetention: ExamCountdown.desiredRetention(daysLeft: daysLeft),
                maxIntervalDays: ExamCountdown.maxIntervalDays(daysLeft: daysLeft)
            )
        } else {
            FSRSService.recordReview(for: question, isCorrect: isCorrect, confidence: nil)
        }
    }

    private func finishAttempt() {
        attempt.completedAt = .now
        try? modelContext.save()
        // Spoken Quiz never routes through QuizResultsView (it dismisses straight back to Quiz
        // Home instead of showing a results screen), so it must do these itself -- otherwise a
        // spoken-only session left the streak and the watch complication silently stale, unlike
        // every other quiz mode.
        if !attempt.answers.isEmpty {
            StreakTracker.recordActivityToday()
            // Spoken Quiz dismisses straight back to Quiz Home (no results
            // screen), so milestones ride ContentView's celebration overlay.
            StreakCelebrationCenter.shared.checkForPendingMilestone()
        }
        WatchSyncService.sync(books: books)
        // Same stale-card guard as QuizResultsView -- this session's grades
        // must reach the Quick Check widget.
        WidgetCenter.shared.reloadTimelines(ofKind: "CobuxQuickCheckWidget")
        isEnding = true
        onDone()
        dismiss()
    }

    private func endSession() {
        isEnding = true
        controller?.end()
        finishAttempt()
    }
}
