import Foundation
import MLX
import Observation

/// Fetches and caches the on-device neural TTS model, so Cobux can speak in a good voice
/// without asking the user to do anything.
///
/// Rajan, twice: *"the voice is still ugly samantha"* → *"why cant we have the nice voice by
/// defalut?"*
///
/// The honest answer was that through Apple's synthesizer we can't. iOS ships only compact
/// system voices; the good ones are 100-500 MB each across every language, so they're a manual
/// download buried four levels deep in Accessibility settings, and there is no API for an app
/// to trigger one, or even to see that one exists. Siri's voices aren't in that system at all.
/// So the only route to a good default is to bring our own synthesizer.
///
/// The model is ~327 MB, which is far too much to bundle into the app, so it's fetched once in
/// the background and kept in Application Support forever after. Until it lands, speech falls
/// back to `AVSpeechSynthesizer` — the voice is worse for one session, never absent.
///
/// Everything here is best-effort by construction: no network, a failed download, a corrupt
/// file, or a device low on space all end in the same place, which is the system voice and a
/// line in the diagnostic log. Voice mode must never fail to speak because this failed.
@MainActor
@Observable
final class NeuralVoiceStore {
    static let shared = NeuralVoiceStore()

    enum State: Equatable {
        case notStarted
        case downloading(fractionCompleted: Double)
        case ready
        /// Terminal for this launch. Retried next launch, not in a loop -- a device that's
        /// offline or out of space shouldn't spend its battery rediscovering that.
        case unavailable
    }

    private(set) var state: State = .notStarted

    /// The one calm line for a phone that has no room. Non-nil only while
    /// `state` is `.unavailable` because of free space; cleared the moment a
    /// later `prepareIfNeeded` finds the room (or the model). Voice Mode's
    /// status line (`VoiceModeView.voiceStatus`) is the place this belongs,
    /// in the `.unavailable` arm, ahead of the voice-upgrade recipe.
    private(set) var unavailableReason: String?

    /// What the download needs free before it starts: the 327 MB model, the
    /// voice, and the headroom iOS itself needs to keep operating -- the
    /// concrete case is a tester's phone at 2.18 GB free of 119 GB, where a
    /// 327 MB download that then leaves the system at its own floor is worse
    /// than no download. Nothing is ever deleted to make room; the download
    /// simply waits for a launch that has it.
    private static let requiredFreeBytes: Int64 = 1_500_000_000
    /// The line, written once so the log and the screen say the same thing.
    private static let lowDiskLine = "Cobux's natural voice needs about 1.5 GB free to download. It will try again when there is room; until then this uses the basic system voice."

    /// `prince-canuma/Kokoro-82M` is the MLX conversion the Swift port is built against, so
    /// this is the same weights file `KokoroTestApp` loads, not a lookalike.
    private static let modelURL = URL(string: "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main/kokoro-v1_0.safetensors")!
    /// One voice, not all 108. `af_heart` is the reference American English voice and the
    /// library's own starter; 522 KB against the model's 327 MB.
    private static let voiceURL = URL(string: "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main/voices/af_heart.safetensors")!

    /// Well under the real 327 MB, but enough to catch a truncated or error-page download
    /// being cached as if it were a model.
    private static let minimumPlausibleModelBytes = 200_000_000

    private var directory: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let dir = support.appendingPathComponent("NeuralVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var modelPath: URL? { directory?.appendingPathComponent("kokoro-v1_0.safetensors") }
    var voicePath: URL? { directory?.appendingPathComponent("af_heart.safetensors") }

    /// True once both files are present and the model is a plausible size.
    var isReady: Bool {
        guard let modelPath, let voicePath,
              FileManager.default.fileExists(atPath: voicePath.path),
              let size = try? FileManager.default.attributesOfItem(atPath: modelPath.path)[.size] as? Int
        else { return false }
        return size >= Self.minimumPlausibleModelBytes
    }

    /// Loads the voice embedding the synthesizer needs. Returns nil rather than throwing --
    /// every caller's fallback is the system voice.
    func loadVoiceEmbedding() -> MLXArray? {
        guard let voicePath, let arrays = try? MLX.loadArrays(url: voicePath) else { return nil }
        return arrays.values.first
    }

    /// Call at launch, off the critical path. Cheap and idempotent when already cached.
    ///
    /// Retries from `.unavailable`, not just `.notStarted`. The download is
    /// Wi-Fi-only by design, so a user who first opened Cobux on cellular --
    /// or with a flaky connection -- landed in `.unavailable`, which used to be
    /// terminal for the whole app launch. They would keep hearing the robotic
    /// system voice on Wi-Fi, forever, until they happened to fully relaunch.
    /// "why cant we have the nice voice by defalut?" is partly this.
    func prepareIfNeeded() async {
        switch state {
        case .notStarted, .unavailable:
            break
        case .downloading, .ready:
            return
        }
        if isReady {
            state = .ready
            unavailableReason = nil
            return
        }
        // Room first. `freeDiskBytes()` is a `statfs`, so it runs detached
        // rather than on this actor; an unanswerable volume (`nil`) counts
        // as room, so a query failure can never disable the voice.
        // Claim the slot BEFORE the await: the launch chain and the scene
        // foreground both call this, and two callers inside the window would
        // start the 327 MB download twice.
        state = .downloading(fractionCompleted: 0)
        let free = await Task.detached(priority: .utility) { DeviceClass.freeDiskBytes() }.value
        if let free, free < Self.requiredFreeBytes {
            if unavailableReason == nil {
                DiagnosticLog.log("neural voice: download deferred, \(free / 1_000_000) MB free (needs \(Self.requiredFreeBytes / 1_000_000) MB)")
            }
            unavailableReason = Self.lowDiskLine
            state = .unavailable
            return
        }
        unavailableReason = nil
        // Deliberately not on cellular: this is a 327 MB convenience download, and silently
        // spending someone's data plan on it would be a hostile default.
        state = .downloading(fractionCompleted: 0)
        do {
            try await download(Self.voiceURL, to: voicePath)
            try await download(Self.modelURL, to: modelPath)
            guard isReady else { throw CocoaError(.fileReadCorruptFile) }
            state = .ready
            DiagnosticLog.log("neural voice: model ready")
        } catch {
            DiagnosticLog.log("neural voice: unavailable (\(error.localizedDescription))")
            state = .unavailable
        }
    }

    private func download(_ remote: URL, to destination: URL?) async throws {
        guard let destination else { throw CocoaError(.fileNoSuchFile) }
        if FileManager.default.fileExists(atPath: destination.path),
           let size = try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int,
           size > 0, remote != Self.modelURL || size >= Self.minimumPlausibleModelBytes {
            return
        }
        var request = URLRequest(url: remote)
        request.allowsCellularAccess = false
        request.timeoutInterval = 120
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw URLError(.badServerResponse)
        }
        // Replace rather than move-if-absent: a previous truncated attempt must not survive.
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        // The model is regenerable from the network and must never cost the user iCloud
        // quota or be culled mid-use by the backup system.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = destination
        try? mutable.setResourceValues(values)
    }
}
