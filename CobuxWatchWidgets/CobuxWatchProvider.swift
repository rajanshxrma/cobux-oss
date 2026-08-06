import WidgetKit
import Foundation

struct WatchGlanceEntry: TimelineEntry {
    let date: Date
    let streakCount: Int
    let dueCount: Int
    let quoteText: String?
    let quoteBook: String?
}

/// No `ModelContainer` here — per Fable's Watch companion ruling, this widget extension reads
/// only the small `WatchPayload` the phone last pushed (cached in the watch-local App Group
/// UserDefaults by `WatchConnectivityReceiver`), never the real SwiftData store.
struct CobuxWatchProvider: TimelineProvider {
    private static let refreshInterval: TimeInterval = 30 * 60
    private static let entryCount = 12
    private let defaults = UserDefaults(suiteName: "group.com.rajansharma.Cobux") ?? .standard

    func placeholder(in context: Context) -> WatchGlanceEntry {
        WatchGlanceEntry(date: .now, streakCount: 3, dueCount: 12, quoteText: "Small changes compound over time.", quoteBook: "Atomic Habits")
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchGlanceEntry) -> Void) {
        completion(currentEntry(fallback: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchGlanceEntry>) -> Void) {
        guard let payload = WatchPayload.loadCached(from: defaults) else {
            let timeline = Timeline(entries: [placeholder(in: context)], policy: .after(Date().addingTimeInterval(Self.refreshInterval)))
            completion(timeline)
            return
        }

        let now = Date()
        var entries: [WatchGlanceEntry] = []
        for index in 0..<Self.entryCount {
            let entryDate = now.addingTimeInterval(Self.refreshInterval * Double(index))
            // The due count rises across the day as `upcomingDueDates` timestamps pass, so this
            // stays honest even if the phone doesn't push again for hours -- the whole point of
            // sending an array of upcoming due-dates instead of just today's snapshot count.
            let risingCount = payload.dueCount + payload.upcomingDueDates.filter { $0 <= entryDate }.count
            entries.append(WatchGlanceEntry(
                date: entryDate,
                streakCount: payload.streakCount,
                dueCount: risingCount,
                quoteText: payload.quoteText,
                quoteBook: payload.quoteBook
            ))
        }

        let timeline = Timeline(entries: entries, policy: .after(now.addingTimeInterval(Self.refreshInterval * Double(Self.entryCount))))
        completion(timeline)
    }

    private func currentEntry(fallback context: Context) -> WatchGlanceEntry {
        guard let payload = WatchPayload.loadCached(from: defaults) else {
            return placeholder(in: context)
        }
        let now = Date()
        let risingCount = payload.dueCount + payload.upcomingDueDates.filter { $0 <= now }.count
        return WatchGlanceEntry(date: now, streakCount: payload.streakCount, dueCount: risingCount, quoteText: payload.quoteText, quoteBook: payload.quoteBook)
    }
}
