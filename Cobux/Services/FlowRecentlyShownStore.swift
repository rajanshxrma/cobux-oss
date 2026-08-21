import Foundation

/// Tracks which highlights Flow has actually settled on recently, across
/// real app sessions -- not just within one Flow session, where a fresh
/// random shuffle already exists (`FlowView.seedBase`). Built from a real,
/// live report: highlights still felt repetitive day to day even with that
/// per-session shuffle, because a small library's whole pool reshuffled is
/// still the same small pool -- the first dozen cards of a fresh session
/// land on largely the same highlights a fresh random draw would always
/// favor early, purely by chance.
///
/// Deliberately a soft bias, not a hard exclusion: `FlowQueueBuilder` uses
/// this to shuffle NOT-recently-shown highlights to the front of the pool
/// and recently-shown ones to the back, rather than removing them outright.
/// A library small enough that everything in it counts as "recently shown"
/// still gets a full feed, just in its natural (now less-favored) order --
/// same graceful-degradation shape as `WidgetHighlightPool`'s own exclusion
/// preference, never a hard cutoff that could show nothing.
enum FlowRecentlyShownStore {
    private static let defaults = UserDefaults.standard
    private static let key = "cobux.flow.recentlyShownHighlights"
    /// Long enough that a daily user genuinely sees new material float to
    /// the front for a few days running, short enough that a highlight
    /// isn't punished forever for having been shown once.
    private static let window: TimeInterval = 3 * 24 * 60 * 60
    /// Bounds the persisted payload regardless of window -- a heavy user
    /// settling hundreds of cards a day shouldn't grow this unboundedly.
    private static let maxEntries = 300

    /// Stored as raw `TimeInterval` (`Date.timeIntervalSince1970`), not
    /// `Date` itself -- an unambiguous property-list-safe scalar, rather
    /// than relying on `NSDate` bridging through `UserDefaults`'s `Any`
    /// dictionary API to round-trip cleanly.
    private static func load() -> [String: TimeInterval] {
        guard let raw = defaults.dictionary(forKey: key) as? [String: TimeInterval] else { return [:] }
        return raw
    }

    private static func save(_ entries: [String: TimeInterval]) {
        defaults.set(entries, forKey: key)
    }

    /// Highlight IDs shown within the current window -- everything else is
    /// implicitly "fresh" as far as this store is concerned.
    static func recentIDs() -> Set<UUID> {
        let cutoff = Date.now.addingTimeInterval(-window).timeIntervalSince1970
        return Set(load().compactMap { key, timestamp in
            guard timestamp >= cutoff, let id = UUID(uuidString: key) else { return nil }
            return id
        })
    }

    /// Called once a highlight card genuinely settles on screen
    /// (`FlowView`'s own `settledItemIDs` insertion), not merely built into
    /// a batch -- a card that scrolled past unseen shouldn't count as
    /// "shown" any more than one that was never queued.
    static func recordShown(_ id: UUID) {
        var entries = load()
        entries[id.uuidString] = Date.now.timeIntervalSince1970

        if entries.count > maxEntries {
            let sortedByAge = entries.sorted { $0.value < $1.value }
            let overflow = entries.count - maxEntries
            for (staleKey, _) in sortedByAge.prefix(overflow) {
                entries.removeValue(forKey: staleKey)
            }
        }
        save(entries)
    }
}
