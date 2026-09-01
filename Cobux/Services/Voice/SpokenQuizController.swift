import Foundation
import Speech
import AVFoundation
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
final class SpokenQuizController: NSObject, AVSpeechSynthesizerDelegate {
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
    private let synthesizer = AVSpeechSynthesizer()

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
        synthesizer.delegate = self
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
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            sessionActive = true
            registerAudioObservers()
        } catch {
            onError?("Couldn't set up the audio session.")
            return
        }
        askCurrentQuestion()
    }

    func end() {
        stopListening()
        synthesizer.stopSpeaking(at: .immediate)
        silenceTimer?.invalidate()
        silenceTimer = nil
        NotificationCenter.default.removeObserver(self)
        guard sessionActive else { return }
        deactivateSession()
        sessionActive = false
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
                self.synthesizer.stopSpeaking(at: .immediate)
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
            synthesizer.stopSpeaking(at: .immediate)
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
        let utterance = AVSpeechUtterance(string: text)
        // `VoicePreference.selectedVoice()`, exactly like `VoiceSessionController`
        // -- NOT `AVSpeechSynthesisVoice(language:)`, which is the plain system
        // default (the old robotic Samantha-class voice) and ignored both the
        // user's explicit Settings pick AND the automatic
        // best-quality-available fallback. Voice Mode has always honored the
        // preference; Spoken Quiz silently didn't, so the same app spoke in two
        // different voices depending on which screen you were on.
        utterance.voice = VoicePreference.selectedVoice()
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        synthesizer.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch self.state {
            case .speakingQuestion:
                self.startListening()
            case .speakingFeedback:
                self.currentIndex += 1
                self.askCurrentQuestion()
            default:
                break
            }
        }
    }

    // MARK: - Listening / STT (same pattern as VoiceSessionController.startListening)

    private func startListening() {
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
