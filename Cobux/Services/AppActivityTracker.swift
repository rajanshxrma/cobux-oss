import Foundation

/// Tracks real app-open timestamps so Reminders' "Smart timing" option can
/// schedule wisdom-reminder notifications at times the user actually opens
/// Cobux, instead of a fixed clock time someone has to set by hand and keep
/// current as their own routine shifts.
///
/// Deliberately a bare hour-of-day histogram in `UserDefaults`, not a new
/// SwiftData model or a per-timestamp log -- the only thing a schedule
/// decision ever needs is "which hours does this person tend to open the
/// app," and a rolling, bounded sample keeps that answer current without
/// growing forever.
enum AppActivityTracker {
    private static let defaults = UserDefaults.standard
    private static let key = "cobux.activity.openHours"
    /// Bounded so this never grows unboundedly for a daily user -- roughly
    /// two months of once-a-day opens, comfortably enough to smooth over a
    /// handful of unusual days without going stale for months.
    private static let maxSamples = 60
    /// Below this many real opens, a hour-of-day mode is too noisy to act
    /// on -- `smartHours` returns `nil` rather than a shaky guess, and
    /// callers should fall back to a sensible fixed default until then.
    static let minimumSamplesForSmartTiming = 7

    /// Call once per genuine foreground transition (`ContentView`'s cold-launch
    /// `.task` and its scenePhase-`.active` handler) -- never from a plain
    /// view-body re-render, or every SwiftUI re-evaluation would count as a
    /// fresh "open" and the histogram would just measure render frequency.
    static func recordOpen(at date: Date = .now) {
        let hour = Calendar.current.component(.hour, from: date)
        var samples = defaults.array(forKey: key) as? [Int] ?? []
        samples.append(hour)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        defaults.set(samples, forKey: key)
    }

    /// The `count` most common hours the user actually opens the app,
    /// earliest first -- `nil` when there isn't enough real data yet to
    /// trust. Ties break toward the earlier hour so the result is stable
    /// run to run rather than flipping on dictionary-ordering noise.
    static func smartHours(count: Int = 2) -> [Int]? {
        let samples = defaults.array(forKey: key) as? [Int] ?? []
        guard samples.count >= minimumSamplesForSmartTiming else { return nil }

        var frequency: [Int: Int] = [:]
        for hour in samples { frequency[hour, default: 0] += 1 }

        let ranked = frequency.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        let top = ranked.prefix(count).map(\.key).sorted()
        return top.isEmpty ? nil : top
    }
}
