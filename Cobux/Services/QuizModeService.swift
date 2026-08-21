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
        rapidRecallPool(among: books.allQuizQuestions, now: now)
    }

    /// Question-list overloads for every pool below, so a caller that needs
    /// several pools at once pays for `allQuizQuestions` a single time instead
    /// of once per pool. The `books:` entry points are unchanged and simply
    /// forward, so single-pool callers read exactly as they did.
    static func rapidRecallPool(among allQuestions: [QuizQuestion], now: Date = .now) -> [QuizQuestion] {
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
        // Each record's source-highlight IDs, resolved exactly once. This used
        // to be rebuilt inside the per-theme loop, so every record's
        // `question` relationship and its whole `sourceHighlights` list was
        // faulted again for each theme — O(themes × records × highlights) of
        // pure repeat work, on the main thread, from a SwiftUI computed
        // property. Records whose `question` has gone away are dropped here,
        // matching the old `guard let question ... else { return false }`.
        let scoredRecords = answerRecords.compactMap { record in
            record.question.map {
                (isCorrect: record.isCorrect, highlightIDs: Set($0.sourceHighlights.map(\.id)))
            }
        }

        return themes.compactMap { theme -> WeakTheme? in
            let highlightIDs = Set(theme.highlights.map(\.id))
            var matched = 0
            var wrongCount = 0
            for record in scoredRecords where !record.highlightIDs.isDisjoint(with: highlightIDs) {
                matched += 1
                if !record.isCorrect { wrongCount += 1 }
            }
            guard matched >= minSampleSizeForWeakTopic else { return nil }
            return WeakTheme(theme: theme, wrongRate: Double(wrongCount) / Double(matched))
        }
        .sorted { $0.wrongRate > $1.wrongRate }
    }

    /// Every due-or-not question belonging to the current weakest themes' highlights --
    /// deliberately not FSRS-due-gated, since the whole point is targeted extra practice on
    /// a known-weak spot, not waiting for the scheduler to bring it back around.
    static func weakSpotsPool(books: [Book], themes: [Theme], answerRecords: [QuizAnswerRecord]) -> [QuizQuestion] {
        weakSpotsPool(among: books.allQuizQuestions, themes: themes, answerRecords: answerRecords)
    }

    static func weakSpotsPool(among allQuestions: [QuizQuestion], themes: [Theme], answerRecords: [QuizAnswerRecord]) -> [QuizQuestion] {
        let weakest = weakestThemes(themes: themes, answerRecords: answerRecords).prefix(weakestThemeLimit)
        guard !weakest.isEmpty else { return [] }
        let weakHighlightIDs = Set(weakest.flatMap { $0.theme.highlights.map(\.id) })
        return allQuestions.filter { question in
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
        discriminationDrillPool(among: books.allQuizQuestions, answerRecords: answerRecords)
    }

    static func discriminationDrillPool(among allQuestions: [QuizQuestion], answerRecords: [QuizAnswerRecord]) -> [QuizQuestion] {
        let missedTags = Set(
            answerRecords
                .filter { !$0.isCorrect }
                .compactMap { $0.question }
                .flatMap(\.topicTags)
        )
        guard !missedTags.isEmpty else { return [] }
        return allQuestions.filter { question in
            !question.isSuspended
                && question.questionType != .application
                && !question.choices.isEmpty
                && !Set(question.topicTags).isDisjoint(with: missedTags)
        }
    }
}
