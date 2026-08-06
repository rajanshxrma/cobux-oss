import Foundation

/// Cross-library "Daily Review" — the home mode Fable's Quiz redesign calls
/// for: a queue that spans every book's due cards, not scoped to one book
/// the way every existing Quiz entry point is. Reuses `QuizSessionView`/
/// `QuizResultsView` unchanged (`QuizAttempt.book` is already optional and
/// neither view has any hard dependency on it being set).
enum DailyReviewService {

    /// Default daily budgets — without a cap, the due queue grows past
    /// 1,000 at real textbook scale and a new user bounces off in week two.
    static let defaultNewPerDay = 20
    static let defaultReviewsPerDay = 120

    static func dueQuestions(in books: [Book], now: Date = .now) -> [QuizQuestion] {
        books
            .flatMap(\.chapters)
            .flatMap(\.quizQuestions)
            .filter { question in
                guard !question.isSuspended, let due = question.dueDate else { return false }
                return due <= now
            }
    }

    /// Applies the new/review split and daily caps, then shuffles the
    /// combined set — mixed throughout the session rather than presenting
    /// all-new-then-all-review as two separate blocks.
    static func budgetedQueue(
        from questions: [QuizQuestion],
        newPerDay: Int = defaultNewPerDay,
        reviewsPerDay: Int = defaultReviewsPerDay
    ) -> [QuizQuestion] {
        let newCards = questions.filter { $0.fsrsReps == 0 }.shuffled().prefix(newPerDay)
        let reviewCards = questions.filter { $0.fsrsReps > 0 }.shuffled().prefix(reviewsPerDay)
        return (Array(newCards) + Array(reviewCards)).shuffled()
    }
}
