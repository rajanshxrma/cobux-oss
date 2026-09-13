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
        dueQuestions(among: books.allQuizQuestions, now: now)
    }

    /// The same filter against a question list a caller has already gathered,
    /// so a caller building several pools pays for `allQuizQuestions` once —
    /// see its doc comment for why that traversal is worth doing exactly once.
    /// (`QuizHomeProbe` restates this filter as a predicate:
    /// `isSuspended == false && chapter != nil && dueDate <= now`.)
    static func dueQuestions(among questions: [QuizQuestion], now: Date = .now) -> [QuizQuestion] {
        questions.filter { question in
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

extension Collection where Element == Book {
    /// Every quiz question in the library, in one traversal.
    ///
    /// Spelled out here rather than repeated inline because it is genuinely
    /// expensive: it faults each book's `chapters` relationship and then each
    /// chapter's `quizQuestions` relationship, so at this library's scale (26
    /// seed books, ~490 chapters) it is thousands of SwiftData faults per call.
    /// Cheap enough once per tap, ruinous when a SwiftUI computed property
    /// re-runs it on every access — which is exactly what `QuizHomeView` was
    /// doing roughly twenty-five times per render, then once per render from
    /// a single-pass snapshot, and now never: its counts are `COUNT`s read by
    /// `QuizHomeProbe` off the main actor, and this traversal runs only when a
    /// session is actually started.
    var allQuizQuestions: [QuizQuestion] {
        flatMap(\.chapters).flatMap(\.quizQuestions)
    }
}
