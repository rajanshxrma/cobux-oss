import AVFoundation
import Foundation
import Observation

/// Records a voice note alongside a journal entry.
///
/// Rajan's ask, after using the dictation button once: "keyboard has dictate
/// feature already in iPhone, a special one that i see now is redundant remove
/// that — instead of that have voice recording feature."
///
/// Dictation and recording are genuinely different things and he was right that
/// only one of them was worth having here. Dictation turns speech into text the
/// keyboard already produces. A recording keeps the thing text cannot: how he
/// actually sounded saying it. That belongs in a journal in a way a transcript
/// does not.
///
/// Stored beside the photo attachments in the same directory, so it inherits the
/// automatic backup/restore path already covering journal media.
@MainActor
@Observable
final class JournalVoiceRecorder: NSObject {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var permissionDenied = false

    /// Lets the view dismiss the permission alert. Without this the flag stays
    /// set for the life of the recorder and the alert re-presents forever.
    func clearPermissionDenied() { permissionDenied = false }

    private var recorder: AVAudioRecorder?
    /// The id the current recording is being written under.
    ///
    /// Kept so `stop()` can discard a too-short file through
    /// `JournalAttachmentStore` rather than reaching into the attachment
    /// directory with `FileManager` behind the store's back. The store now
    /// remembers which extension an id resolved to, and the invariant that
    /// keeps that memory honest -- every write, move and delete in that
    /// directory goes through the store -- is worth holding without exceptions
    /// rather than arguing that this particular one is safe.
    private var recordingID: UUID?
    private var timer: Timer?
    private var sessionActive = false

    static func url(for id: UUID) -> URL {
        JournalAttachmentStore.audioURL(for: id)
    }

    func start(id: UUID) async {
        guard !isRecording else { return }
        let granted = await withCheckedContinuation { c in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
        guard granted else {
            permissionDenied = true
            return
        }

        // Build 57, Rajan, a fresh compose sheet: tapping Voice note went
        // straight to "The microphone wasn't available just now." This block
        // was `.record` with `.spokenAudio` -- a PLAYBACK mode; the two
        // recorders in this app that work (`VoiceSessionController`,
        // `SpokenQuizController`) both configure the session exactly as below,
        // so the journal now borrows the proven shape rather than its own.
        // And every failure used to be `catch { return }`: swallowed, no log,
        // so his report arrived with a screenshot and no evidence. Each path
        // out of here now writes one `DiagnosticLog` line with the NSError
        // domain/code, so the next report carries the number.
        guard activateSession() else { return }

        // AAC at 22.05 kHz mono: speech-quality, roughly 1 MB per two minutes,
        // so a habit of voice notes doesn't quietly consume the device.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let url = Self.url(for: id)
        // `JournalAttachmentStore.directory` is a lazy static that creates the
        // folder on first touch, and `audioURL(for:)` touches it -- so this is
        // belt to that braces. A recorder handed a URL whose parent does not
        // exist fails at `record()`, silently, and this is the one write into
        // that directory the store does not perform itself.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let rec: AVAudioRecorder
        do {
            rec = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            Self.log("recorder init failed", error)
            deactivate()
            return
        }
        // `record()` returns false when the file cannot be created or the
        // session is not actually recording-capable. It was never checked, so
        // the chip could have shown a timer over a recorder that was not
        // running. That path now ends in the same alert as the others.
        guard rec.record() else {
            DiagnosticLog.log("journal voice: record() returned false at \(url.lastPathComponent)")
            deactivate()
            return
        }
        recorder = rec
        recordingID = id
        isRecording = true
        elapsed = 0
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = self?.recorder?.currentTime ?? 0 }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    /// Ends the recording and reports whether a usable file exists — the caller
    /// only creates the attachment row if it does, so a zero-length recording
    /// never leaves an unplayable attachment behind.
    @discardableResult
    func stop() -> Bool {
        timer?.invalidate(); timer = nil
        guard let rec = recorder else { return false }
        let url = rec.url
        let id = recordingID
        rec.stop()
        recorder = nil
        recordingID = nil
        isRecording = false
        deactivate()
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        guard size > 1_000 else {
            if let id {
                JournalAttachmentStore.deleteAudio(id: id)
            } else {
                // Only reachable if `start` never set the id, which cannot
                // happen while `recorder` is non-nil -- kept so a future change
                // to that pairing degrades to the old behaviour instead of
                // leaving the file behind.
                try? FileManager.default.removeItem(at: url)
            }
            return false
        }
        return true
    }

    func cancel(id: UUID) {
        timer?.invalidate(); timer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        deactivate()
        // Through the store: it is the only thing that knows an id's file has
        // gone, and it now caches that answer for the journal feed.
        JournalAttachmentStore.deleteAudio(id: id)
    }

    /// Configures and activates the shared session for recording; false means
    /// the caller shows the alert. One retry, and the reason it exists: the
    /// app's own voice-note player leaves a `.playback` session active when a
    /// note was just listened to, and a category change over a live session
    /// from another mode is the plausible collision here. Deactivating first
    /// (`notifyOthersOnDeactivation`, the same courtesy every other session
    /// end in this app pays) and trying once more costs nothing when the first
    /// attempt succeeds, which is the common case.
    private func activateSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        for attempt in 1...2 {
            do {
                // Mirrors `VoiceSessionController.start()` and
                // `SpokenQuizController.start()` verbatim -- the configuration
                // that records on his phone every day. `.allowBluetoothA2DP`
                // over HFP for the same reason they give: AirPods should not
                // narrow the mic to telephony bandwidth.
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.duckOthers, .defaultToSpeaker, .allowBluetoothA2DP])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                sessionActive = true
                if attempt == 2 { DiagnosticLog.log("journal voice: session ok on retry") }
                return true
            } catch {
                Self.log("session setup failed (attempt \(attempt))", error)
                guard attempt == 1 else { return false }
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
        return false
    }

    /// One line per failure, domain and code included -- an `AVAudioSession`
    /// error is an OSStatus and its number is the whole diagnosis.
    private static func log(_ what: String, _ error: Error) {
        let ns = error as NSError
        DiagnosticLog.log("journal voice: \(what) -- \(ns.domain) \(ns.code): \(ns.localizedDescription)")
    }

    private func deactivate() {
        guard sessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        sessionActive = false
    }

    // No deinit: `timer` is main-actor isolated and deinit is not, so touching it
    // there does not compile under strict concurrency. Every path that ends a
    // recording -- stop() and cancel() -- already invalidates it, and both are
    // called by the compose view's own teardown.
}
