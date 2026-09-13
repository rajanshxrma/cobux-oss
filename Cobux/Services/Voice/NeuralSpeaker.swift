import AVFoundation
import Foundation
import KokoroSwift
import MLX

/// Speaks a sentence with the on-device neural voice, or reports that it can't.
///
/// This exists so the voice controllers keep exactly one speech contract -- hand
/// `SentenceSpeaker` (below) a sentence, get a callback when its audio starts and another when
/// it finishes -- whether the words came from Kokoro or from `AVSpeechSynthesizer`. The
/// controllers' whole state machines hang off "the utterance finished", and having two
/// half-parallel notions of finishing is how those machines would get wedged again.
///
/// Every failure returns false rather than throwing, and the caller falls back to the system
/// voice. Synthesis and the weight load both run on detached tasks so that neither a ~1 s
/// generation nor the 327 MB load ever holds this actor: `stop()` has to land the instant End
/// is tapped, not after the sentence being prepared has finished rendering. The audio session
/// itself is owned by the controller, not here, because the controller is also recording
/// through it.
actor NeuralSpeaker {
    /// The loaded model and its voice embedding. Neither `KokoroTTS` nor `MLXArray` is
    /// Sendable, and both cross into detached tasks; the box is honest about that because the
    /// `synthesis` chain below is what actually guarantees one user at a time.
    private struct LoadedEngine: @unchecked Sendable {
        let engine: KokoroTTS
        let voice: MLXArray
    }

    private var loaded: LoadedEngine?
    /// The in-flight engine build, so a `prewarm()` racing the first sentence loads the
    /// weights once, not twice (each load is 327 MB and a couple of seconds).
    private var preparation: Task<Bool, Never>?
    /// The most recent generation. Each new one chains behind it so `KokoroTTS`, which is not
    /// thread-safe, never runs two generations at once, whatever the callers do.
    private var synthesis: Task<[Float]?, Never>?

    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isAttached = false

    /// One entry per buffer handed to the player and not yet played out, in playback order.
    /// Its head is the buffer audible right now; the next entry's `onStart` fires when the head
    /// finishes, which is exactly the frame the player moves on to it.
    private var scheduled: [ScheduledBuffer] = []
    /// Bumped by `stop()`. A sentence whose synthesis began before a stop is dropped rather
    /// than played after it -- otherwise a tap on End could be followed by a stale sentence.
    private var epoch = 0

    private struct ScheduledBuffer {
        let id: UUID
        let onStart: @Sendable () -> Void
        let onFinish: @Sendable () -> Void
    }

    /// Kokoro emits 24 kHz mono float samples.
    private static let sampleRate = 24_000.0
    /// A touch above Kokoro's default cadence. Its neutral pace reads slightly deliberate for
    /// conversation; 1.05 is brisk without sounding hurried. Tune by ear, not by theory.
    private static let speed: Float = 1.05
    /// -50 dBFS. Anything quieter is the model's silence, not speech.
    private static let silenceFloor: Float = 0.00316
    /// Silence kept after the last audible sample and before the first: the inter-sentence
    /// pause, made consistent. The model's own trailing silence varies from ~0.1 s to well over
    /// half a second, and that variance -- one join tight, the next a dead beat -- is a large
    /// part of what made sentences sound stitched together rather than spoken in sequence.
    /// Both are judgment calls to tune against his ear, not measured constants.
    private static let tailPadSeconds = 0.18
    private static let headPadSeconds = 0.04

    // MARK: - Engine

    /// Loads the weights ahead of the first sentence. Called from the controllers' `start()`,
    /// so the load overlaps the permission prompt and the first listen instead of landing as a
    /// multi-second pause before the first spoken word. Cheap and silent when the model isn't
    /// downloaded yet: the fallback voice needs nothing warmed.
    func prewarm() async {
        _ = await prepare()
    }

    /// Builds the engine on first use. Memoized through `preparation` so concurrent callers
    /// share one load; a failed attempt is not cached, because the download can finish
    /// mid-session and the next sentence should pick the good voice up.
    private func prepare() async -> Bool {
        if loaded != nil { return true }
        if let preparation { return await preparation.value }
        let task = Task<Bool, Never> {
            guard let modelPath = await NeuralVoiceStore.shared.modelPath,
                  await NeuralVoiceStore.shared.isReady,
                  let embedding = await NeuralVoiceStore.shared.loadVoiceEmbedding()
            else { return false }
            // Detached: the load blocks its thread for seconds, and this actor must stay free
            // to take `stop()` meanwhile.
            self.loaded = await Task.detached(priority: .userInitiated) {
                LoadedEngine(engine: KokoroTTS(modelPath: modelPath), voice: embedding)
            }.value
            return true
        }
        preparation = task
        let ready = await task.value
        preparation = nil
        return ready
    }

    /// Synthesizes `text` and schedules it to play straight after whatever is already queued.
    /// Returns false when the neural path isn't usable -- a normal outcome here, not an error
    /// path -- or when a `stop()` landed while this sentence was being synthesized, in which
    /// case it is dropped, not spoken late. `onStart` fires the moment the audio becomes
    /// audible, `onFinish` when it has fully played out; both arrive on an arbitrary thread.
    func speak(_ text: String, onStart: @escaping @Sendable () -> Void, onFinish: @escaping @Sendable () -> Void) async -> Bool {
        let startEpoch = epoch
        guard let buffer = await synthesize(text) else { return false }
        guard epoch == startEpoch else { return false }
        do {
            try enqueue(buffer, onStart: onStart, onFinish: onFinish)
            return true
        } catch {
            DiagnosticLog.log("neural voice: playback failed, using system voice (\(error))")
            return false
        }
    }

    func stop() {
        epoch += 1
        scheduled.removeAll()
        player.stop()
        if audioEngine.isRunning { audioEngine.stop() }
    }

    // MARK: - Synthesis

    /// Kokoro's output for `text`, trimmed, as a buffer ready to schedule -- or nil when the
    /// neural path isn't usable. Generation runs detached and strictly one at a time.
    private func synthesize(_ text: String) async -> AVAudioPCMBuffer? {
        guard await prepare(), let loaded else { return nil }
        let previous = synthesis
        let task = Task.detached(priority: .userInitiated) { () -> [Float]? in
            _ = await previous?.value
            do {
                let (samples, _) = try loaded.engine.generateAudio(voice: loaded.voice, language: .enUS, text: text, speed: Self.speed)
                return samples
            } catch {
                DiagnosticLog.log("neural voice: synthesis failed, using system voice (\(error))")
                return nil
            }
        }
        synthesis = task
        let samples = await task.value
        if synthesis == task { synthesis = nil }
        guard let samples else { return nil }
        return makeBuffer(from: samples)
    }

    /// Kokoro's samples as a 24 kHz mono buffer, with the silence at both ends cut to a fixed
    /// pad. Nil for an empty or entirely silent result.
    private func makeBuffer(from values: [Float]) -> AVAudioPCMBuffer? {
        guard let range = audibleRange(of: values),
              let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(range.count)
        values.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress! + range.lowerBound, count: range.count)
        }
        return buffer
    }

    /// The samples worth playing: from the first above the silence floor less the head pad, to
    /// the last above it plus the tail pad. Only ever trims -- never extends past the data.
    private func audibleRange(of values: [Float]) -> Range<Int>? {
        guard let first = values.firstIndex(where: { abs($0) > Self.silenceFloor }),
              let last = values.lastIndex(where: { abs($0) > Self.silenceFloor })
        else { return nil }
        let headPad = Int(Self.sampleRate * Self.headPadSeconds)
        let tailPad = Int(Self.sampleRate * Self.tailPadSeconds)
        let start = max(0, first - headPad)
        let end = min(values.count, last + 1 + tailPad)
        return start..<end
    }

    // MARK: - Playback

    private func enqueue(_ buffer: AVAudioPCMBuffer, onStart: @escaping @Sendable () -> Void, onFinish: @escaping @Sendable () -> Void) throws {
        if !isAttached {
            audioEngine.attach(player)
            audioEngine.connect(player, to: audioEngine.mainMixerNode, format: buffer.format)
            isAttached = true
        }
        if !audioEngine.isRunning { try audioEngine.start() }
        player.play()

        let id = UUID()
        let startsNow = scheduled.isEmpty
        scheduled.append(ScheduledBuffer(id: id, onStart: onStart, onFinish: onFinish))
        // `at: nil` appends to the player's own schedule, so this buffer begins on the very
        // frame the previous one ends -- gapless by construction, not by racing a completion
        // callback. `.dataPlayedBack` rather than `.dataRendered`: rendered fires when the
        // buffer has been handed to the hardware, early enough that the caller would move on
        // over the tail of this one.
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            Task { await self.bufferFinished(id) }
        }
        if startsNow { onStart() }
    }

    /// Runs once a buffer has fully played out -- or the player was stopped, in which case
    /// `stop()` already emptied `scheduled` and this is a no-op.
    private func bufferFinished(_ id: UUID) {
        guard let index = scheduled.firstIndex(where: { $0.id == id }) else { return }
        let finished = scheduled.remove(at: index)
        finished.onFinish()
        if index == 0, let next = scheduled.first { next.onStart() }
    }
}

/// The one speech queue both voice controllers speak through: sentences in, `onSentenceStarted`
/// as each becomes audible, `onDrained` once the last has finished. Neural voice first, system
/// voice for any sentence the neural path declines, and a strict ordering rule between them --
/// nothing ever plays over anything else, whichever engine is speaking.
///
/// The pipelining lives here. While sentence N plays, N+1 is already being synthesized and
/// scheduled behind it (one-deep lookahead), so the next sentence begins on the frame the
/// current one ends. Before this, N+1's synthesis only began once N had finished playing, and
/// that 0.3-1.2 s of dead air between every pair of sentences was most of what Rajan heard as
/// "AI-like". Captions hang off `onSentenceStarted`, so they land with the sound rather than
/// when the sentence was dequeued.
///
/// Main thread only, like the controllers that own it: every callback it makes is delivered on
/// the main thread, and every mutation of its own state happens there.
final class SentenceSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    /// A sentence's audio has just begun, with the sentence's text -- for captions.
    var onSentenceStarted: ((String) -> Void)?
    /// Everything enqueued has been spoken, or an outside cancel (a phone call, Siri) ended it.
    /// Never fires for `stop()`: whoever stopped it already knows.
    var onDrained: (() -> Void)?

    /// True from the first `enqueue` until the queue drains or `stop()` is called.
    private(set) var isSpeaking = false

    private let neural = NeuralSpeaker()
    private let synthesizer = AVSpeechSynthesizer()

    private var queue: [String] = []
    /// Sentences handed to the neural engine and not yet finished -- synthesizing, scheduled or
    /// audible. Held at `lookahead + 1`: the one playing, and the one being readied behind it.
    private var neuralInFlight = 0
    /// A neural `speak` whose verdict hasn't come back yet. Only one at a time, so sentences
    /// reach the player in the order they were queued -- the actor serializes generation, but
    /// this is what makes the order a property of the design rather than of scheduling luck.
    private var awaitingNeural = false
    /// A sentence the neural engine declined, waiting for the neural audio ahead of it to finish
    /// before the system voice takes it. Speaking it any sooner would talk over that audio.
    private var pendingSystemSentence: String?
    private var systemVoiceSpeaking = false
    /// Bumped by `stop()`. Every callback carries the generation it was issued under and is
    /// dropped when stale, so an interrupted sentence can't finish into the next turn's queue.
    private var generation = 0

    /// How many sentences to ready beyond the one playing. One is enough: synthesis runs at
    /// roughly three times real time, so the next sentence is ready well before the current
    /// one ends, and a deeper lookahead would only make an interruption throw away more work.
    private static let lookahead = 1

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Loads the neural weights now, so they're resident before the first sentence.
    func prewarm() {
        let neural = self.neural
        Task { await neural.prewarm() }
    }

    func enqueue(_ sentences: [String]) {
        guard !sentences.isEmpty else { return }
        queue.append(contentsOf: sentences)
        isSpeaking = true
        pump()
    }

    /// Silences both engines and forgets everything queued. Callbacks already in flight are
    /// dropped by generation; `onDrained` does not fire.
    func stop() {
        generation += 1
        queue.removeAll()
        neuralInFlight = 0
        awaitingNeural = false
        pendingSystemSentence = nil
        systemVoiceSpeaking = false
        isSpeaking = false
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        // The neural path plays through its own AVAudioEngine, so stopping the system
        // synthesizer alone would leave it talking -- the half-teardown that once let voice
        // mode survive being closed.
        let neural = self.neural
        Task { await neural.stop() }
    }

    // MARK: - The pump

    /// Advances the queue as far as the ordering rule allows. Called whenever anything changes:
    /// sentences arrive, a synthesis resolves, a buffer or utterance finishes.
    private func pump() {
        guard !systemVoiceSpeaking else { return }
        if let sentence = pendingSystemSentence {
            // The system voice must wait for the neural audio ahead of it to play out.
            guard neuralInFlight == 0 else { return }
            pendingSystemSentence = nil
            speakWithSystemVoice(sentence)
            return
        }
        guard !queue.isEmpty else {
            if neuralInFlight == 0, isSpeaking {
                isSpeaking = false
                onDrained?()
            }
            return
        }
        guard !awaitingNeural, neuralInFlight <= Self.lookahead else { return }

        let sentence = queue.removeFirst()
        neuralInFlight += 1
        awaitingNeural = true
        let generation = self.generation
        let neural = self.neural
        let started: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.neuralSentenceStarted(sentence, generation: generation) }
        }
        let finished: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.neuralSentenceFinished(generation: generation) }
        }
        Task { [weak self] in
            let spoke = await neural.speak(sentence, onStart: started, onFinish: finished)
            await MainActor.run {
                guard let self, generation == self.generation else { return }
                self.awaitingNeural = false
                if !spoke {
                    // Neural declined (model not downloaded, text over its token limit, engine
                    // failed to start): the system voice takes this one, once nothing neural
                    // is still playing ahead of it.
                    self.neuralInFlight -= 1
                    self.pendingSystemSentence = sentence
                }
                // Scheduled or not, ready the next sentence -- this is the lookahead.
                self.pump()
            }
        }
    }

    private func neuralSentenceStarted(_ sentence: String, generation: Int) {
        guard generation == self.generation else { return }
        onSentenceStarted?(sentence)
    }

    private func neuralSentenceFinished(generation: Int) {
        guard generation == self.generation else { return }
        neuralInFlight = max(0, neuralInFlight - 1)
        pump()
    }

    // MARK: - System voice

    private func speakWithSystemVoice(_ text: String) {
        systemVoiceSpeaking = true
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        // The user's Settings pick, or the best installed voice for their language -- never the
        // bare system default, which is the Samantha-class voice he asked repeatedly to be rid
        // of. Spoken Quiz once ignored the preference and spoke in a different voice from Voice
        // Mode; one queue means one voice.
        utterance.voice = VoicePreference.selectedVoice()
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        synthesizer.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.systemVoiceSpeaking else { return }
            self.onSentenceStarted?(utterance.speechString)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.systemVoiceSpeaking else { return }
            self.systemVoiceSpeaking = false
            self.pump()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Our own `stop()` clears `systemVoiceSpeaking` before cancelling, so anything arriving
        // here still marked speaking was cancelled from outside -- a phone call, Siri, a route
        // change. Left alone, the sentences behind it sat in the queue with nothing to ever
        // speak or drain them and the session showed a live waveform forever. Drain, so the
        // owner's state machine moves on exactly as after a normal finish.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.systemVoiceSpeaking else { return }
            self.systemVoiceSpeaking = false
            self.queue.removeAll()
            self.pendingSystemSentence = nil
            self.isSpeaking = false
            self.onDrained?()
        }
    }
}
