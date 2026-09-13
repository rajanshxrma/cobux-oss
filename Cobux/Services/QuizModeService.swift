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
        /// How many answered questions this rate is computed over.
        ///
        /// Published because it was already being computed here and then
        /// recomputed by `QuizAnalyticsView` -- which rebuilt this theme's
        /// highlight-id `Set` INSIDE a filter closure, once per answer record,
        /// for each of the five topics it shows. The number is the same number;
        /// this is the one that was measured.
        let sampleSize: Int
    }

    static func weakestThemes(themes: [Theme], answerRecords: [QuizAnswerRecord]) -> [WeakTheme] {
        // Nothing answered means nothing can be weak -- and, until 61, this
        // guard was missing, so the loop below still faulted every theme's
        // highlights to intersect them with an empty set.
        guard !themes.isEmpty, !answerRecords.isEmpty else { return [] }

        // WALKED FROM THE RECORDS TO THE THEMES, not from the themes to
        // their highlights (build 61). The old shape read
        // `Set(theme.highlights.map(\.id))` for EVERY theme -- the whole tag
        // join, every highlight row with its full text and 2 KB vector,
        // ~33,000 rows across the library -- to decide which of a few
        // hundred answered questions touched it. `QuizHomeProbe` ran that on
        // every appearance of the Quiz tab, which is what was still slow on
        // 60 after everything else had moved off the frame. `Theme.highlights`
        // and `Highlight.themes` are inverses of one relationship, so
        // "record R touches theme T" is the same fact read either way; this
        // reads it from the side that is bounded by what he has answered: one
        // `themes` fault per DISTINCT source highlight of an answered
        // question (a handful of small `Theme` rows each), never per theme.
        // Same `matched`/`wrongCount` per theme, same threshold, same order.
        //
        // Records whose `question` has gone away are dropped, matching the
        // old `guard let question ... else { return false }`.
        var themeIDsByHighlight: [UUID: [UUID]] = [:]
        var matched: [UUID: Int] = [:]
        var wrongCount: [UUID: Int] = [:]
        for record in answerRecords {
            guard let question = record.question else { continue }
            var touched: Set<UUID> = []
            for highlight in question.sourceHighlights {
                let themeIDs: [UUID]
                if let known = themeIDsByHighlight[highlight.id] {
                    themeIDs = known
                } else {
                    themeIDs = highlight.themes.map(\.id)
                    themeIDsByHighlight[highlight.id] = themeIDs
                }
                touched.formUnion(themeIDs)
            }
            for themeID in touched {
                matched[themeID, default: 0] += 1
                if !record.isCorrect { wrongCount[themeID, default: 0] += 1 }
            }
        }

        return themes.compactMap { theme -> WeakTheme? in
            guard let sample = matched[theme.id], sample >= minSampleSizeForWeakTopic else { return nil }
            return WeakTheme(theme: theme,
                             wrongRate: Double(wrongCount[theme.id] ?? 0) / Double(sample),
                             sampleSize: sample)
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
        let weakHighlightIDs = weakHighlightIDs(themes: themes, answerRecords: answerRecords)
        guard !weakHighlightIDs.isEmpty else { return [] }
        return allQuestions.filter { question in
            !question.isSuspended && !Set(question.sourceHighlights.map(\.id)).isDisjoint(with: weakHighlightIDs)
        }
    }

    /// The highlight ids behind the current weakest themes -- the one set both
    /// `weakSpotsPool` (which builds the session on tap) and `QuizHomeProbe`
    /// (which counts it for the row, off the main actor) read from. One
    /// definition, so the number on the row and the size of the session it
    /// starts cannot drift apart.
    static func weakHighlightIDs(themes: [Theme], answerRecords: [QuizAnswerRecord]) -> Set<UUID> {
        Set(weakHighlights(themes: themes, answerRecords: answerRecords).map(\.id))
    }

    /// The highlights themselves, for a caller that walks their
    /// `quizQuestions` inverse rather than testing every question's
    /// `sourceHighlights` -- `QuizHomeProbe` counts the Weak Spots pool that
    /// way. Deduplicated by id: a highlight tagged with two weak themes is
    /// one highlight.
    static func weakHighlights(themes: [Theme], answerRecords: [QuizAnswerRecord]) -> [Highlight] {
        let weakest = weakestThemes(themes: themes, answerRecords: answerRecords).prefix(weakestThemeLimit)
        guard !weakest.isEmpty else { return [] }
        var seen: Set<UUID> = []
        return weakest.flatMap(\.theme.highlights).filter { seen.insert($0.id).inserted }
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
        let missedTags = missedTopicTags(answerRecords: answerRecords)
        guard !missedTags.isEmpty else { return [] }
        return allQuestions.filter { question in
            !question.isSuspended
                && isDiscriminationCandidate(questionType: question.questionType,
                                             choices: question.choices,
                                             topicTags: question.topicTags,
                                             missedTags: missedTags)
        }
    }

    /// Every topic tag on a question the user has answered wrongly. Shared
    /// with `QuizHomeProbe` for the same reason as `weakHighlightIDs`.
    static func missedTopicTags(answerRecords: [QuizAnswerRecord]) -> Set<String> {
        Set(
            answerRecords
                .filter { !$0.isCorrect }
                .compactMap { $0.question }
                .flatMap(\.topicTags)
        )
    }

    /// The per-question half of the drill filter, on plain values so a probe
    /// that fetched only these columns can apply the identical test.
    /// `isSuspended` is the caller's to check -- the probe puts it in the
    /// predicate, the pool reads it off the object.
    static func isDiscriminationCandidate(questionType: QuizQuestionType,
                                          choices: [String],
                                          topicTags: [String],
                                          missedTags: Set<String>) -> Bool {
        questionType != .application
            && !choices.isEmpty
            && !Set(topicTags).isDisjoint(with: missedTags)
    }

    /// Opens a quiz with its easiest questions, then shuffles the rest.
    ///
    /// His report: "the quiz section in Cobux is very hard... a user comes
    /// across the quiz part of the app and it doesn't appeal." A purely random
    /// order means the first card is as likely to be the hardest as the easiest,
    /// and the first card is what decides whether someone keeps going. Three
    /// easy ones first is enough to get moving; after that the mix is honest,
    /// so this makes the quiz feel approachable without making it easier.
    ///
    /// Ties are broken randomly so the same three don't lead every session.
    static func warmUpOrdered(_ questions: [QuizQuestion], warmUpCount: Int = 3) -> [QuizQuestion] {
        guard questions.count > warmUpCount else { return questions.shuffled() }
        let byEase = questions.shuffled().sorted { $0.difficulty < $1.difficulty }
        let warmUp = Array(byEase.prefix(warmUpCount))
        let warmUpIDs = Set(warmUp.map(\.id))
        return warmUp + questions.filter { !warmUpIDs.contains($0.id) }.shuffled()
    }
}
