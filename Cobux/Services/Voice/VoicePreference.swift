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

    /// True when the voice Voice Mode will actually speak with is `.default` quality -- the
    /// point where the user should be nudged to download an Enhanced/Premium voice.
    ///
    /// This used to ask whether *every* installed en-* voice was default quality, which is a
    /// different question and quietly false in a common case: one enhanced en-GB voice
    /// downloaded for something unrelated flipped it, while `selectedVoice()` went on speaking
    /// with a default-quality en-US one. Ask about the voice being used, not the inventory.
    /// Drops a stored pick that pins the user to a `.default`-quality voice once a better one
    /// has been installed. Without this, anyone who ever touched the voice picker before
    /// downloading an enhanced voice stayed on the basic voice permanently, with the app
    /// giving no sign that its own "switches automatically" promise had been disabled.
    /// Only ever releases a pin -- a deliberate pick of a good voice is left alone.
    static func clearStalePinIfBetterVoiceAvailable() {
        guard let identifier = defaults.string(forKey: selectedIdentifierKey),
              let pinned = AVSpeechSynthesisVoice(identifier: identifier),
              pinned.quality == .default,
              availableVoices().contains(where: { $0.quality != .default })
        else { return }
        defaults.removeObject(forKey: selectedIdentifierKey)
    }

    static var usingDefaultQualityVoice: Bool {
        selectedVoice()?.quality == .default
    }

    /// The exact steps, naming one specific voice.
    ///
    /// Apple gives third-party apps no way to download, trigger, or even enumerate voices that
    /// aren't installed, and no public deep link into Accessibility settings (`App-Prefs:` roots
    /// are private API). So the recipe is all we can offer -- which makes it worth writing
    /// properly: name a single voice rather than "an Enhanced or Premium one", since a user
    /// standing in a list of thirty voices with no recommendation just leaves.
    ///
    /// "Switches automatically" is literally true: `selectedVoice()` falls back to the
    /// best-quality installed voice, so downloading one is the entire action.
    static let upgradeRecipe = """
        Cobux is using iOS's basic system voice. For a much better one — free, one-time, and it \
        works offline afterwards: open Settings → Accessibility → Spoken Content → Voices → \
        English, and download Ava (Premium). Cobux switches to it automatically.
        """
}

private extension AVSpeechSynthesisVoiceQuality {
    var rank: Int {
        switch self {
        case .premium: return 2
        case .enhanced: return 1
        default: return 0
        }
    }
}

extension AVSpeechSynthesisVoice {
    /// Name plus quality tier, for the picker in Settings -- the tier is the only signal a
    /// user has for why one voice sounds better than another.
    var cobuxDisplayLabel: String {
        let tier: String
        switch quality {
        case .premium: tier = "Premium"
        case .enhanced: tier = "Enhanced"
        default: tier = "Default"
        }
        return "\(name) (\(tier))"
    }
}
