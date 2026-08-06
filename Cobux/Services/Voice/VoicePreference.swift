import AVFoundation

/// Picks and remembers which system `AVSpeechSynthesisVoice` Voice Mode speaks with. Per
/// Fable's voice architecture ruling: deliberately selected system voice, no third-party TTS in
/// phase one -- rank available voices by quality (`.premium` > `.enhanced` > `.default`) and
/// nudge users toward downloading a better one if only `.default` is available for their
/// language, rather than silently always using whatever `AVSpeechUtterance` defaults to.
enum VoicePreference {
    private static let defaults = UserDefaults.standard
    private static let selectedIdentifierKey = "cobux.voice.selectedIdentifier"

    /// Every system voice for the given language, best quality first. `AVSpeechSynthesisVoice
    /// .quality` only distinguishes `.default`/`.enhanced`/`.premium` -- there's no public API
    /// for finer ranking, so ties (e.g. two `.enhanced` voices) keep their system-reported order.
    static func availableVoices(languagePrefix: String = Locale.current.language.languageCode?.identifier ?? "en") -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(languagePrefix) }
            .sorted { $0.quality.rank > $1.quality.rank }
    }

    /// The user's explicit pick, if they made one and it's still installed -- otherwise the
    /// best available voice for their language, so a voice is always usable without requiring a
    /// Settings visit first.
    static func selectedVoice() -> AVSpeechSynthesisVoice? {
        if let identifier = defaults.string(forKey: selectedIdentifierKey),
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        return availableVoices().first
    }

    static var selectedVoiceIdentifier: String? {
        get { defaults.string(forKey: selectedIdentifierKey) }
        set { defaults.set(newValue, forKey: selectedIdentifierKey) }
    }

    /// True when every available voice for the user's language is `.default` quality -- the
    /// point where Settings should nudge them to download an Enhanced/Premium voice, since
    /// there's nothing better to pick from yet.
    static var onlyDefaultQualityVoicesAvailable: Bool {
        let voices = availableVoices()
        return !voices.isEmpty && voices.allSatisfy { $0.quality == .default }
    }
}

private extension AVSpeechSynthesisVoiceQuality {
    var rank: Int {
        switch self {
        case .premium: return 2
        case .enhanced: return 1
        case .default: return 0
        @unknown default: return 0
        }
    }

    var label: String {
        switch self {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        case .default: return "Default"
        @unknown default: return "Default"
        }
    }
}

extension AVSpeechSynthesisVoice {
    /// Display label combining the voice's name and quality tier, for the Settings picker.
    var cobuxDisplayLabel: String {
        "\(name) (\(quality.label))"
    }
}
