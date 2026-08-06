import SwiftData
import Foundation

/// A lightweight Leitner-box spaced-repetition ledger, one per highlight that
/// has ever actually been quizzed. Created lazily on first encounter — never
/// pre-populated for the thousands of never-quizzed highlights in the two
/// medical textbooks.
@Model
final class HighlightMemory {
    var id: UUID = UUID()
    var highlight: Highlight?
    var box: Int = 1
    var nextReviewDate: Date
    var lastReviewedDate: Date?
    var timesSeen: Int = 0
    var timesCorrect: Int = 0
    var consecutiveCorrect: Int = 0
    /// 1 = guessed, 2 = unsure, 3 = confident
    var lastConfidenceRaw: Int?

    init(highlight: Highlight?, nextReviewDate: Date = .now) {
        self.id = UUID()
        self.highlight = highlight
        self.nextReviewDate = nextReviewDate
    }

    private static let boxIntervalDays: [Int: Double] = [1: 0, 2: 2, 3: 5, 4: 12, 5: 30]

    /// Advances this highlight's box after being quizzed. A correct-but-guessed
    /// answer resurfaces at half the normal interval — a guess isn't real
    /// retention even when it happens to land right — while a confident
    /// correct answer earns the full interval. `confidence: nil` (exam mode,
    /// which intentionally doesn't collect it) is stored honestly as unknown
    /// rather than fabricated as "unsure" — it behaves identically to any
    /// non-1 value here (only a guessed=1 answer halves the interval), so
    /// nothing about the actual scheduling changes, but `lastConfidenceRaw`
    /// no longer claims a rating the user never gave.
    func recordAnswer(correct: Bool, confidence: Int?) {
        timesSeen += 1
        lastReviewedDate = .now
        lastConfidenceRaw = confidence

        if correct {
            timesCorrect += 1
            consecutiveCorrect += 1
            box = min(5, box + 1)
        } else {
            consecutiveCorrect = 0
            box = 1
        }

        let baseInterval = Self.boxIntervalDays[box] ?? 0
        let interval = (correct && confidence == 1) ? baseInterval / 2 : baseInterval
        nextReviewDate = Calendar.current.date(byAdding: .day, value: Int(interval), to: .now) ?? .now
    }
}
