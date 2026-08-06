import Foundation

/// Pool-building for the quiz modes named in the original Phase 4 plan but never built:
/// Rapid Recall, Discrimination Drills, and Weak Spots. Chapter Cram needs no new pooling
/// logic (it reuses the existing per-chapter `chapter.quizQuestions` pool `QuizScopeBuilderView`
/// already builds -- the gap there was a global entry point, not new logic; see
/// `ChapterCramPickerView`). Each mode here runs through the existing `QuizSessionView`/
/// `QuizResultsView` unchanged, exactly like Daily Review -- a distinct pool + a distinctive
/// `scopeDescription`, not a new `QuizMode` case (grading/timer semantics don't change).
enum QuizModeService {

    /// A short, review-only top-up between full Daily Review sessions -- deliberately NOT
    /// "Daily Review but smaller": only already-seen cards (fsrsReps > 0, so no new-card
    /// introduction budget competes with it), soonest-due first, hard-capped so it always
    /// reads as "quick," never as a second full queue.
    static let rapidRecallLimit = 15

    static func rapidRecallPool(books: [Book], now: Date = .now) -> [QuizQuestion] {
        let allQuestions = books.flatMap(\.chapters).flatMap(\.quizQuestions)
        let dueReviews = allQuestions.filter { question -> Bool in
            guard !question.isSuspended, question.fsrsReps > 0, let due = question.dueDate else { return false }
            return due <= now
        }
        let sorted = dueReviews.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        return Array(sorted.prefix(rapidRecallLimit))
    }

    /// A topic needs at least this many answered questions before it's judged "weak" -- one
    /// unlucky guess on a topic seen once shouldn't brand it. Mirrors `QuizAnalyticsView`'s
    /// own threshold, since this and the Analytics "Weakest Topics" panel must agree on what
    /// counts as weak -- same reasoning as the FSRS/Leitner due-count unification earlier.
    static let minSampleSizeForWeakTopic = 3
    static let weakestThemeLimit = 3

    struct WeakTheme {
        let theme: Theme
        let wrongRate: Double
    }

    static func weakestThemes(themes: [Theme], answerRecords: [QuizAnswerRecord]) -> [WeakTheme] {
        themes.compactMap { theme -> WeakTheme? in
            let highlightIDs = Set(theme.highlights.map(\.id))
            let records = answerRecords.filter { record in
                guard let question = record.question else { return false }
                return !Set(question.sourceHighlights.map(\.id)).isDisjoint(with: highlightIDs)
            }
            guard records.count >= minSampleSizeForWeakTopic else { return nil }
            let wrongCount = records.filter { !$0.isCorrect }.count
            return WeakTheme(theme: theme, wrongRate: Double(wrongCount) / Double(records.count))
        }
        .sorted { $0.wrongRate > $1.wrongRate }
    }

    /// Every due-or-not question belonging to the current weakest themes' highlights --
    /// deliberately not FSRS-due-gated, since the whole point is targeted extra practice on
    /// a known-weak spot, not waiting for the scheduler to bring it back around.
    static func weakSpotsPool(books: [Book], themes: [Theme], answerRecords: [QuizAnswerRecord]) -> [QuizQuestion] {
        let weakest = weakestThemes(themes: themes, answerRecords: answerRecords).prefix(weakestThemeLimit)
        guard !weakest.isEmpty else { return [] }
        let weakHighlightIDs = Set(weakest.flatMap { $0.theme.highlights.map(\.id) })
        return books
            .flatMap(\.chapters)
            .flatMap(\.quizQuestions)
            .filter { question in
                !question.isSuspended && !Set(question.sourceHighlights.map(\.id)).isDisjoint(with: weakHighlightIDs)
            }
    }

    /// "Assembled from a confusion matrix built out of wrong-answer tag pairs" (the plan's own
    /// phrasing) -- no per-choice tag data exists to build a true pairwise confusion matrix, so
    /// this is the honest, data-grounded approximation: pool every MCQ question that shares a
    /// topic tag with a question the user has actually gotten wrong, across the whole library.
    /// Free (assembled from data already collected, no generation call), matching the plan's
    /// own description of this mode.
    static func discriminationDrillPool(books: [Book], answerRecords: [QuizAnswerRecord]) -> [QuizQuestion] {
        let missedTags = Set(
            answerRecords
                .filter { !$0.isCorrect }
                .compactMap { $0.question }
                .flatMap(\.topicTags)
        )
        guard !missedTags.isEmpty else { return [] }
        return books
            .flatMap(\.chapters)
            .flatMap(\.quizQuestions)
            .filter { question in
                !question.isSuspended
                    && question.questionType != .application
                    && !question.choices.isEmpty
                    && !Set(question.topicTags).isDisjoint(with: missedTags)
            }
    }
}
