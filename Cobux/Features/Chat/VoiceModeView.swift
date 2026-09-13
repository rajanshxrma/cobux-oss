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
    /// Reduce Motion is a hard gate (CobuxMotion.swift): rows fade in
    /// rather than spring up, and the header glyph holds still.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            // The store's own reason first (60): under 1.5 GB free it refuses
            // the 327 MB download and says so here, once, calmly.
            return NeuralVoiceStore.shared.unavailableReason
                ?? (usingDefaultQualityVoice ? VoicePreference.upgradeRecipe : nil)
        }
    }

    /// Read once per visit, not once per body -- the same fix already applied
    /// to `SettingsView.availableVoices`, for the same call underneath.
    ///
    /// `VoicePreference.usingDefaultQualityVoice` resolves `selectedVoice()`,
    /// which falls through to `availableVoices()` and therefore to
    /// `AVSpeechSynthesisVoice.speechVoices()` -- the speech service
    /// enumerating every voice installed on the device. Reading it straight out
    /// of `voiceStatus` put that enumeration in front of Voice Mode's first
    /// frame AND repeated it on every subsequent body pass, and this view's
    /// body is re-evaluated constantly while a session runs: every transcript
    /// row, every controller state change, every streamed sentence.
    ///
    /// Starts `false`, so the frame before the read lands shows no banner. That
    /// is the right direction for a one-frame gap -- an upgrade nudge that
    /// appears and then vanishes would read as a glitch, while one that appears
    /// a frame late reads as nothing at all.
    @State private var usingDefaultQualityVoice = false
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

    // His finalized utterances append as right-aligned bubbles, the
    // assistant's sentences as left-aligned lines -- built view-side by
    // observing the controller's per-turn `liveTranscript`/`spokenSentences`
    // (which reset every turn) so the controller's state machine needed no
    // changes at all. `VoiceTranscriptEntry` and the row/scroll mechanics
    // below are shared with `SpokenQuizView` (`VoiceTranscriptView.swift`).
    @State private var transcript: [VoiceTranscriptEntry] = []
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
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.78)) {
                transcript.append(VoiceTranscriptEntry(text: spoken, isUser: true))
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
        // Behind the first frame, not in front of it. One yield hands the
        // cover's opening frame up before the voice enumeration runs.
        .task {
            await Task.yield()
            usingDefaultQualityVoice = VoicePreference.usingDefaultQualityVoice
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
            if phase == .background { endSession() }
            // Re-check on return: if they went and downloaded the voice, the banner
            // should be gone when they come back, not linger until the next launch.
            if phase == .active {
                voiceStoreState = NeuralVoiceStore.shared.state
                // Same reason, same trip: a voice downloaded while away must
                // clear the banner on return. This is the ONLY thing that can
                // change the answer, which is exactly why re-reading it here is
                // enough and re-reading it per body never was.
                usingDefaultQualityVoice = VoicePreference.usingDefaultQualityVoice
            }
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
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
            case .thinking:
                ProgressView()
                    .tint(.white)
            case .speaking:
                Image(systemName: "waveform.circle.fill")
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
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
    /// appearing in the bubble as he speaks, then a thinking line. Row/scroll
    /// mechanics live in `VoiceTranscriptScrollView` (`VoiceTranscriptView.swift`),
    /// shared with `SpokenQuizView`.
    private var transcriptView: some View {
        VoiceTranscriptScrollView(
            entries: transcript,
            animatedTrigger: controller?.state,
            immediateTrigger: controller?.liveTranscript,
            tail: { transcriptTail }
        )
    }

    @ViewBuilder
    private var transcriptTail: some View {
        switch controller?.state ?? .idle {
        case .listening:
            VoiceTranscriptRow(
                text: (controller?.liveTranscript.isEmpty ?? true) ? "Listening…" : (controller?.liveTranscript ?? ""),
                isUser: true,
                isLive: controller?.liveTranscript.isEmpty ?? true
            )
        case .thinking:
            thinkingLine
        case .speaking:
            // Captions land with the audio now, so when the state flips to
            // speaking the first sentence is still being synthesized. Keep
            // "Thinking…" up until the voice actually starts rather than show
            // a blank tail for that beat.
            if controller?.spokenSentences.isEmpty ?? true {
                thinkingLine
            }
        case .idle:
            EmptyView()
        }
    }

    private var thinkingLine: some View {
        Text("Thinking…")
            .font(.title3)
            .foregroundStyle(.white.opacity(0.6))
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
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.78)) {
            for sentence in newSentences {
                transcript.append(VoiceTranscriptEntry(text: sentence, isUser: false))
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
