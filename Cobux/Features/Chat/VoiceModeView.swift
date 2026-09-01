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
    @Environment(\.scenePhase) private var scenePhase
    @State private var voiceStoreState: NeuralVoiceStore.State = NeuralVoiceStore.shared.state

    /// What to tell him about the voice, or nil once the good one is in use and there's
    /// nothing worth saying. Downloading is worth naming: the first session speaks in the
    /// basic system voice, and without this line that reads as the bug he already reported
    /// twice rather than a one-time download finishing in the background.
    private var voiceStatus: String? {
        switch voiceStoreState {
        case .ready:
            return nil
        case .downloading:
            return "Downloading Cobux's natural voice (about 330 MB, one time, Wi-Fi only). Until it's ready, this uses the basic system voice."
        case .notStarted, .unavailable:
            return VoicePreference.usingDefaultQualityVoice ? VoicePreference.upgradeRecipe : nil
        }
    }
    @Query private var books: [Book]

    let selectedBookID: UUID?
    let symposiumModeEnabled: Bool
    let initialConversationHistory: [AIMessage]
    /// Only meaningful when launched from the "My Journal" thread
    /// (`selectedBookID == ChatPromptBuilder.journalThreadID`), whose voice
    /// turns are grounded in these entries; every other thread's assembly
    /// ignores them, exactly as text chat's does. Defaults empty so any call
    /// site that predates the journal thread compiles unchanged.
    var personalWritingEntries: [PersonalWritingEntry] = []

    @State private var controller: VoiceSessionController?
    @State private var showPermissionAlert = false
    @State private var isEnding = false

    /// One spoken exchange element, kept for the whole session. His finalized
    /// utterances append as right-aligned bubbles, the assistant's sentences
    /// as left-aligned lines -- built view-side by observing the controller's
    /// per-turn `liveTranscript`/`spokenSentences` (which reset every turn) so
    /// the controller's state machine needed no changes at all.
    private struct TranscriptEntry: Identifiable {
        let id = UUID()
        let text: String
        let isUser: Bool
    }

    @State private var transcript: [TranscriptEntry] = []
    /// How many of the CURRENT turn's `spokenSentences` are already folded
    /// into `transcript` -- resets to 0 when the controller starts a new turn
    /// (its array shrinks back to empty).
    @State private var syncedSentenceCount = 0

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

                // The session reads as a two-sided chat transcript growing
                // from the top -- Rajan's ask, replacing the old layout where
                // HIS speech was one centered line and everything sat pinned
                // to the bottom as a caption strip.
                if transcript.isEmpty && (controller?.state ?? .idle) == .idle {
                    Spacer()
                    idleExplainer
                    Spacer()
                } else {
                    transcriptView
                }

                if let statusMessage = controller?.statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 16)
                        .transition(.opacity)
                }
            }
        }
        // His utterance finalizes into a bubble the moment the turn leaves
        // listening -- `liveTranscript` still holds the full recognized text
        // then (it's only cleared when the NEXT listen starts).
        .onChange(of: controller?.state) { _, newState in
            guard newState == .thinking,
                  let spoken = controller?.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
                  !spoken.isEmpty else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                transcript.append(TranscriptEntry(text: spoken, isUser: true))
            }
        }
        .onChange(of: controller?.spokenSentences.count) { _, _ in
            syncSpokenSentences()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Tap-to-interrupt is the phase-one substitute for real barge-in — during
            // thinking/speaking it cancels the in-flight turn and returns to listening.
            controller?.interrupt()
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: setUpAndRequestPermissions)
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
            if phase == .background { endSession() }
            // Re-check on return: if they went and downloaded the voice, the banner
            // should be gone when they come back, not linger until the next launch.
            if phase == .active { voiceStoreState = NeuralVoiceStore.shared.state }
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

    /// The compact header form of the old 180 pt center orb -- the session's
    /// state at a glance, without pushing the transcript off-center.
    @ViewBuilder
    private var stateGlyph: some View {
        Group {
            switch controller?.state ?? .idle {
            case .idle:
                Image(systemName: "mic.slash.fill")
            case .listening:
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            case .thinking:
                ProgressView()
                    .tint(.white)
            case .speaking:
                Image(systemName: "waveform.circle.fill")
                    .symbolEffect(.pulse, options: .repeating)
            }
        }
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
        .frame(width: 36, height: 36)
        .background(Circle().fill(Color.cobuxAccent.opacity(0.25)))
        .animation(.easeOut(duration: 0.25), value: controller?.state)
    }

    private var idleExplainer: some View {
        VStack(spacing: 18) {
            Text("Voice mode listens, asks Claude, and speaks the answer back as it streams in — hands-free. Each question uses your Anthropic API credits. Tap anywhere while it's thinking or speaking to interrupt.")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
            // The nudge lives HERE, not only in Settings. It already existed as a
            // grey caption on the Settings > Voice Mode screen -- which nobody using
            // Voice Mode ever opens, so the one piece of information standing between
            // Rajan and a better voice was filed where he'd never see it. Downloading
            // an enhanced voice is the ONLY way to sound better: Apple doesn't expose
            // the Siri voices to third-party apps at all, so this text is the fix.
            if let voiceStatus {
                Text(voiceStatus)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.leading)
                    .padding(14)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(.horizontal, 32)
    }

    /// The whole session as one top-anchored, two-sided transcript: his
    /// utterances right-aligned bubbles, the assistant's sentences left-
    /// aligned lines spring-appending as they're actually spoken (the same
    /// insertion transition the old sentence stack used, now applied to both
    /// sides). The in-progress moment renders live at the tail -- his words
    /// appearing in the bubble as he speaks, then a thinking line.
    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(transcript) { entry in
                        transcriptRow(text: entry.text, isUser: entry.isUser, isLive: false)
                    }

                    switch controller?.state ?? .idle {
                    case .listening:
                        transcriptRow(
                            text: (controller?.liveTranscript.isEmpty ?? true) ? "Listening…" : (controller?.liveTranscript ?? ""),
                            isUser: true,
                            isLive: controller?.liveTranscript.isEmpty ?? true
                        )
                    case .thinking:
                        Text("Thinking…")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.6))
                    case .idle, .speaking:
                        EmptyView()
                    }

                    // Stable tail anchor -- live rows change identity as
                    // states flip, so auto-scroll targets this instead.
                    Color.clear
                        .frame(height: 1)
                        .id("transcriptTail")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: transcript.count) { _, _ in
                withAnimation { proxy.scrollTo("transcriptTail", anchor: .bottom) }
            }
            .onChange(of: controller?.liveTranscript) { _, _ in
                proxy.scrollTo("transcriptTail", anchor: .bottom)
            }
            .onChange(of: controller?.state) { _, _ in
                withAnimation { proxy.scrollTo("transcriptTail", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func transcriptRow(text: String, isUser: Bool, isLive: Bool) -> some View {
        if isUser {
            HStack {
                Spacer(minLength: 48)
                Text(text)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(isLive ? 0.6 : 0.95))
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 18))
            }
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .bottom))
                    .animation(.spring(response: 0.38, dampingFraction: 0.78)),
                removal: .opacity
            ))
        } else {
            Text(text)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .bottom))
                        .animation(.spring(response: 0.38, dampingFraction: 0.78)),
                    removal: .opacity
                ))
        }
    }

    /// Folds newly spoken sentences of the current turn into the transcript
    /// as they're actually spoken. The controller resets `spokenSentences`
    /// to empty at each new turn -- detected as the count shrinking -- so
    /// `syncedSentenceCount` starts over while everything already folded
    /// stays in `transcript` for the life of the session.
    private func syncSpokenSentences() {
        guard let sentences = controller?.spokenSentences else { return }
        if sentences.count < syncedSentenceCount { syncedSentenceCount = 0 }
        guard sentences.count > syncedSentenceCount else { return }
        let newSentences = sentences[syncedSentenceCount...]
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
            for sentence in newSentences {
                transcript.append(TranscriptEntry(text: sentence, isUser: false))
            }
        }
        syncedSentenceCount = sentences.count
    }

    // MARK: - Setup

    private func setUpAndRequestPermissions() {
        // `onAppear` can fire more than once for the same presentation. Building a
        // second controller over the first orphaned it mid-session, still holding a
        // hot mic and an active audio session with nothing left to call `end()` on it.
        guard controller == nil else { return }
        let sessionController = VoiceSessionController(
            claudeService: claudeService,
            books: books,
            selectedBookID: selectedBookID,
            symposiumModeEnabled: symposiumModeEnabled,
            conversationHistory: initialConversationHistory,
            personalWritingEntries: personalWritingEntries
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
