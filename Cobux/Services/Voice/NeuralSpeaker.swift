import AVFoundation
import Foundation
import KokoroSwift
import MLX

/// Speaks a sentence with the on-device neural voice, or reports that it can't.
///
/// This exists so `VoiceSessionController` keeps exactly one speech contract — hand it a
/// sentence, get a callback when the audio finishes — whether the words came from Kokoro or
/// from `AVSpeechSynthesizer`. The controller's whole state machine hangs off "the utterance
/// finished" (`handleSpeechQueueDrained`), and having two half-parallel notions of finishing
/// is how that machine would get wedged again.
///
/// Every failure returns false rather than throwing, and the caller falls back to the system
/// voice. Synthesis running on a background actor keeps a ~300 ms generation off the main
/// thread; the audio session itself is owned by the controller, not here, because the
/// controller is also recording through it.
actor NeuralSpeaker {
    private var engine: KokoroTTS?
    private var voice: MLXArray?

    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isAttached = false

    /// Kokoro emits 24 kHz mono float samples.
    private static let sampleRate = 24_000.0

    /// Builds the engine on first use. Loading 327 MB of weights takes a beat, so this is
    /// deliberately lazy rather than done at launch -- nobody should pay for it who never
    /// opens voice mode.
    private func prepare() async -> Bool {
        if engine != nil, voice != nil { return true }
        guard let modelPath = await NeuralVoiceStore.shared.modelPath,
              await NeuralVoiceStore.shared.isReady,
              let embedding = await NeuralVoiceStore.shared.loadVoiceEmbedding()
        else { return false }
        engine = KokoroTTS(modelPath: modelPath)
        voice = embedding
        return engine != nil
    }

    /// Synthesizes and plays `text`. Returns false if the neural path isn't usable, in which
    /// case the caller must speak it with `AVSpeechSynthesizer` instead -- returning false is
    /// a normal outcome here, not an error path.
    func speak(_ text: String, onFinish: @escaping @Sendable () -> Void) async -> Bool {
        guard await prepare(), let engine, let voice else { return false }
        do {
            let (samples, _) = try engine.generateAudio(voice: voice, language: .enUS, text: text)
            guard let buffer = makeBuffer(from: samples) else { return false }
            try play(buffer, onFinish: onFinish)
            return true
        } catch {
            DiagnosticLog.log("neural voice: synthesis failed, using system voice (\(error))")
            return false
        }
    }

    func stop() {
        player.stop()
        if audioEngine.isRunning { audioEngine.stop() }
    }

    private func makeBuffer(from values: [Float]) -> AVAudioPCMBuffer? {
        guard !values.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(values.count)
        values.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: values.count)
        }
        return buffer
    }

    private func play(_ buffer: AVAudioPCMBuffer, onFinish: @escaping @Sendable () -> Void) throws {
        if !isAttached {
            audioEngine.attach(player)
            audioEngine.connect(player, to: audioEngine.mainMixerNode, format: buffer.format)
            isAttached = true
        }
        if !audioEngine.isRunning { try audioEngine.start() }
        player.play()
        // `.dataPlayedBack` rather than `.dataRendered`: rendered fires when the buffer has
        // been handed to the hardware, which is early enough that the next sentence would
        // start over the tail of this one.
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
            onFinish()
        }
    }
}
