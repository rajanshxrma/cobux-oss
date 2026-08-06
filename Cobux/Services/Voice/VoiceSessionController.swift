import Foundation
import Speech
import AVFoundation
import CobuxCore

enum VoiceState: Equatable {
    case idle, listening, thinking, speaking
}

/// Half-duplex, streaming, turn-based voice loop — replaces `WalkModeAudioController`.
/// Reuses `ChatPromptBuilder`/`streamMessageCached` so a voice turn and a text turn scoped
/// the same way produce the same prompt by construction, and `SpeechChunker` to start
/// speaking the first sentence the moment it arrives instead of waiting for the whole reply.
///
/// The audio session is configured once in `start()` and held for the whole session — never
/// flipped per phase the way `WalkModeAudioController` did. Per Fable's voice architecture
/// ruling, this is both the fix for the old half-duplex clunkiness and the structural
/// prerequisite for real duplex/AEC later without a rewrite.
@Observable
final class VoiceSessionController: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var state: VoiceState = .idle
    private(set) var liveTranscript = ""
    private(set) var spokenCaption = ""
    private(set) var statusMessage: String?
    private(set) var conversationHistory: [AIMessage]

    /// Fires once a full turn (user question + assistant reply) is persisted into
    /// `conversationHistory` — the owner uses this to also persist a `ChatMessage` pair, so
    /// voice and text share one conversation instead of a separate voice-only history.
    var onTurnCompleted: ((_ userMessage: String, _ assistantReply: String, _ referencedTitles: [String]) -> Void)?
    var onError: ((String) -> Void)?
    /// Fires when nothing has cleared the minimum-question-words floor for `idleTimeout` — the
    /// "phone in a pocket" guard. The owner ends the session on this.
    var onIdleTimeout: (() -> Void)?

    private let claudeService: ClaudeService
    private let books: [Book]
    private let selectedBookID: UUID?
    private let symposiumModeEnabled: Bool

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let synthesizer = AVSpeechSynthesizer()

    private var silenceTimer: Timer?
    private var idleTimer: Timer?
    private var lastTranscript = ""
    private var lastChangeDate = Date()
    private var isIntentionallyStoppingRecognition = false
    private var sessionActive = false

    private var streamTask: Task<Void, Never>?
    private var streamInFlight = false
    private var chunker: SpeechChunker?
    private var utteranceQueue: [String] = []
    private var isSpeakingQueue = false
    private var currentTurnUserMessage: String?

    /// This session's cumulative real spend, computed from the delta in `UsageTracker`'s
    /// running monthly estimate before/after each turn — `ClaudeService` already records real
    /// usage internally, so this needs no extra plumbing to get an accurate figure.
    private var sessionSpentDollars: Double = 0
    private var sessionWarningSpoken = false
    private var sessionShouldEndAfterSpeech = false
    /// Fires once the spoken end-of-budget message has finished — the owner ends the session.
    var onSessionBudgetExhausted: (() -> Void)?

    // Silence detection: how long the transcript must sit unchanged before we treat the user
    // as done speaking — real VAD is not phase-one work, per Fable's ruling.
    private let silenceThreshold: TimeInterval = 1.2
    /// Fragments shorter than this are almost certainly noise/mumbling, not a real question —
    /// dropped without ever spending a credit. Same floor `WalkModeAudioController` used.
    private let minimumQuestionWords = 3
    /// The "phone in a pocket" guard from Fable's ruling — named as a judgment call to tune
    /// against real use, not a measured constant.
    static let idleTimeout: TimeInterval = 120
    /// Voice replies stay short by design (2-4 spoken sentences per the prompt instruction) —
    /// a much tighter cap than text chat's 8192, since a rambling spoken reply is worse UX
    /// than a short one and this also bounds worst-case per-turn cost.
    static let voiceMaxTokens = 1024
    /// A soft, session-scoped spend ceiling — separate from and additional to the existing
    /// monthly `BudgetGuard` cap (shared with quiz generation). Text chat has never had any
    /// per-turn spend guard; voice is the first to need one, both because it's the first
    /// feature that can rack up turns hands-free with no screen to glance at, and because a
    /// runaway continuous session is a real new failure mode text chat doesn't have. Named an
    /// uncertainty by Fable: ship as a documented constant, tune against real use.
    static let sessionCeilingDollars: Double = 0.25
    private static let sessionWarningRatio: Double = 0.8

    init(claudeService: ClaudeService, books: [Book], selectedBookID: UUID?, symposiumModeEnabled: Bool, conversationHistory: [AIMessage]) {
        self.claudeService = claudeService
        self.books = books
        self.selectedBookID = selectedBookID
        self.symposiumModeEnabled = symposiumModeEnabled
        self.conversationHistory = conversationHistory
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Permissions

    func requestPermissions(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            guard speechStatus == .authorized else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    // MARK: - Session lifecycle

    func start() {
        guard !sessionActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            sessionActive = true
        } catch {
            onError?("Couldn't set up the audio session.")
            return
        }
        startListening()
    }

    func end() {
        stopListening()
        stopSpeakingQueue()
        streamTask?.cancel()
        streamTask = nil
        streamInFlight = false
        idleTimer?.invalidate()
        idleTimer = nil
        guard sessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        sessionActive = false
    }

    /// Tap-to-interrupt: the phase-one substitute for real barge-in per Fable's ruling.
    /// Cancels whatever's in flight — the network stream if still thinking, or queued speech
    /// if already speaking — and returns straight to listening.
    func interrupt() {
        guard state == .thinking || state == .speaking else { return }
        streamTask?.cancel()
        streamTask = nil
        streamInFlight = false
        chunker = nil
        currentTurnUserMessage = nil
        stopSpeakingQueue()
        startListening()
    }

    // MARK: - Listening / STT

    private func startListening() {
        stopListeningInternal()
        resetIdleTimer()
        liveTranscript = ""
        statusMessage = nil

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            onError?("Speech recognition isn't available right now.")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On-device recognition is free, private, and avoids the server path's per-request
        // throttling that a long continuous voice session would otherwise hit — both Rajan's
        // and Utkarsh's devices support it, per Fable's ruling.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        lastTranscript = ""
        lastChangeDate = Date()

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            onError?("Couldn't start the microphone.")
            return
        }

        isIntentionallyStoppingRecognition = false
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                if text != self.lastTranscript {
                    self.lastTranscript = text
                    self.lastChangeDate = Date()
                    DispatchQueue.main.async { self.liveTranscript = text }
                }
            }

            if let error {
                let wasIntentional = self.isIntentionallyStoppingRecognition
                self.isIntentionallyStoppingRecognition = false
                if wasIntentional { return }
                let nsError = error as NSError
                if nsError.domain == "kAFAssistantErrorDomain" && [203, 216, 301, 1110].contains(nsError.code) {
                    return
                }
                DispatchQueue.main.async { self.onError?(error.localizedDescription) }
            }
        }

        startSilenceTimer()
        state = .listening
    }

    private func startSilenceTimer() {
        silenceTimer?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(self.lastChangeDate)
            if elapsed >= self.silenceThreshold && !self.lastTranscript.isEmpty {
                let finalText = self.lastTranscript
                self.stopListeningInternal()
                DispatchQueue.main.async { self.handleFinalTranscript(finalText) }
            }
        }
        silenceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopListening() {
        stopListeningInternal()
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    private func stopListeningInternal() {
        isIntentionallyStoppingRecognition = true
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }

    // MARK: - Turn handling

    private func handleFinalTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            startListening()
            return
        }
        let wordCount = trimmed.split(separator: " ").count
        guard wordCount >= minimumQuestionWords else {
            startListening()
            return
        }
        resetIdleTimer()
        askClaude(trimmed)
    }

    /// A rough pre-flight cost estimate — no live `count_tokens` round-trip, since that would
    /// add real latency to a loop where responsiveness is the whole point (voice already pays
    /// for accuracy by reconciling against `UsageTracker`'s real post-turn total in
    /// `sessionSpentDollars`, so this only needs to be a safe upper bound, not exact). ~4
    /// chars/token is the same rough heuristic `QuizGenerationService` falls back to when a
    /// live estimate isn't available. Output is priced at the hard `voiceMaxTokens` cap — a
    /// guard should never underestimate its worst case.
    private func estimatedTurnCost(question: String, assembled: ChatPromptBuilder.Assembled) -> Double {
        let promptChars: Int
        switch assembled {
        case .symposium(let systemPrompt, _): promptChars = systemPrompt.count
        case .bookScoped(let stable, let dynamic): promptChars = stable.count + dynamic.count
        case .general(let stable, let dynamic, _): promptChars = stable.count + dynamic.count
        }
        let historyChars = conversationHistory.reduce(0) { $0 + $1.content.count }
        let inputTokens = (promptChars + historyChars + question.count) / 4
        return UsageTracker.estimatedCost(
            inputTokens: inputTokens, outputTokens: Self.voiceMaxTokens,
            cacheCreationTokens: 0, cacheReadTokens: 0, model: .sonnet5
        )
    }

    private func askClaude(_ question: String) {
        guard !claudeService.apiKey.isEmpty else {
            failTurn("Add your Anthropic API key in Settings to use voice mode.")
            return
        }

        let assembled = ChatPromptBuilder.assemble(userMessage: question, books: books, selectedBookID: selectedBookID, symposiumModeEnabled: symposiumModeEnabled, isVoice: true)

        // Cost guards, spoken not just displayed — eyes-free mode needs eyes-free errors.
        // Two layers, per Fable's ruling: the existing monthly BudgetGuard (shared with quiz
        // generation, never previously applied to chat) and a new, additional session-scoped
        // soft ceiling that exists specifically because a hands-free session can rack up turns
        // with no screen to glance at.
        let proposedCost = estimatedTurnCost(question: question, assembled: assembled)
        let monthlyDecision = BudgetGuard(capDollars: QuizGenerationService.budgetCapDollars).evaluate(
            alreadySpentDollars: UsageTracker.currentMonthEstimate(),
            proposedCostDollars: proposedCost
        )
        guard monthlyDecision.allowed else {
            failTurn(monthlyDecision.blockReason ?? "This would exceed your monthly budget.")
            return
        }

        if sessionSpentDollars + proposedCost >= Self.sessionCeilingDollars {
            sessionShouldEndAfterSpeech = true
            enqueueSpeech(["You've reached your voice budget for this session, so I'm ending voice mode here. You can keep going in text chat."])
            return
        }
        if !sessionWarningSpoken && sessionSpentDollars >= Self.sessionCeilingDollars * Self.sessionWarningRatio {
            sessionWarningSpoken = true
            enqueueSpeech(["Heads up — you're near your voice budget for this session."])
        }

        state = .thinking
        currentTurnUserMessage = question
        spokenCaption = ""

        let historySnapshot = conversationHistory
        let turnStartSpend = UsageTracker.currentMonthEstimate()
        let chunker = SpeechChunker()
        self.chunker = chunker

        let stream: AsyncThrowingStream<String, Error>
        switch assembled {
        case .symposium(let systemPrompt, _):
            stream = claudeService.streamMessage(userMessage: question, conversationHistory: historySnapshot, systemPrompt: systemPrompt)
        case .bookScoped(let stableSystemPrompt, let dynamicContext):
            stream = claudeService.streamMessageCached(
                userMessage: question, conversationHistory: historySnapshot,
                stableSystemPrompt: stableSystemPrompt, dynamicContext: dynamicContext,
                options: ClaudeService.RequestOptions(maxTokens: Self.voiceMaxTokens, thinkingDisabled: true)
            )
        case .general(let stableSystemPrompt, let dynamicContext, _):
            stream = claudeService.streamMessageCached(
                userMessage: question, conversationHistory: historySnapshot,
                stableSystemPrompt: stableSystemPrompt, dynamicContext: dynamicContext,
                options: ClaudeService.RequestOptions(maxTokens: Self.voiceMaxTokens, thinkingDisabled: true)
            )
        }

        streamInFlight = true
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await delta in stream {
                    if Task.isCancelled { return }
                    let chunks = chunker.ingest(delta)
                    await MainActor.run { self.enqueueSpeech(chunks) }
                }
                if Task.isCancelled { return }
                let finalChunks = chunker.finish()
                await MainActor.run {
                    self.enqueueSpeech(finalChunks)
                    // Real cost, not the pre-flight estimate — ClaudeService already recorded
                    // it into UsageTracker's running total by the time this stream's
                    // continuation finishes, so the delta is this turn's actual spend.
                    let realTurnCost = max(0, UsageTracker.currentMonthEstimate() - turnStartSpend)
                    self.sessionSpentDollars += realTurnCost
                    self.finishTurn(rawText: chunker.rawText)
                }
            } catch is CancellationError {
                // Interrupted deliberately — `interrupt()` already reset state.
            } catch {
                await MainActor.run { self.failTurn(error.localizedDescription) }
            }
        }
    }

    private func finishTurn(rawText: String) {
        streamInFlight = false
        streamTask = nil

        let parsed = CitationResolver.parse(rawReply: rawText)
        let finalText = parsed.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty, let userMessage = currentTurnUserMessage else {
            failTurn("No response received. Please try again.")
            return
        }
        let resolvedTitles = CitationResolver.resolve(declaredTitles: parsed.declaredTitles, libraryTitles: books.map(\.title))

        conversationHistory.append(AIMessage(role: "user", content: userMessage))
        conversationHistory.append(AIMessage(role: "assistant", content: finalText))
        onTurnCompleted?(userMessage, finalText, resolvedTitles)
        currentTurnUserMessage = nil

        handleSpeechQueueDrained()
    }

    /// Guard/error messages are spoken, not just displayed — eyes-free mode needs eyes-free
    /// errors. Returns to listening once the message finishes, via the same
    /// `handleSpeechQueueDrained` path a normal turn uses, rather than interrupting mid-sentence.
    private func failTurn(_ message: String) {
        statusMessage = message
        onError?(message)
        chunker = nil
        streamTask = nil
        streamInFlight = false
        currentTurnUserMessage = nil
        enqueueSpeech([message])
    }

    // MARK: - Speaking

    private func enqueueSpeech(_ chunks: [String]) {
        guard !chunks.isEmpty else { return }
        utteranceQueue.append(contentsOf: chunks)
        if state != .speaking {
            state = .speaking
        }
        if !isSpeakingQueue {
            speakNextInQueue()
        }
    }

    private func speakNextInQueue() {
        guard !utteranceQueue.isEmpty else {
            isSpeakingQueue = false
            handleSpeechQueueDrained()
            return
        }
        isSpeakingQueue = true
        let next = utteranceQueue.removeFirst()
        spokenCaption += (spokenCaption.isEmpty ? "" : " ") + next
        let utterance = AVSpeechUtterance(string: next)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        synthesizer.speak(utterance)
    }

    /// Only actually returns to listening once BOTH the speech queue is empty AND the network
    /// stream has finished (`streamInFlight` false) — called from both ends (a chunk finishes
    /// speaking, or the stream finishes) since either can be the last one to complete.
    private func handleSpeechQueueDrained() {
        guard !streamInFlight, utteranceQueue.isEmpty, !isSpeakingQueue else { return }
        if sessionShouldEndAfterSpeech {
            onSessionBudgetExhausted?()
            return
        }
        startListening()
    }

    private func stopSpeakingQueue() {
        utteranceQueue.removeAll()
        isSpeakingQueue = false
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.speakNextInQueue() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.isSpeakingQueue = false }
    }

    // MARK: - Idle auto-pause

    /// Resets on every real (non-noise) transcript event. If nothing clears
    /// `minimumQuestionWords` for `idleTimeout`, `onIdleTimeout` fires — the owner ends the
    /// session rather than let it listen forever with the phone in a pocket.
    private func resetIdleTimer() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: Self.idleTimeout, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.onIdleTimeout?() }
        }
        idleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
