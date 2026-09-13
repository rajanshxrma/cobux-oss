import Foundation

/// Words and names that must never appear on an ambient surface.
///
/// This exists because of a problem Rajan named directly: *"sometimes if a
/// person goes through their ex, or memories of their ex which they've written
/// about in their journals, they don't wanna see that thing again — so that
/// just cannot show up."*
///
/// **The app deliberately does not try to detect that itself**, for two reasons.
/// The first is that deciding what wounds him is characterization wearing a
/// different hat, and this app does not characterize him. The second is harder:
/// it is impossible in principle. The most painful material about a person is
/// often the happiest — "the best day we ever had" — so no sentiment model can
/// find it, and the name that matters is knowable only to him. Pain is a
/// relation between him now and what he wrote then, and only he holds it.
///
/// So he holds it. One list, his words, no inference.
///
/// Enforced at a single choke point in `JournalHighlightSelector`'s eligibility
/// path rather than at each surface, so the journal card, Ebb, Flow's echo, and
/// anything added later inherit it without having to remember — the same
/// argument `FlowQueueBuilder` makes for applying `excludedBookIDs` once.
///
/// The honest limit, stated plainly: a passage can still appear ONCE before he
/// quiets the word. What this guarantees is never twice and never anything he
/// has quieted — not "never once". Claiming more would require the inference
/// this refuses to make.
enum JournalQuietWords {
    private static let key = "cobux.journal.quietWords"

    /// Injectable so tests never touch the real list.
    ///
    /// Not a nicety: `ThresholdDeckBuilderTests` clears every quiet word in
    /// `setUp` and `tearDown`, so running the suite against
    /// `UserDefaults.standard` would silently erase the actual list of names he
    /// asked never to see again -- destroying user data to test the feature
    /// whose entire purpose is protecting it.
    nonisolated(unsafe) static var store: UserDefaults = .standard

    /// Called after every change to the list. The People index registers
    /// here (`JournalPeopleIndexer`) so quieting a name removes its page on
    /// the next pass and un-quieting lets it return -- this file stays pure
    /// Foundation (it travels to the test harness), so it cannot name the
    /// indexer itself. Nil until something registers; tests leave it nil.
    nonisolated(unsafe) static var onChange: (@Sendable () -> Void)?

    static func all() -> [String] {
        (store.stringArray(forKey: key) ?? [])
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func add(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var stored = store.stringArray(forKey: key) ?? []
        guard !stored.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }
        stored.append(trimmed)
        store.set(stored, forKey: key)
        onChange?()
    }

    static func remove(_ word: String) {
        let stored = (store.stringArray(forKey: key) ?? [])
            .filter { $0.caseInsensitiveCompare(word) != .orderedSame }
        store.set(stored, forKey: key)
        onChange?()
    }

    /// Whether this text may be shown on an ambient surface at all.
    ///
    /// Checked against the WHOLE entry, not the chosen passage: a quieted name
    /// appearing anywhere in an entry means the entry is about that, even if the
    /// sentence the selector picked never says so.
    static func isQuiet(_ text: String) -> Bool {
        let words = store.stringArray(forKey: key) ?? []
        guard !words.isEmpty else { return false }
        let lowered = text.lowercased()
        return words.contains { lowered.contains($0.lowercased()) }
    }
}
