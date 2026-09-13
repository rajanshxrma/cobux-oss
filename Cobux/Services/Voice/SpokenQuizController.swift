import Foundation
import Speech
import AVFoundation
import UIKit
import CobuxCore

enum SpokenQuizState: Equatable {
    case idle, speakingQuestion, listening, grading, speakingFeedback, done
}

/// The "Walk Mode Quiz" mode from the original plan, adapted: the plan's spec named reusing
/// `WalkModeView.swift`'s speech loop directly, but that file was deleted and replaced by
/// `VoiceSessionController` during the voice-companion rebuild. This reuses that rebuild's
/// proven STT session-management pattern (on-device-preferring `SFSpeechRecognizer`,
/// silence-timer turn-taking, one persistent `AVAudioSession`) but is otherwise a much
/// simpler loop -- no streaming network call, no prompt caching. Every question is graded as
/// free recall via the same `EmbeddingService`/`FreeRecallGrader` pair `.application`
/// questions use in `QuizSessionView` -- eyes-free mode doesn't care about the MCQ mechanic,
/// it just wants a natural spoken answer, graded the same way.
@Observable
final class SpokenQuizController: NSObject {
    private(set) var state: SpokenQuizState = .idle
    private(set) var liveTranscript = ""
    private(set) var currentIndex = 0
    private(set) var correctCount = 0
    private(set) var lastFeedback: String?

    var onError: ((String) -> Void)?
    /// Fires once every question has been asked and graded.
    var onFinished: (() -> Void)?

    private let questions: [QuizQuestion]
    private let onAnswer: (_ question: QuizQuestion, _ isCorrect: Bool, _ spokenAnswer: String) -> Void

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// The same speech queue Voice Mode speaks through -- on-device neural voice
    /// first, system voice per sentence when it declines, sentences pipelined so
    /// they join without a gap. Spoken Quiz once had no neural path at all, so
    /// the same app spoke in the good voice in Voice Mode and the robotic system
    /// voice here, which is the voice he has asked repeatedly to be rid of; one
    /// shared queue is what keeps the two surfaces from drifting apart again.
    private let speaker = SentenceSpeaker()

    private var silenceTimer: Timer?
    private var lastTranscript = ""
    private var lastChangeDate = Date()
    private var isIntentionallyStoppingRecognition = false
    private var sessionActive = false

    private let silenceThreshold: TimeInterval = 1.5
    private let minimumAnswerWords = 2

    var currentQuestion: QuizQuestion? {
        questions.indices.contains(currentIndex) ? questions[currentIndex] : nil
    }

    init(
        questions: [QuizQuestion],
        onAnswer: @escaping (_ question: QuizQuestion, _ isCorrect: Bool, _ spokenAnswer: String) -> Void
    ) {
        self.questions = questions
        self.onAnswer = onAnswer
        super.init()
        // The one place "an utterance finished" advances the quiz, whichever
        // engine spoke it -- a neural utterance that finished anywhere else
        // would leave the quiz sitting there forever.
        speaker.onDrained = { [weak self] in
            Task { @MainActor [weak self] in self?.handleSpeechFinished() }
        }
    }

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

    func start() {
        guard !sessionActive, !questions.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            // `.allowBluetoothA2DP`, not `.allowBluetooth` (HFP): with AirPods in, the
            // questions play through them at full bandwidth instead of out of the phone
            // speaker. HFP would narrow every voice to telephony bandwidth.
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            sessionActive = true
            registerAudioObservers()
        } catch {
            onError?("Couldn't set up the audio session.")
            return
        }
        // Neural weights load now, overlapping the first question's synthesis
        // being requested, rather than as a pause before the first spoken word.
        speaker.prewarm()
        // Eyes-free means no touch keeps the screen awake; auto-lock used to
        // background the scene and end the quiz mid-question.
        setKeepsScreenAwake(true)
        askCurrentQuestion()
    }

    func end() {
        stopListening()
        // Both engines, not just the synthesizer. The neural voice plays through
        // its own AVAudioEngine and used to keep reading the question after End,
        // then advance the quiz on a controller that had already been torn down.
        speaker.stop()
        silenceTimer?.invalidate()
        silenceTimer = nil
        NotificationCenter.default.removeObserver(self)
        guard sessionActive else { return }
        setKeepsScreenAwake(false)
        deactivateSession()
        sessionActive = false
    }

    /// `UIApplication.isIdleTimerDisabled`, hopped to the main actor: this class
    /// isn't isolated to it, even though every caller is on the main thread.
    private func setKeepsScreenAwake(_ awake: Bool) {
        Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = awake }
    }

    // MARK: - Audio interruptions and route changes

    /// Same teardown gaps `VoiceSessionController` had, and for the same reason: a phone call
    /// or a Bluetooth disconnect stopped the engine with nothing listening for it, leaving the
    /// quiz sitting in `.listening` with a dead microphone.
    private func registerAudioObservers() {
        let center = NotificationCenter.default
        center.removeObserver(self)
        center.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance()
        )
        center.addObserver(
            self, selector: #selector(handleConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange, object: audioEngine
        )
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionActive else { return }
            switch type {
            case .began:
                self.speaker.stop()
                self.stopListeningInternal()
            case .ended:
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                guard options.contains(.shouldResume) else { return }
                try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
                self.startListening()
            @unknown default:
                break
            }
        }
    }

    @objc private func handleConfigurationChange(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionActive, self.state == .listening else { return }
            self.stopListeningInternal()
            self.startListening()
        }
    }

    /// `setActive(false)` throws while audio IO is still winding down; the old `try?` swallowed
    /// it and left Cobux holding audio focus after the quiz ended.
    private func deactivateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            DiagnosticLog.log("spoken quiz: audio session deactivate failed (\(error)); retrying")
            DispatchQueue.main.async {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if sessionActive {
            audioEngine.stop()
            speaker.stop()
            setKeepsScreenAwake(false)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Question flow

    private func askCurrentQuestion() {
        guard let question = currentQuestion else {
            state = .done
            end()
            onFinished?()
            return
        }
        state = .speakingQuestion
        lastFeedback = nil
        speak(question.prompt)
    }

    private func speak(_ text: String) {
        // Through the same sentence cutter Voice Mode's stream runs through, so
        // the queue speaks a question or a long explanation one sentence at a
        // time -- pipelined, and each sentence comfortably under Kokoro's 510
        // phoneme-token limit. Spoken whole, a long explanation tripped that
        // limit and flipped mid-quiz to the system voice for one utterance.
        // `sanitize` also strips any markdown a generated explanation carries.
        let chunker = SpeechChunker()
        var sentences = chunker.ingest(text)
        sentences += chunker.finish()
        guard !sentences.isEmpty else {
            // Nothing speakable (markdown-only text). Advance rather than hang.
            Task { @MainActor [weak self] in self?.handleSpeechFinished() }
            return
        }
        speaker.enqueue(sentences)
    }

    /// The one place "an utterance finished" advances the quiz, driven by the
    /// speaker's drain whichever engine spoke.
    @MainActor
    private func handleSpeechFinished() {
        // Never on an ended controller: a neural utterance that outlived End
        // used to land here and either restart the mic or read the next
        // question into a torn-down session.
        guard sessionActive else { return }
        switch state {
        case .speakingQuestion:
            startListening()
        case .speakingFeedback:
            currentIndex += 1
            askCurrentQuestion()
        default:
            break
        }
    }

    // MARK: - Listening / STT (same pattern as VoiceSessionController.startListening)

    private func startListening() {
        // Same guard as `handleSpeechFinished`: no hot mic on a dead controller.
        guard sessionActive else { return }
        stopListeningInternal()
        liveTranscript = ""

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            onError?("Speech recognition isn't available right now.")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        lastTranscript = ""
        lastChangeDate = Date()

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        // A 0 Hz / 0-channel format means the session's input is gone (phone
        // call, Siri, alarm, or a Bluetooth route change yanked it) --
        // `installTap` with such a format raises an UNCATCHABLE NSException
        // (IsFormatSampleRateAndChannelCountValid) and hard-crashes the app.
        // Swift try/catch can't protect the tap, so validate first and take
        // the same graceful failure path as an engine-start error.
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            onError?("The microphone isn't available right now.")
            return
        }
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
                // Recognizer queue here, main-runloop silence timer there:
                // compare and write `lastTranscript`/`lastChangeDate` where
                // they're read, alongside the `liveTranscript` hop.
                DispatchQueue.main.async {
                    guard text != self.lastTranscript else { return }
                    self.lastTranscript = text
                    self.lastChangeDate = Date()
                    self.liveTranscript = text
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
            let wordCount = self.lastTranscript.split(separator: " ").count
            guard elapsed >= self.silenceThreshold, wordCount >= self.minimumAnswerWords else { return }
            let finalText = self.lastTranscript
            self.stopListeningInternal()
            DispatchQueue.main.async { self.gradeAndAdvance(spokenAnswer: finalText) }
        }
        silenceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopListening() {
        stopListeningInternal()
    }

    private func stopListeningInternal() {
        // Was only invalidated by the OUTER `stopListening()` -- but the silence
        // timer's own fire callback calls this inner function directly (line ~207)
        // after grading, never the outer one. Since grading freezes
        // `lastChangeDate`/`lastTranscript`, the timer's guard (`elapsed >=
        // silenceThreshold, wordCount >= minimumAnswerWords`) kept passing on every
        // subsequent 0.3s tick too, re-invoking `gradeAndAdvance` with the same
        // spoken answer repeatedly until something else happened to call the outer
        // function -- duplicate `QuizAnswerRecord` inserts and duplicate FSRS
        // reviews from a single answer. Invalidating here, in the function every
        // stop path actually goes through, closes that regardless of which caller
        // triggered the stop.
        silenceTimer?.invalidate()
        silenceTimer = nil

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

    // MARK: - Grading

    private func gradeAndAdvance(spokenAnswer: String) {
        guard let question = currentQuestion else { return }
        state = .grading

        let isCorrect: Bool
        if let answerVector = EmbeddingService.embed(spokenAnswer),
           let referenceVector = EmbeddingService.embed(question.explanation) {
            let similarity = EmbeddingService.cosineSimilarity(answerVector, referenceVector)
            isCorrect = FreeRecallGrader.isCorrect(similarity: similarity)
        } else {
            isCorrect = false
        }

        if isCorrect { correctCount += 1 }
        onAnswer(question, isCorrect, spokenAnswer)

        lastFeedback = isCorrect ? "Correct." : "Not quite — \(question.explanation)"
        state = .speakingFeedback
        speak(lastFeedback ?? "")
    }
}
