import SwiftUI
import SwiftData
import UIKit

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

    @State private var controller: SpokenQuizController?
    @State private var showPermissionAlert = false
    @State private var isEnding = false

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
        sessionController.onError = { _ in }
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

        FSRSService.recordReview(for: question, isCorrect: isCorrect, confidence: nil)
    }

    private func finishAttempt() {
        attempt.completedAt = .now
        try? modelContext.save()
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
