import Foundation

/// The single feature that makes this a medical-student app, not a generic
/// flashcard tool: set an exam date, and two things change automatically —
/// nothing is ever scheduled past exam day, and the retention target rises as
/// it approaches, compressing intervals exactly the way a serious Anki user
/// already does by hand before a real exam.
public enum ExamCountdown {

    /// Never fewer than 1 — "the exam is today" still needs a countdown that
    /// makes sense, not a zero/negative day count breaking downstream math.
    public static func daysLeft(from now: Date, to examDate: Date, calendar: Calendar = .current) -> Int {
        let days = calendar.dateComponents([.day], from: now, to: examDate).day ?? 0
        return max(1, days)
    }

    /// Rises in the final stretch — compresses intervals (a 0.95 target cuts
    /// the raw FSRS interval to ~46% of a 0.90 target at the same stability)
    /// without the user having to manually retune anything.
    public static func desiredRetention(daysLeft: Int) -> Double {
        if daysLeft > 14 { return 0.90 }
        if daysLeft > 7 { return 0.93 }
        return 0.95
    }

    /// The clamp that does the actual work: nothing FSRS schedules can ever
    /// land past the exam, so cramming near the end can't accidentally push
    /// a card's next review to after it no longer matters.
    public static func maxIntervalDays(daysLeft: Int) -> Int { daysLeft }

    /// How many never-introduced cards need to start each day to cover
    /// everything before the exam, with a few days of buffer at the end for
    /// review rather than still meeting new material the day before.
    public static func requiredNewPerDay(notIntroduced: Int, daysLeft: Int, bufferDays: Int = 3) -> Int {
        guard notIntroduced > 0 else { return 0 }
        let effectiveDays = max(1, daysLeft - bufferDays)
        return Int((Double(notIntroduced) / Double(effectiveDays)).rounded(.up))
    }

    /// Simple linear projection: at a given new-cards-per-day pace, what
    /// fraction of the not-yet-introduced pool will have been seen at least
    /// once by exam day (with the buffer applied, same as the required-pace
    /// calculation). Intentionally linear/optimistic — a real coverage curve
    /// would need per-user retention modeling this feature doesn't have
    /// data for yet; this is the same order of estimate a user would make
    /// by hand ("N cards, M days left, P per day").
    public static func projectedCoverage(notIntroduced: Int, daysLeft: Int, newPerDay: Int, bufferDays: Int = 3) -> Double {
        guard notIntroduced > 0 else { return 1.0 }
        let effectiveDays = max(1, daysLeft - bufferDays)
        let projected = Double(newPerDay * effectiveDays)
        return min(1.0, projected / Double(notIntroduced))
    }
}
