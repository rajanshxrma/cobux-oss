import Foundation

/// The read-only glance data pushed from the phone to `CobuxWatch` via
/// `WCSession.updateApplicationContext`. Per Fable's Watch companion ruling: the watch has no
/// `ModelContainer`/`CobuxCore` at all — this schema (assembled phone-side by
/// `WatchSyncService`, consumed watch-side by the receiver in `CobuxWatch/`) is the entire
/// data surface the watch ever sees. Shared between `Cobux`, `CobuxWatch`, and
/// `CobuxWatchWidgets` — only the schema is shared, never the transport logic itself.
public struct WatchPayload: Codable, Sendable {
    public var streakCount: Int
    public var streakLastActiveDate: Date?
    public var dueCount: Int
    /// Next due timestamps (capped, see `maxUpcomingDueDates`) — not just today's snapshot
    /// count. The watch widget provider computes `count(due <= entryDate)` per timeline entry
    /// from this array, so the due count rises correctly across the day while the phone
    /// sleeps, instead of freezing at whatever it was at the last sync.
    public var upcomingDueDates: [Date]
    public var quoteText: String?
    public var quoteBook: String?
    public var quoteCoverColorHex: String?
    public var generatedAt: Date

    public static let maxUpcomingDueDates = 100
    /// `updateApplicationContext`'s real size ceiling isn't published by Apple — this payload
    /// stays well under a few KB even at the cap, treated as safely within bounds rather than
    /// a measured limit (Fable's own named uncertainty on this ruling).
    public static let maxQuoteTextLength = 300

    public init(
        streakCount: Int,
        streakLastActiveDate: Date?,
        dueCount: Int,
        upcomingDueDates: [Date],
        quoteText: String?,
        quoteBook: String?,
        quoteCoverColorHex: String?,
        generatedAt: Date
    ) {
        self.streakCount = streakCount
        self.streakLastActiveDate = streakLastActiveDate
        self.dueCount = dueCount
        self.upcomingDueDates = Array(upcomingDueDates.prefix(Self.maxUpcomingDueDates))
        self.quoteText = quoteText.map { String($0.prefix(Self.maxQuoteTextLength)) }
        self.quoteBook = quoteBook
        self.quoteCoverColorHex = quoteCoverColorHex
        self.generatedAt = generatedAt
    }
}

/// Keys used in the watch-side App Group `UserDefaults` — both the raw `WatchPayload` (encoded
/// as JSON, so the watch-side receiver and widget provider can decode it without needing
/// `WCSession` themselves) and the individual `StreakTracker`-compatible keys the receiver
/// writes so `StreakTracker.swift` runs unmodified on the watch.
public enum WatchPayloadKeys {
    public static let payloadData = "cobux.watch.payload"
}

public extension WatchPayload {
    /// Reads whatever the watch-side `WCSession` receiver last cached — no `WatchConnectivity`
    /// import needed here, so `CobuxWatchWidgets` (which never activates a session itself, only
    /// reads what `CobuxWatch` already received) doesn't need to link it either.
    static func loadCached(from defaults: UserDefaults) -> WatchPayload? {
        guard let data = defaults.data(forKey: WatchPayloadKeys.payloadData) else { return nil }
        return try? JSONDecoder().decode(WatchPayload.self, from: data)
    }
}
