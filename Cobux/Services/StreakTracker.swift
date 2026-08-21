import Foundation

/// A daily-engagement streak, local-only (UserDefaults, no new SwiftData
/// model needed). Counts "showing up" once per calendar day — adding a
/// highlight or finishing any quiz activity both count, since Cobux serves
/// two different daily habits (Rajan's reflective reading, Utkarsh's
/// exam-cram quizzing) that shouldn't need separate streaks.
///
/// 2.3.0 adds streak protection: every 7 consecutive active days earns a
/// streak freeze (bank capped at 2), and a missed day is silently covered by
/// a banked freeze — consumed retroactively the next time activity is
/// recorded — instead of resetting the streak to 1. Milestone crossings
/// (7/30/100/365) are parked in `pendingMilestone` for the app to celebrate
/// and clear. This type stays Foundation-only: it's compiled into the widget
/// and Watch targets as-is, so no UserNotifications/SwiftUI imports here.
enum StreakTracker {
    /// Shared App Group suite (not `.standard`) so the widget extension --
    /// a separate sandboxed process -- can read the same streak the main
    /// app writes, for the Lock Screen circular widget.
    private static let defaults = UserDefaults(suiteName: "group.com.rajansharma.Cobux") ?? .standard
    /// `internal`, not `private` — `CobuxWatch`'s `WCSession` receiver writes into these exact
    /// keys (in its own, watch-local copy of this same App Group suite) so this type's own
    /// `currentStreak`/`recordActivityToday` — compiled unmodified into `CobuxWatch` too — see
    /// the synced value without needing a second, duplicated set of key strings.
    static let lastActiveDateKey = "cobux.streak.lastActiveDate"
    static let currentStreakKey = "cobux.streak.currentStreak"
    static let freezeBankKey = "cobux.streak.freezeBank"
    static let freezeProgressKey = "cobux.streak.freezeProgress"
    static let pendingMilestoneKey = "cobux.streak.pendingMilestone"
    static let longestStreakKey = "cobux.streak.longestStreak"

    static let milestones = [7, 30, 100, 365]
    static let freezeEarnInterval = 7
    static let freezeBankCap = 2

    /// Call this from any place that represents real daily engagement
    /// (saving a highlight, finishing a quiz with at least one answer).
    /// Safe to call more than once per day — a no-op after the first call.
    @discardableResult
    static func recordActivityToday() -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        guard let lastActive = defaults.object(forKey: lastActiveDateKey) as? Date else {
            return startFresh(today: today)
        }

        // Snapshot once, before any writes below, rather than re-reading
        // `currentStreakKey` from `defaults` right before each use. This
        // doesn't make the whole function atomic across processes (App Group
        // UserDefaults has no cross-process transaction), but it collapses
        // the window in which a concurrent call from the widget extension —
        // a separate sandboxed process sharing this exact App Group suite,
        // which can call this at the same wall-clock moment the main app
        // does (e.g. a shuffle/back/forward tap right as the app opens) —
        // could read back a value THIS call already wrote and add its own +1
        // on top, double-advancing the streak for a single day's activity.
        // (The Watch is not part of this race: per this file's own doc above,
        // it writes its own local copy of the App Group suite on-device, not
        // this process's store, so it's eventually-consistent via sync, not
        // concurrent.)
        let streakSnapshot = defaults.integer(forKey: currentStreakKey)

        let daysBetween = calendar.dateComponents([.day], from: calendar.startOfDay(for: lastActive), to: today).day ?? 0
        switch daysBetween {
        case ..<0:
            // The clock moved backward relative to the last recorded activity
            // — a timezone change (flying west), a manual clock correction,
            // or similar. Never let a negative gap reach the "missed days"
            // math below: `missedDays = daysBetween - 1` would go very
            // negative, which reads as "way under the freeze bank" and would
            // both grant free freeze-bank credit AND double-advance the
            // streak for a day that's either already counted or untrustworthy
            // either way. Treat it as a no-op, same as same-day re-entry —
            // the read-only `currentStreak` below already guards the same way
            // via `max(0, daysBetween - 1)`.
            return streakSnapshot
        case 0:
            return streakSnapshot
        case 1:
            return advance(to: streakSnapshot + 1, today: today)
        default:
            // Missed day(s). Banked freezes cover the gap retroactively — the
            // streak continues as if the gap never happened, minus the spent
            // freezes. A gap bigger than the bank resets honestly.
            let missedDays = daysBetween - 1
            let bank = defaults.integer(forKey: freezeBankKey)
            if missedDays <= bank {
                defaults.set(bank - missedDays, forKey: freezeBankKey)
                // The gap broke the *consecutive* run that earns freezes, even
                // though the streak itself survived.
                defaults.set(0, forKey: freezeProgressKey)
                return advance(to: streakSnapshot + 1, today: today, countsTowardFreeze: false)
            }
            return startFresh(today: today)
        }
    }

    private static func startFresh(today: Date) -> Int {
        defaults.set(today, forKey: lastActiveDateKey)
        defaults.set(1, forKey: currentStreakKey)
        defaults.set(1, forKey: freezeProgressKey)
        // A genuine reset clears the bank: freezes protect an established
        // habit, and letting them survive the streak they failed to save
        // would let a brand-new 1-day streak start life with maximum
        // protection — making the honest-zero display rule meaningless for
        // the first week.
        defaults.set(0, forKey: freezeBankKey)
        updateLongest(with: 1)
        return 1
    }

    private static func advance(to newStreak: Int, today: Date, countsTowardFreeze: Bool = true) -> Int {
        defaults.set(today, forKey: lastActiveDateKey)
        defaults.set(newStreak, forKey: currentStreakKey)

        if countsTowardFreeze {
            var progress = defaults.integer(forKey: freezeProgressKey) + 1
            if progress >= freezeEarnInterval {
                let bank = defaults.integer(forKey: freezeBankKey)
                if bank < freezeBankCap {
                    defaults.set(bank + 1, forKey: freezeBankKey)
                }
                progress = 0
            }
            defaults.set(progress, forKey: freezeProgressKey)
        } else {
            defaults.set(1, forKey: freezeProgressKey)
        }

        if milestones.contains(newStreak) {
            defaults.set(newStreak, forKey: pendingMilestoneKey)
        }
        updateLongest(with: newStreak)
        return newStreak
    }

    private static func updateLongest(with streak: Int) {
        if streak > defaults.integer(forKey: longestStreakKey) {
            defaults.set(streak, forKey: longestStreakKey)
        }
    }

    /// Read-only, doesn't record anything -- returns 0 once the streak is
    /// genuinely lost rather than waiting for the next `recordActivityToday()`
    /// call to notice, so the display is always honest. Freeze-aware: a gap
    /// the banked freezes can still cover shows the stored streak (it will
    /// survive the next recorded activity), a bigger gap shows 0. On the
    /// watch, `freezeBank` is absent from the local suite (reads 0) and the
    /// sync receiver stamps `lastActiveDate = now`, so behavior there is
    /// unchanged from pre-freeze builds.
    static var currentStreak: Int {
        let calendar = Calendar.current
        guard let lastActive = defaults.object(forKey: lastActiveDateKey) as? Date else { return 0 }
        let daysBetween = calendar.dateComponents([.day], from: calendar.startOfDay(for: lastActive), to: calendar.startOfDay(for: .now)).day ?? 0
        let missedDays = max(0, daysBetween - 1)
        return missedDays <= defaults.integer(forKey: freezeBankKey) ? defaults.integer(forKey: currentStreakKey) : 0
    }

    /// Whether today has already been counted — drives the streak-at-risk
    /// evening reminder (no nudge needed once you've shown up).
    static var hasShownUpToday: Bool {
        guard let lastActive = defaults.object(forKey: lastActiveDateKey) as? Date else { return false }
        return Calendar.current.isDateInToday(lastActive)
    }

    static var freezeBank: Int { defaults.integer(forKey: freezeBankKey) }
    static var longestStreak: Int { defaults.integer(forKey: longestStreakKey) }

    /// A milestone crossed by a recent `recordActivityToday()` that the app
    /// hasn't celebrated yet; 0 when none. The celebration UI reads this and
    /// calls `clearPendingMilestone()` on dismiss.
    static var pendingMilestone: Int { defaults.integer(forKey: pendingMilestoneKey) }

    static func clearPendingMilestone() {
        defaults.removeObject(forKey: pendingMilestoneKey)
    }
}
