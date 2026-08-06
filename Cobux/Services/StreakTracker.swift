import Foundation

/// A daily-engagement streak, local-only (UserDefaults, no new SwiftData
/// model needed). Counts "showing up" once per calendar day — adding a
/// highlight or finishing any quiz activity both count, since Cobux serves
/// two different daily habits (Rajan's reflective reading, Utkarsh's
/// exam-cram quizzing) that shouldn't need separate streaks.
enum StreakTracker {
    /// Shared App Group suite (not `.standard`) so the widget extension --
    /// a separate sandboxed process -- can read the same streak the main
    /// app writes, for the Lock Screen circular widget.
    private static let defaults = UserDefaults(suiteName: "group.com.rajansharma.Cobux") ?? .standard
    private static let lastActiveDateKey = "cobux.streak.lastActiveDate"
    private static let currentStreakKey = "cobux.streak.currentStreak"

    /// Call this from any place that represents real daily engagement
    /// (saving a highlight, finishing a quiz with at least one answer).
    /// Safe to call more than once per day — a no-op after the first call.
    @discardableResult
    static func recordActivityToday() -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        guard let lastActive = defaults.object(forKey: lastActiveDateKey) as? Date else {
            defaults.set(today, forKey: lastActiveDateKey)
            defaults.set(1, forKey: currentStreakKey)
            return 1
        }

        let daysBetween = calendar.dateComponents([.day], from: calendar.startOfDay(for: lastActive), to: today).day ?? 0
        switch daysBetween {
        case 0:
            return defaults.integer(forKey: currentStreakKey)
        case 1:
            let newStreak = defaults.integer(forKey: currentStreakKey) + 1
            defaults.set(today, forKey: lastActiveDateKey)
            defaults.set(newStreak, forKey: currentStreakKey)
            return newStreak
        default:
            defaults.set(today, forKey: lastActiveDateKey)
            defaults.set(1, forKey: currentStreakKey)
            return 1
        }
    }

    /// Read-only, doesn't record anything -- returns 0 once a day has been
    /// missed rather than waiting for the next `recordActivityToday()` call
    /// to notice, so the display is always honest.
    static var currentStreak: Int {
        let calendar = Calendar.current
        guard let lastActive = defaults.object(forKey: lastActiveDateKey) as? Date else { return 0 }
        let daysBetween = calendar.dateComponents([.day], from: calendar.startOfDay(for: lastActive), to: calendar.startOfDay(for: .now)).day ?? 0
        return daysBetween > 1 ? 0 : defaults.integer(forKey: currentStreakKey)
    }
}
