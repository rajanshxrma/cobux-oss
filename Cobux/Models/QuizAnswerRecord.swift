import SwiftData
import Foundation

@Model
final class QuizAnswerRecord {
    var id: UUID = UUID()
    var attempt: QuizAttempt?
    var question: QuizQuestion?
    var selectedAnswerIndex: Int?
    var isCorrect: Bool = false
    /// 1 = guessed, 2 = unsure, 3 = confident — also used for the self-graded
    /// "Nailed it / Partially / Missed it" rating on `.application` questions.
    var confidenceRaw: Int?
    var timeSpentSeconds: Double = 0
    var markedForReview: Bool = false
    /// The user's typed/spoken free-recall answer for `.application` questions —
    /// previously bound in the UI but never actually persisted anywhere, so it
    /// was silently discarded every time.
    var answerText: String?
    /// The order choices were actually shown in for this presentation (indexes
    /// into `QuizQuestion.choices`) — choices are now shuffled per presentation
    /// so repeat sessions don't train answer position instead of content; this
    /// records what was really on screen, for an accurate results replay.
    var presentedChoiceOrder: [Int] = []

    init(attempt: QuizAttempt?, question: QuizQuestion?) {
        self.id = UUID()
        self.attempt = attempt
        self.question = question
    }
}
