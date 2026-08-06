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
        guard sessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        sessionActive = false
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
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
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
