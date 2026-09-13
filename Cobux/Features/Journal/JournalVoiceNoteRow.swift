import AVFoundation
import SwiftUI

/// Plays back a journal voice note.
///
/// Voice notes have been recordable, persisted, backed up and restored for a
/// while — but nothing in the app ever played one, or even showed that one
/// existed. `JournalAttachmentStore.isVoiceNote(id:)` was written for the view
/// layer and then called from nowhere, so every audio attachment fell through
/// the photo path and rendered as a blank grey tile in the journal list, the
/// entry detail hero, and the composer strip. Recording into a void is worse
/// than not offering it, which is why this is a correctness fix rather than a
/// nicety.
struct JournalVoiceNoteRow: View {
    /// Where the audio is. A SAVED note is found by its attachment id (the
    /// store resolves the file); a note still staged in the composer has no
    /// row yet and is addressed by the file the recorder wrote, which is the
    /// same bytes `JournalAttachmentStore.audioURL(for:)` will move on save.
    /// One player for both, so what the composer confirms is what the entry
    /// later plays.
    enum Source: Hashable {
        case attachment(UUID)
        case file(URL)
    }

    let source: Source
    var accent: Color = .cobuxAccent
    /// The small label above the scrubber. "Voice note" for a saved one; the
    /// composer passes "Voice note · ready to save" for a staged one.
    var kicker: String = "Voice note"

    init(attachmentID: UUID, accent: Color = .cobuxAccent, kicker: String = "Voice note") {
        self.source = .attachment(attachmentID)
        self.accent = accent
        self.kicker = kicker
    }

    init(fileURL: URL, accent: Color = .cobuxAccent, kicker: String = "Voice note") {
        self.source = .file(fileURL)
        self.accent = accent
        self.kicker = kicker
    }

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var duration: TimeInterval = 0
    @State private var progress: Double = 0
    /// Drives the scrubber while playing. AVAudioPlayer has no progress
    /// callback, so the alternative is polling; this ticks only while audio is
    /// actually playing and is torn down on pause.
    @State private var ticker: Timer?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(accent)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause voice note" : "Play voice note")

            VStack(alignment: .leading, spacing: 6) {
                Label(kicker, systemImage: "waveform")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ProgressView(value: progress)
                    .tint(accent)
            }

            Text(timeLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: source) { load() }
        .onDisappear { stop() }
        .accessibilityElement(children: .combine)
    }

    private var timeLabel: String {
        let remaining = max(0, duration - (player?.currentTime ?? 0))
        let shown = isPlaying ? remaining : duration
        let mins = Int(shown) / 60
        let secs = Int(shown) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private var fileURL: URL? {
        switch source {
        case .attachment(let id): return JournalAttachmentStore.existingFileURL(for: id)
        case .file(let url): return url
        }
    }

    private func load() {
        guard let url = fileURL,
              url.pathExtension == "m4a",
              let made = try? AVAudioPlayer(contentsOf: url) else { return }
        made.prepareToPlay()
        player = made
        duration = made.duration
    }

    private func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            stopTicking()
            isPlaying = false
            return
        }
        // Playback has to share the session with the rest of the app rather
        // than seizing it — a journal voice note should not kill the user's
        // music any longer than it is actually speaking.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        startTicking()
    }

    private func startTicking() {
        stopTicking()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                guard let player else { return }
                progress = duration > 0 ? player.currentTime / duration : 0
                if !player.isPlaying {
                    // Finished on its own: rewind so a second tap replays
                    // rather than sitting silently at the end.
                    isPlaying = false
                    player.currentTime = 0
                    progress = 0
                    stopTicking()
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
            }
        }
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func stop() {
        player?.pause()
        stopTicking()
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
