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
    @Environment(\.scenePhase) private var scenePhase
    /// Reduce Motion is a hard gate (CobuxMotion.swift): rows fade in
    /// rather than spring up, and the header glyph holds still.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    // Finalized rows kept for the whole session -- question and feedback
    // land left-aligned, his recognized answer right-aligned, exactly the
    // treatment `VoiceModeView` ships (rule: converge onto that, not a third
    // hand-rolled transcript). `VoiceTranscriptEntry` and the row/scroll
    // mechanics live in `VoiceTranscriptView.swift`, shared with it.
    @State private var transcript: [VoiceTranscriptEntry] = []

    var body: some View {
        ZStack {
            backgroundGradient

            VStack(spacing: 0) {
                HStack {
                    stateGlyph
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
                        .padding(.bottom, 8)
                }

                // Same top-anchored two-sided transcript as Voice Mode --
                // this used to be a bottom `captionArea`, one centered line
                // per state, each replacing the last.
                if transcript.isEmpty && (controller?.state ?? .idle) == .idle {
                    Spacer()
                    idleExplainer
                    Spacer()
                } else {
                    transcriptView
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: setUpAndRequestPermissions)
        // Folds finalized rows into `transcript` as the controller's state
        // machine moves. `.grading` is deliberately not its own case here --
        // `gradeAndAdvance` sets `.grading` then `.speakingFeedback`
        // synchronously in the same call with no run-loop yield between
        // them, so SwiftUI's `onChange` can coalesce the two and never
        // observe `.grading` as a distinct value. Folding the answer into
        // the `.speakingFeedback` case (using `liveTranscript`, which isn't
        // cleared until the NEXT question's `startListening`) is correct
        // regardless of whether that coalescing happens.
        .onChange(of: controller?.state) { _, newState in
            guard let newState else { return }
            switch newState {
            case .speakingQuestion:
                guard let prompt = controller?.currentQuestion?.prompt else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.78)) {
                    transcript.append(VoiceTranscriptEntry(text: prompt, isUser: false))
                }
            case .speakingFeedback:
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.78)) {
                    if let spoken = controller?.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
                       !spoken.isEmpty {
                        transcript.append(VoiceTranscriptEntry(text: spoken, isUser: true))
                    }
                    if let feedback = controller?.lastFeedback {
                        transcript.append(VoiceTranscriptEntry(text: feedback, isUser: false))
                    }
                }
            case .idle, .listening, .grading, .done:
                break
            }
        }
        // Both voice surfaces are presented as `fullScreenCover`, which stays
        // presented when the app backgrounds -- so `onDisappear` never fires and
        // tearing down only from there meant the session survived being "closed".
        // The mic stayed hot, the .duckOthers audio session stayed active so every
        // other app's audio stayed ducked, the synthesizer kept talking until iOS
        // suspended the process, and an in-flight stream kept spending API credits
        // with nobody listening. Reported as "it keeps going even if closed".
        // `QuizSessionView` already observed scenePhase this way; the voice
        // surfaces just never got it.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { controller?.end() }
        }
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

    /// Compact header glyph, byte-for-byte the same treatment as
    /// `VoiceModeView.stateGlyph` -- the session's state at a glance,
    /// without pushing the transcript off-center the way the old 180pt
    /// center orb did.
    @ViewBuilder
    private var stateGlyph: some View {
        Group {
            switch controller?.state ?? .idle {
            case .idle, .done:
                Image(systemName: "mic.slash.fill")
            case .speakingQuestion, .speakingFeedback:
                Image(systemName: "waveform.circle.fill")
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            case .listening:
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
            case .grading:
                ProgressView().tint(.white)
            }
        }
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
        .frame(width: 36, height: 36)
        .background(Circle().fill(Color.cobuxAccent.opacity(0.25)))
        .animation(.easeOut(duration: 0.25), value: controller?.state)
    }

    private var idleExplainer: some View {
        Text("Spoken Quiz reads each question aloud, listens for your answer, and grades it as you speak -- no screen needed.")
            .font(.title3)
            .foregroundStyle(.white.opacity(0.92))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
    }

    /// The session as one top-anchored, two-sided transcript -- question and
    /// feedback left-aligned, his recognized answer right-aligned, sharing
    /// `VoiceModeView`'s `VoiceTranscriptScrollView` mechanics rather than a
    /// third hand-rolled implementation.
    private var transcriptView: some View {
        VoiceTranscriptScrollView(
            entries: transcript,
            animatedTrigger: controller?.state,
            immediateTrigger: controller?.liveTranscript,
            tail: { transcriptTail }
        )
    }

    /// The in-progress moment at the tail: his answer growing live while
    /// listening, or a "Grading…" line. Everything else (the question, the
    /// feedback) is already a finalized row in `transcript` by the time its
    /// state is showing, so those cases render nothing here.
    @ViewBuilder
    private var transcriptTail: some View {
        switch controller?.state ?? .idle {
        case .listening:
            VoiceTranscriptRow(
                text: (controller?.liveTranscript.isEmpty ?? true) ? "Listening…" : (controller?.liveTranscript ?? ""),
                isUser: true,
                isLive: controller?.liveTranscript.isEmpty ?? true
            )
        case .grading:
            Text("Grading…")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.6))
        case .idle, .speakingQuestion, .speakingFeedback, .done:
            EmptyView()
        }
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
