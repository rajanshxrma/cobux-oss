import SwiftUI
import SwiftData
import UIKit

/// Hands-free voice mode: listen → transcribe → ask Claude → speak the answer as it streams
/// in, sentence by sentence → listen again, until the user taps "End". Replaces `WalkModeView`
/// per Fable's voice architecture ruling — one engine, one surface, not two parallel voice
/// stacks. Unlike the old Walk Mode, a turn here streams straight to speech (no confirmation
/// delay) and shares the launching thread's own conversation, scoped and persisted exactly
/// like a text turn, rather than always landing in the general thread.
struct VoiceModeView: View {
    @Bindable var claudeService: ClaudeService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var books: [Book]

    let selectedBookID: UUID?
    let symposiumModeEnabled: Bool
    let initialConversationHistory: [AIMessage]

    @State private var controller: VoiceSessionController?
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

                Spacer()

                stateIcon

                Spacer()

                VStack(spacing: 10) {
                    captionArea

                    if let statusMessage = controller?.statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.65))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .transition(.opacity)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Tap-to-interrupt is the phase-one substitute for real barge-in — during
            // thinking/speaking it cancels the in-flight turn and returns to listening.
            controller?.interrupt()
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
            Text("Voice mode needs microphone and speech recognition access. Enable them in Settings to continue.")
        }
    }

    // MARK: - Visual pieces

    private var backgroundGradient: some View {
        LinearGradient(
            colors: CobuxColor.voiceGradient,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var stateIcon: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.cobuxAccent.opacity(0.35), Color.cobuxAccent.opacity(0.12)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 180, height: 180)
                .overlay(
                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 1)
                )

            iconImage
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(.white)
        }
        .animation(.easeOut(duration: 0.25), value: controller?.state)
    }

    @ViewBuilder
    private var iconImage: some View {
        switch controller?.state ?? .idle {
        case .idle:
            Image(systemName: "mic.slash.fill")
        case .listening:
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, options: .repeating)
        case .thinking:
            ProgressView()
                .tint(.white)
                .scaleEffect(1.5)
        case .speaking:
            Image(systemName: "waveform.circle.fill")
                .symbolEffect(.pulse, options: .repeating)
        }
    }

    private var captionArea: some View {
        Group {
            switch controller?.state ?? .idle {
            case .idle:
                Text("Voice mode listens, asks Claude, and speaks the answer back as it streams in — hands-free. Each question uses your Anthropic API credits. Tap anywhere while it's thinking or speaking to interrupt.")
            case .listening:
                Text((controller?.liveTranscript.isEmpty ?? true) ? "Listening…" : (controller?.liveTranscript ?? ""))
            case .thinking:
                Text("Thinking…")
            case .speaking:
                Text(controller?.spokenCaption ?? "")
            }
        }
        .font(.title3)
        .foregroundStyle(.white.opacity(0.92))
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .frame(minHeight: 80)
        .animation(.easeOut(duration: 0.2), value: controller?.liveTranscript)
        .animation(.easeOut(duration: 0.2), value: controller?.spokenCaption)
    }

    // MARK: - Setup

    private func setUpAndRequestPermissions() {
        let sessionController = VoiceSessionController(
            claudeService: claudeService,
            books: books,
            selectedBookID: selectedBookID,
            symposiumModeEnabled: symposiumModeEnabled,
            conversationHistory: initialConversationHistory
        )
        sessionController.onTurnCompleted = { userMessage, assistantReply, referencedTitles in
            persistTurn(userMessage: userMessage, assistantReply: assistantReply, referencedTitles: referencedTitles)
        }
        sessionController.onError = { _ in
            // Surfaced via `controller.statusMessage`, already observed by the view.
        }
        sessionController.onIdleTimeout = {
            endSession()
        }
        sessionController.onSessionBudgetExhausted = {
            endSession()
        }
        controller = sessionController

        sessionController.requestPermissions { granted in
            guard !isEnding else { return }
            if !granted {
                showPermissionAlert = true
                return
            }
            // Unlike text chat's mic button, voice mode starts listening immediately on
            // permission grant — the idle screen briefly explains what it does first if
            // permissions were already granted from a prior session.
            sessionController.start()
        }
    }

    /// A turn's user question + assistant reply persist exactly like a text turn — same
    /// `bookID` scoping, same model — so the thread the voice session was launched from
    /// reads as one continuous conversation once the user returns to it, not a separate
    /// voice-only history.
    private func persistTurn(userMessage: String, assistantReply: String, referencedTitles: [String]) {
        let userMsg = ChatMessage(content: userMessage, isUser: true, timestamp: .now, referencedBooks: [], bookID: selectedBookID)
        modelContext.insert(userMsg)
        let aiMsg = ChatMessage(content: assistantReply, isUser: false, timestamp: Date().addingTimeInterval(0.01), referencedBooks: referencedTitles, bookID: selectedBookID)
        modelContext.insert(aiMsg)
    }

    private func endSession() {
        isEnding = true
        controller?.end()
        dismiss()
    }
}
