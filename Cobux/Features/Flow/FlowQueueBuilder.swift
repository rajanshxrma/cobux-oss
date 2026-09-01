import Foundation

/// Builds Flow's card queue from the library's stored data — no embeddings
/// created, no generation, no network. Deterministic for a given (seedBase,
/// batch, library state); the base is random per session so every open deals
/// a fresh feed, and fixed within a session so re-renders can't reshuffle.
enum FlowQueueBuilder {
    static let batchSize = 40
    /// A recap card lands after every this-many content cards — the
    /// set-complete rhythm from the habit lens.
    static let recapInterval = 12
    /// Cards reviewed this recently are excluded from cloze teasers — Flow's
    /// light grading writes real FSRS state, and re-grading a card twice in
    /// one sitting would distort the schedule the Daily Review queue relies on.
    static let clozeReReviewGuard: TimeInterval = 12 * 60 * 60
    /// At most this many self-test cards per batch; Flow should feel like
    /// browsing, not like the quiz tab wearing a costume. Night mode halves
    /// the appetite further.
    static let maxClozePerBatch = 6
    static let maxClozePerBatchAtNight = 2
    /// Cross-book resonance pairs must clear this cosine similarity to count
    /// as "saying the same thing" — below it the pairing reads as random.
    static let resonanceThreshold: Float = 0.62

    /// The repeating type pattern. Highlights are the connective tissue
    /// (every other card), with the "surprise" types spaced between —
    /// variable reward with a deliberate rhythm.
    ///
    /// The eighth slot used to be a book-progress card. It's a key lesson now,
    /// not a shorter seven-slot pattern: seven is odd, so the cycle would wrap
    /// highlight-onto-highlight and quietly break the every-other-card
    /// alternation the rest of the rhythm is built on. Key lessons take the
    /// freed slot because their pool is the only other unbounded one (clozes
    /// cap at 6/batch, weak topics at 5), so the slot stays real content
    /// instead of degrading straight back to a highlight.
    private static let pattern: [CardKind] = [
        .highlight, .keyLesson, .highlight, .cloze,
        .highlight, .weakTopic, .highlight, .keyLesson,
    ]

    private enum CardKind { case highlight, keyLesson, cloze, weakTopic }

    /// SplitMix64 — tiny, seedable, good enough for feed shuffling. Swift's
    /// default RNG can't be seeded, and Flow needs determinism for both
    /// testability and a stable feed across view rebuilds.
    struct SeededRandomNumberGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Combines the caller's per-open base with the batch number. The base is
    /// random per Flow SESSION (each open feels fresh — Rajan's explicit
    /// feedback: reopening the app kept starting the feed from the same
    /// cards, which read as a bug, not stability) while staying fixed WITHIN
    /// a session so SwiftUI re-renders can't reshuffle cards already on
    /// screen. Tests pass a fixed base for determinism.
    static func seed(base: UInt64, forBatch batch: Int) -> UInt64 {
        base &* 1_000_003 &+ UInt64(batch)
    }

    /// Night mode (22:00–04:59): the feed turns quiet — fewer self-tests, no
    /// weak-topic callouts (no failure-framing at midnight), more long-form
    /// quotes. Daytime keeps exactly the standard pattern.
    static func isNight(_ now: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: now)
        return hour >= 22 || hour < 5
    }

    /// Finds the strongest cross-book highlight pairs using the embeddings
    /// the library ALREADY stores (creating embeddings costs; comparing them
    /// is free). Called once per session by FlowView, off the scroll path,
    /// over plain value tuples — never SwiftData objects on a background
    /// thread. Returns highlight-ID pairs, strongest first.
    static func resonancePairs(
        from candidates: [(id: UUID, bookID: UUID, embedding: [Float])],
        limit: Int = 6
    ) -> [(UUID, UUID)] {
        guard candidates.count > 1 else { return [] }
        var scored: [(Float, UUID, UUID)] = []
        for i in 0..<(candidates.count - 1) {
            for j in (i + 1)..<candidates.count {
                guard candidates[i].bookID != candidates[j].bookID else { continue }
                let score = EmbeddingService.cosineSimilarity(candidates[i].embedding, candidates[j].embedding)
                if score >= resonanceThreshold {
                    scored.append((score, candidates[i].id, candidates[j].id))
                }
            }
        }
        var used = Set<UUID>()
        var pairs: [(UUID, UUID)] = []
        for (_, a, b) in scored.sorted(by: { $0.0 > $1.0 }) {
            guard pairs.count < limit, !used.contains(a), !used.contains(b) else { continue }
            used.insert(a); used.insert(b)
            pairs.append((a, b))
        }
        return pairs
    }

    /// Recap rhythm state threaded ACROSS batches — recap numbering and the
    /// 12-card count must survive the batch seam, or set numbers skip and
    /// the rhythm stretches whenever resonance riders displace a slot.
    struct BatchContinuation {
        var contentSinceRecap = 0
        var recapNumber = 0
    }

    /// `excludedBookIDs` is applied once, here, to the book list every pool is
    /// derived from — so a switched-off book can't reach the feed through ANY
    /// card type (quotes, lessons, quick checks, weak topics, resonance, or the
    /// recap's next-book line) rather than each pool having to remember the
    /// rule separately. Empty by default: the filter is opt-in, and a library
    /// nobody has configured behaves exactly as it did before.
    static func buildBatch(
        books: [Book],
        batch: Int,
        seedBase: UInt64,
        resonancePairs: [(Highlight, Highlight)] = [],
        excludedBookIDs: Set<UUID> = [],
        continuation: inout BatchContinuation,
        now: Date = .now,
        recentlyShownIDs: Set<UUID> = [],
        /// Caller-supplied so this builder stays pure and deterministic (the
        /// whole point of `seedBase`, and what its tests rely on) -- the
        /// "have we already greeted them today" state lives in
        /// `StreakTracker.hasShownDailyOpenerToday`, read at the call site.
        includeDailyOpener: Bool = true
    ) -> [FlowCard] {
        var rng = SeededRandomNumberGenerator(seed: seed(base: seedBase, forBatch: batch))
        let night = isNight(now)

        let sourceBooks = excludedBookIDs.isEmpty
            ? books
            : books.filter { !excludedBookIDs.contains($0.id) }

        // Pools, shuffled once per batch with the seeded RNG, then cycled.
        var highlights = sourceBooks.flatMap(\.highlights).shuffled(using: &rng)
        if night {
            // Double-weight the contemplative profiles so a midnight feed
            // leans long-form serif, not exam prep.
            let contemplative = highlights.filter { highlight in
                let profile = highlight.book?.contentProfile
                return profile == .narrative || profile == .densePhilosophy
            }
            highlights = (highlights + contemplative).shuffled(using: &rng)
        }

        // Soft bias, not a hard exclusion: recently-shown highlights (see
        // `FlowRecentlyShownStore`) move to the BACK of the cycle rather than
        // being removed -- a small library where everything counts as
        // "recent" still gets its full pool, just reordered, instead of
        // ever showing nothing. Fixes a real live report: even with a fresh
        // random shuffle every session, a small pool reshuffled still lands
        // on largely the same highlights early, purely by chance.
        if !recentlyShownIDs.isEmpty {
            let fresh = highlights.filter { !recentlyShownIDs.contains($0.id) }
            let seen = highlights.filter { recentlyShownIDs.contains($0.id) }
            if !fresh.isEmpty {
                highlights = fresh + seen
            }
        }

        // Highlights that can't be read on their own go to the BACK, never out.
        //
        // Flow deals a highlight full-screen with no surrounding page, so a
        // fragment like "He was right about this" arrives as a card the reader
        // cannot parse at all -- his report: "some of the flow highlights are
        // just randomly picked or something cause i can't fucking comprehend
        // what they mean by just reading the flow highlight."
        //
        // A soft demotion, matching the recently-shown pass above, rather than
        // a filter: a small library must still get a full feed, and a fragment
        // is worth showing eventually rather than never. Same reasoning that
        // made the recency pass a reorder instead of an exclusion.
        let standalone = highlights.filter { Self.readsStandalone($0.text) }
        let fragments = highlights.filter { !Self.readsStandalone($0.text) }
        if !standalone.isEmpty {
            highlights = standalone + fragments
        }

        let lessons: [(Chapter, Int)] = sourceBooks.flatMap(\.chapters).flatMap { chapter in
            chapter.keyLessons.indices.map { (chapter, $0) }
        }.shuffled(using: &rng)

        let allQuestions = sourceBooks.flatMap(\.chapters).flatMap(\.quizQuestions)
        let clozeCap = night ? maxClozePerBatchAtNight : maxClozePerBatch
        let clozePool = allQuestions.filter { question in
            guard !question.isSuspended, question.correctAnswerIndex != nil else { return false }
            guard let dueDate = question.dueDate, dueDate <= now else { return false }
            if let lastReviewedAt = question.lastReviewedAt,
               now.timeIntervalSince(lastReviewedAt) < clozeReReviewGuard { return false }
            return true
        }.shuffled(using: &rng).prefix(clozeCap)

        // Weak topics: tags of cards the scheduler has seen lapse repeatedly.
        // Suppressed at night — nobody needs "you keep getting this wrong"
        // as a bedtime story.
        var weakTopics: [(key: String, value: Int)] = []
        if !night {
            var lapsesByTopic: [String: Int] = [:]
            for question in allQuestions where question.fsrsLapses >= 2 {
                for tag in question.topicTags {
                    lapsesByTopic[tag, default: 0] += question.fsrsLapses
                }
            }
            weakTopics = lapsesByTopic
                .sorted { $0.value > $1.value }
                .prefix(5)
                .shuffled(using: &rng)
        }

        // Resonance cards: at most one per recap-set so they stay rare enough
        // to feel like finding gold, spread across the batch. Pairs are
        // computed session-wide before the filter is known, so drop any pair
        // touching an excluded book here — a "gold" card is still half a card
        // from a book the user switched off.
        let allowedPairs = excludedBookIDs.isEmpty ? resonancePairs : resonancePairs.filter { pair in
            guard let first = pair.0.book?.id, let second = pair.1.book?.id else { return false }
            return !excludedBookIDs.contains(first) && !excludedBookIDs.contains(second)
        }
        var resonanceQueue = allowedPairs.shuffled(using: &rng)

        guard !highlights.isEmpty else { return [] }

        var cursors = (highlight: 0, lesson: 0, cloze: 0, weak: 0)
        var cards: [FlowCard] = []
        var patternIndex = 0

        // Session opener: exactly once, at the very top of batch 0. The due
        // count uses the SAME filters as the cloze pool (gradeable, not
        // recently reviewed) so the number never promises cards the feed
        // can't actually surface.
        // `batch == 0` alone was never enough: every Flow open starts a new
        // session at batch 0, so this greeting re-dealt itself on every
        // reopen. `includeDailyOpener` carries the once-per-DAY half.
        if batch == 0 && includeDailyOpener {
            let dueCount = allQuestions.filter { question in
                guard !question.isSuspended, question.correctAnswerIndex != nil else { return false }
                guard let dueDate = question.dueDate, dueDate <= now else { return false }
                if let lastReviewedAt = question.lastReviewedAt,
                   now.timeIntervalSince(lastReviewedAt) < clozeReReviewGuard { return false }
                return true
            }.count
            cards.append(.dailyOpener(streak: StreakTracker.currentStreak, dueCount: dueCount))
        }

        // "X has territory left" must never name a finished book — and, since
        // Rajan's note was that incomplete-progress framing reads as
        // disappointing, it now names the unfinished book CLOSEST to done
        // rather than the least-complete one. Same card, same copy, but it
        // points at the book you're about to finish instead of the one you
        // most abandoned (which, under the old `min`, was usually a book that
        // had never been opened at all). Ties break on title so the line stays
        // stable across recaps in a session.
        let nextBookTitle = sourceBooks
            .filter { !$0.chapters.isEmpty && ($0.chapterProgress ?? 0) < 1.0 }
            .max(by: { lhs, rhs in
                let left = lhs.chapterProgress ?? 0
                let right = rhs.chapterProgress ?? 0
                return left == right ? lhs.title > rhs.title : left < right
            })?.title

        while cards.count < batchSize {
            if continuation.contentSinceRecap == recapInterval {
                continuation.recapNumber += 1
                cards.append(.sessionRecap(
                    setNumber: continuation.recapNumber,
                    ripeningTomorrow: ripeningCount(in: allQuestions, now: now),
                    nextBook: nextBookTitle
                ))
                continuation.contentSinceRecap = 0
                // A resonance card rides right after a recap when one is
                // available — the reward beat lands at the set boundary.
                if !resonanceQueue.isEmpty {
                    let (a, b) = resonanceQueue.removeFirst()
                    cards.append(.resonance(a, b))
                }
                continue
            }

            let kind = pattern[patternIndex % pattern.count]
            patternIndex += 1
            continuation.contentSinceRecap += 1

            switch kind {
            case .highlight:
                cards.append(.highlight(highlights[cursors.highlight % highlights.count]))
                cursors.highlight += 1
            case .keyLesson where !lessons.isEmpty:
                let (chapter, index) = lessons[cursors.lesson % lessons.count]
                cards.append(.keyLesson(chapter, lessonIndex: index))
                cursors.lesson += 1
            case .cloze where cursors.cloze < clozePool.count:
                cards.append(.clozeTeaser(clozePool[clozePool.startIndex + cursors.cloze]))
                cursors.cloze += 1
            case .weakTopic where cursors.weak < weakTopics.count:
                let (topic, lapses) = weakTopics[cursors.weak]
                cards.append(.weakTopic(topic: topic, lapseCount: lapses))
                cursors.weak += 1
            default:
                // Depleted/empty pool: degrade to a highlight so a
                // highlight-only library still produces a full feed.
                cards.append(.highlight(highlights[cursors.highlight % highlights.count]))
                cursors.highlight += 1
            }
        }

        return cards
    }

    /// "N cards ripen overnight" for the recap card's tomorrow line — due
    /// within the next 24h but not due yet.
    static func ripeningCount(in questions: [QuizQuestion], now: Date = .now) -> Int {
        let tomorrow = now.addingTimeInterval(24 * 60 * 60)
        return questions.filter { question in
            guard !question.isSuspended, let dueDate = question.dueDate else { return false }
            return dueDate > now && dueDate <= tomorrow
        }.count
    }

    /// Whether a highlight can be understood with no surrounding page.
    ///
    /// Three cheap signals, deliberately conservative -- this only reorders, so
    /// a false negative costs a highlight its place near the front, never its
    /// place in the feed:
    /// - too short to carry a complete thought on its own
    /// - no terminal punctuation, i.e. it was clipped mid-sentence
    /// - opens on a bare referential word whose antecedent lives in the
    ///   paragraph above, which Flow does not show
    static func readsStandalone(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 40 else { return false }
        guard let last = trimmed.last, ".!?\u{201D}\"')".contains(last) else { return false }
        let opener = trimmed
            .prefix(while: { !$0.isWhitespace })
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased()
        let dangling: Set<String> = [
            "this", "that", "these", "those", "it", "its", "he", "she", "they", "them",
            "but", "which", "therefore", "thus", "and", "so", "because", "however", "hence"
        ]
        return !dangling.contains(opener)
    }
}
