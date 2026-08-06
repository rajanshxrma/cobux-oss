import SwiftData
import Foundation

enum QuizMode: String, Codable {
    case practice
    case examSimulation
}

@Model
final class QuizAttempt {
    var id: UUID = UUID()
    var book: Book?
    var scopeDescription: String
    var modeRaw: String
    var startedAt: Date
    var completedAt: Date?
    var totalQuestions: Int = 0
    var correctCount: Int = 0
    var skippedCount: Int = 0
    /// Questions actually answered before the attempt finished — distinct from
    /// `totalQuestions` (the full count assigned at creation), so ending a quiz
    /// early scores against what was really attempted instead of silently
    /// counting every un-reached question as wrong.
    var answeredCount: Int = 0
    var timeLimitSeconds: Int?
    var timeTakenSeconds: Int?
    /// Wall-clock exam deadline, set once at start — the timer recomputes
    /// `remainingSeconds` from this every tick instead of decrementing a
    /// counter, so backgrounding the app can no longer gift free time (a
    /// counter-based timer simply stops ticking while suspended; a deadline
    /// comparison against `Date()` can't drift that way).
    var deadline: Date?

    @Relationship(deleteRule: .cascade, inverse: \QuizAnswerRecord.attempt)
    var answers: [QuizAnswerRecord] = []

    var mode: QuizMode {
        get { QuizMode(rawValue: modeRaw) ?? .practice }
        set { modeRaw = newValue.rawValue }
    }

    var scorePercent: Double? {
        guard answeredCount > 0 else { return nil }
        return Double(correctCount) / Double(answeredCount)
    }

    init(book: Book?, scopeDescription: String, mode: QuizMode, timeLimitSeconds: Int? = nil, startedAt: Date = .now) {
        self.id = UUID()
        self.book = book
        self.scopeDescription = scopeDescription
        self.modeRaw = mode.rawValue
        self.timeLimitSeconds = timeLimitSeconds
        self.startedAt = startedAt
    }
}
