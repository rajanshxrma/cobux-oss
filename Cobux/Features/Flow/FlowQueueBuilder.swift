import Foundation
import Observation

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
    /// `Sendable` because it now rides in `FlowBatchRequest`/`FlowBatchPlan`
    /// to and from `FlowPoolProbe`'s executor -- two integers, nothing else.
    struct BatchContinuation: Sendable {
        var contentSinceRecap = 0
        var recapNumber = 0
    }

    /// The raw material one batch is dealt from. Rows, not books.
    ///
    /// `buildBatch(books:)` used to derive every pool itself, by walking the
    /// `Book` relationships: `flatMap(\.highlights)` materialised the ENTIRE
    /// highlight table (32,125 rows across 156 seed books, each carrying a
    /// 2 KB embedding blob -- tens of megabytes of managed objects) on the
    /// main actor, `flatMap(\.chapters)` and `flatMap(\.quizQuestions)` ran
    /// one SELECT per book and per chapter, and the recap's next-book line
    /// faulted `chapters` three more times per book. About five seconds of
    /// main-actor CPU to deal forty cards, paid at open behind the instant
    /// card and again at every batch seam. That is the "it is still slow"
    /// he reported, and it is the 0x8BADF00D watchdog class from build 46.
    ///
    /// The builder now takes its pools as arguments and stays exactly as
    /// pure and seeded as before; the CALLER decides how the pools are
    /// filled. `FlowView` fills them with bounded, indexed `FetchDescriptor`s
    /// (a few hundred rows per batch); the `books:` overload below fills them
    /// from the arrays, for the tests and for any caller with a small
    /// in-memory library. Same builder, same cards.
    struct Pools {
        /// Highlights the batch may deal. Order is the caller's; the builder
        /// shuffles with its own seeded RNG, exactly as before.
        var highlights: [Highlight]
        /// Chapters whose key lessons feed the lesson slot, and from which the
        /// recap's next-book line is derived (completed / total per book).
        var chapters: [Chapter]
        /// Candidates for the cloze slot. The builder applies the FULL cloze
        /// filter (gradeable, due at `now`, not reviewed inside the 12 h
        /// guard) itself, so a caller may pass a superset -- the arrays
        /// overload passes every question; `FlowView` passes rows a SQL
        /// predicate has already narrowed to due-and-gradeable.
        var dueQuestions: [QuizQuestion]
        /// Candidates for the weak-topic callout (`fsrsLapses >= 2`); the
        /// builder re-checks the threshold, so a superset is fine here too.
        var lapsedQuestions: [QuizQuestion]
        /// "N cards are ripe for review" on batch 0's opener. Already counted
        /// under the cloze filter INCLUDING the 12 h guard, so the number
        /// never promises cards the feed cannot surface.
        var dueCount: Int
        /// "N cards ripen overnight" on every recap card.
        var ripeningTomorrow: Int
    }

    /// `excludedBookIDs` is applied once, here, to the book list every pool is
    /// derived from — so a switched-off book can't reach the feed through ANY
    /// card type (quotes, lessons, quick checks, weak topics, resonance, or the
    /// recap's next-book line) rather than each pool having to remember the
    /// rule separately. Empty by default: the filter is opt-in, and a library
    /// nobody has configured behaves exactly as it did before.
    ///
    /// The array-fed form. Every pool is derived from the books' relationships
    /// and handed to `buildBatch(pools:)`, which is where the dealing lives.
    /// Fine for a test library of a few dozen rows; on a real one it faults the
    /// whole library onto the calling actor, which is why `FlowView` no longer
    /// calls it (see `Pools`).
    static func buildBatch(
        books: [Book],
        batch: Int,
        seedBase: UInt64,
        resonancePairs: [(Highlight, Highlight)] = [],
        /// An entry he wrote on this calendar date in an earlier year, already
        /// selected and snapshotted by the caller so this builder stays pure
        /// and seeded. Nil on most days, and that is the normal case.
        journalEcho: (entryID: UUID, date: Date, passage: String)? = nil,
        excludedBookIDs: Set<UUID> = [],
        continuation: inout BatchContinuation,
        now: Date = .now,
        recentlyShownIDs: Set<UUID> = [],
        /// Ids he has told Flow never to deal again -- see `FlowSuppression`.
        /// Read at the call site, like `recentlyShownIDs`, so the builder
        /// stays pure and its tests never touch a real defaults suite.
        suppressedIDs: Set<UUID> = [],
        /// Caller-supplied so this builder stays pure and deterministic (the
        /// whole point of `seedBase`, and what its tests rely on) -- the
        /// "have we already greeted them today" state lives in
        /// `StreakTracker.hasShownDailyOpenerToday`, read at the call site.
        includeDailyOpener: Bool = true
    ) -> [FlowCard] {
        let sourceBooks = excludedBookIDs.isEmpty
            ? books
            : books.filter { !excludedBookIDs.contains($0.id) }
        // One traversal of the library's chapters, two readers (lessons and
        // questions) -- the second flatMap could only ever produce the array
        // the first already had.
        let chapters = sourceBooks.flatMap(\.chapters)
        let questions = chapters.flatMap(\.quizQuestions)
        let pools = Pools(
            highlights: sourceBooks.flatMap(\.highlights),
            chapters: chapters,
            dueQuestions: questions,
            lapsedQuestions: questions,
            dueCount: questions.filter { isGradeableAndDue($0, now: now) }.count,
            ripeningTomorrow: ripeningCount(in: questions, now: now)
        )
        return buildBatch(
            pools: pools,
            batch: batch,
            seedBase: seedBase,
            resonancePairs: resonancePairs,
            journalEcho: journalEcho,
            excludedBookIDs: excludedBookIDs,
            continuation: &continuation,
            now: now,
            recentlyShownIDs: recentlyShownIDs,
            suppressedIDs: suppressedIDs,
            includeDailyOpener: includeDailyOpener
        )
    }

    /// The pool-fed form -- the builder proper.
    ///
    /// `excludedBookIDs` is still applied here, to every pool, so the rule
    /// lives in one place whichever overload filled them: the arrays overload
    /// has already dropped excluded books (so this pass is a no-op there), and
    /// `FlowView`'s fetches draw highlights only from included books but fetch
    /// chapters and questions library-wide, so this is where a switched-off
    /// book's lessons, quick checks and weak topics are kept out. A row with
    /// no book cannot belong to an excluded one and is kept, matching
    /// `BookSourceFilter.isVisible`.
    ///
    /// `suppressedIDs` is the per-card "Don't show this again" (see
    /// `FlowSuppression`), applied to every pool built from a highlight or a
    /// quick check -- the highlight cycle, the cloze pool and the resonance
    /// pairs -- the same once-per-builder shape as `excludedBookIDs`, so no
    /// card type has to remember the rule on its own. A hard filter, unlike
    /// the recency demotion: he asked never to see it, so it is never dealt.
    /// Filters consume no RNG, so with an empty set every draw below is
    /// byte-identical to what it was.
    ///
    /// RNG draw order is unchanged from the original body and is load-bearing
    /// (highlights -> night -> lessons -> cloze -> weakTopics -> resonance):
    /// a fixed `seedBase` must keep dealing the feed it dealt before.
    static func buildBatch(
        pools: Pools,
        batch: Int,
        seedBase: UInt64,
        resonancePairs: [(Highlight, Highlight)] = [],
        journalEcho: (entryID: UUID, date: Date, passage: String)? = nil,
        excludedBookIDs: Set<UUID> = [],
        continuation: inout BatchContinuation,
        now: Date = .now,
        recentlyShownIDs: Set<UUID> = [],
        suppressedIDs: Set<UUID> = [],
        includeDailyOpener: Bool = true
    ) -> [FlowCard] {
        var rng = SeededRandomNumberGenerator(seed: seed(base: seedBase, forBatch: batch))
        let night = isNight(now)

        func allowed(_ book: Book?) -> Bool {
            guard !excludedBookIDs.isEmpty, let book else { return true }
            return !excludedBookIDs.contains(book.id)
        }
        // Both hard filters in ONE pass over each pool, and only when at
        // least one of them has something to say -- an unconfigured library
        // takes the same no-copy path it always did.
        let hasHardFilter = !excludedBookIDs.isEmpty || !suppressedIDs.isEmpty
        let sourceHighlights = hasHardFilter
            ? pools.highlights.filter { allowed($0.book) && !suppressedIDs.contains($0.id) }
            : pools.highlights
        let sourceChapters = excludedBookIDs.isEmpty
            ? pools.chapters : pools.chapters.filter { allowed($0.book) }
        let dueCandidates = hasHardFilter
            ? pools.dueQuestions.filter { allowed($0.book) && !isSuppressed($0, in: suppressedIDs) }
            : pools.dueQuestions
        let lapsedCandidates = excludedBookIDs.isEmpty
            ? pools.lapsedQuestions : pools.lapsedQuestions.filter { allowed($0.book) }

        // Pools, shuffled once per batch with the seeded RNG, then cycled.
        var highlights = sourceHighlights.shuffled(using: &rng)
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
        // ONE pass, not two. This was two `filter`s over the same array with
        // the same predicate -- so `readsStandalone` ran twice for every
        // highlight in the library, and it is not a cheap predicate: it trims,
        // counts, walks a prefix, trims again and lowercases, allocating each
        // time. On this library that was roughly 64,000 invocations to produce
        // a partition that one traversal answers.
        //
        // Byte-identical output, and provably so: `filter` preserves source
        // order, both passes read the same pure predicate over the same array,
        // and the two are exact complements (`p` and `!p`). Appending each
        // element to one bucket or the other in source order therefore builds
        // exactly the arrays the two filters built. No RNG is consumed here, by
        // either shape.
        var standalone: [Highlight] = []
        var fragments: [Highlight] = []
        for highlight in highlights {
            if Self.readsStandalone(highlight.text) {
                standalone.append(highlight)
            } else {
                fragments.append(highlight)
            }
        }
        if !standalone.isEmpty {
            highlights = standalone + fragments
        }

        // RNG order: `lessons`' `shuffled(using: &rng)` is the one draw in this
        // region and stays exactly where it was in the sequence (highlights ->
        // night -> lessons -> cloze -> weakTopics -> resonance).
        let lessons: [(Chapter, Int)] = sourceChapters.flatMap { chapter in
            chapter.keyLessons.indices.map { (chapter, $0) }
        }.shuffled(using: &rng)

        let clozeCap = night ? maxClozePerBatchAtNight : maxClozePerBatch
        let clozePool = dueCandidates
            .filter { isGradeableAndDue($0, now: now) }
            .shuffled(using: &rng)
            .prefix(clozeCap)

        // Weak topics: tags of cards the scheduler has seen lapse repeatedly.
        // Suppressed at night — nobody needs "you keep getting this wrong"
        // as a bedtime story.
        var weakTopics: [(key: String, value: Int)] = []
        if !night {
            var lapsesByTopic: [String: Int] = [:]
            for question in lapsedCandidates where question.fsrsLapses >= 2 {
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
        // The same goes for a suppressed highlight: half a gold card is
        // still a card he asked never to see.
        let allowedPairs = hasHardFilter ? resonancePairs.filter { pair in
            guard let first = pair.0.book?.id, let second = pair.1.book?.id else { return false }
            return !excludedBookIDs.contains(first) && !excludedBookIDs.contains(second)
                && !suppressedIDs.contains(pair.0.id) && !suppressedIDs.contains(pair.1.id)
        } : resonancePairs
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
            cards.append(.dailyOpener(streak: StreakTracker.currentStreak, dueCount: pools.dueCount))
        }

        // The echo rides straight after the greeting, in batch 0 only.
        //
        // It is the one card that is true of TODAY specifically, so burying it
        // behind thirty library cards would waste the only day it means
        // anything. When there is no echo it is simply not dealt -- its absence
        // is never announced, which is what keeps it from becoming something he
        // failed to have.
        if batch == 0, let echo = journalEcho {
            cards.append(.journalEcho(entryID: echo.entryID, date: echo.date,
                                      passage: echo.passage))
        }

        // "X has territory left" must never name a finished book — and, since
        // Rajan's note was that incomplete-progress framing reads as
        // disappointing, it now names the unfinished book CLOSEST to done
        // rather than the least-complete one. Same card, same copy, but it
        // points at the book you're about to finish instead of the one you
        // most abandoned (which, under the old `min`, was usually a book that
        // had never been opened at all). Ties break on title so the line stays
        // stable across recaps in a session.
        //
        // Derived from the chapters pool, not from `Book.chapterProgress`:
        // that property is `completedChapterCount / chapters.count`, which
        // faulted every book's `chapters` relationship three times per batch
        // just to name one title. The same ratio over the same chapters,
        // grouped by book, reads only rows the batch already holds.
        let nextBookTitle = Self.nextBookTitle(in: sourceChapters)

        while cards.count < batchSize {
            if continuation.contentSinceRecap == recapInterval {
                continuation.recapNumber += 1
                cards.append(.sessionRecap(
                    setNumber: continuation.recapNumber,
                    ripeningTomorrow: pools.ripeningTomorrow,
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

    /// The cloze slot's filter, and the opener's due count, in one place: a
    /// gradeable card (not suspended, has a fixed correct answer), due at
    /// `now`, and not graded inside the re-review guard. The opener uses the
    /// SAME predicate as the pool so its number never promises cards the feed
    /// cannot actually surface.
    static func isGradeableAndDue(_ question: QuizQuestion, now: Date) -> Bool {
        guard !question.isSuspended, question.correctAnswerIndex != nil else { return false }
        guard let dueDate = question.dueDate, dueDate <= now else { return false }
        if let lastReviewedAt = question.lastReviewedAt,
           now.timeIntervalSince(lastReviewedAt) < clozeReReviewGuard { return false }
        return true
    }

    /// Whether a quick check is one he asked Flow not to deal again: its own
    /// id (the cloze card's "Don't show this again" records the question), or
    /// a source highlight he suppressed -- a check built from a line he never
    /// wants to see is that line wearing a question mark.
    ///
    /// `sourceHighlights` is a to-many fault, so it is touched only when the
    /// set is non-empty and only for the batch's few dozen due candidates --
    /// bounded, and free for the library nobody has suppressed anything in.
    static func isSuppressed(_ question: QuizQuestion, in suppressedIDs: Set<UUID>) -> Bool {
        guard !suppressedIDs.isEmpty else { return false }
        if suppressedIDs.contains(question.id) { return true }
        return question.sourceHighlights.contains { suppressedIDs.contains($0.id) }
    }

    /// The unfinished book closest to done, by completed-chapter ratio over
    /// the given chapters, ties broken on title (see the call site). A book
    /// is "unfinished" when it has at least one chapter and not all of them
    /// are completed -- the same set `Book.chapterProgress < 1.0` describes,
    /// computed without touching a `Book`'s relationships.
    static func nextBookTitle(in chapters: [Chapter]) -> String? {
        struct Tally { var completed = 0; var total = 0; var title = "" }
        var byBook: [UUID: Tally] = [:]
        for chapter in chapters {
            guard let book = chapter.book else { continue }
            var tally = byBook[book.id] ?? Tally(title: book.title)
            tally.total += 1
            if chapter.isCompleted { tally.completed += 1 }
            byBook[book.id] = tally
        }
        // Written as a plain loop: the lazy map/filter/max chain with a tuple
        // literal and a ternary comparator is exactly the shape the type
        // checker gives up on ("unable to type-check this expression in
        // reasonable time"), which is what stopped the 58 build once.
        var bestTitle: String?
        var bestProgress = -1.0
        for tally in byBook.values where tally.total > 0 {
            let progress = Double(tally.completed) / Double(tally.total)
            guard progress < 1.0 else { continue }
            let wins = progress > bestProgress
                || (progress == bestProgress && tally.title > (bestTitle ?? ""))
            if wins {
                bestProgress = progress
                bestTitle = tally.title
            }
        }
        return bestTitle
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
    /// Built once, not per highlight.
    ///
    /// This was a `Set` literal INSIDE `readsStandalone`, so it was allocated
    /// and populated on every call -- once per highlight in a batch, on the
    /// main actor, on Flow's open path. Nineteen strings is nothing; nineteen
    /// strings thirty-two thousand times is not, and the set is the same set
    /// every time.
    private static let danglingOpeners: Set<String> = [
        "this", "that", "these", "those", "it", "its", "he", "she", "they", "them",
        "but", "which", "therefore", "thus", "and", "so", "because", "however", "hence"
    ]

    static func readsStandalone(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 40 else { return false }
        guard let last = trimmed.last, ".!?\u{201D}\"')".contains(last) else { return false }
        let opener = trimmed
            .prefix(while: { !$0.isWhitespace })
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased()
        return !Self.danglingOpeners.contains(opener)
    }
}

/// Cards he has told Flow never to deal again -- the per-card half of the
/// suppression the library's per-book "Hide from Flow" already has.
///
/// `EbbSuppressionStore`'s shape exactly: a persisted set of ids, no
/// confirmation, no undo prompt, no toast -- Cobux never grades or nags, and a
/// dismissal that argues back is a nag. The one difference is the store. This
/// lives in the App-Group suite (`CobuxSchema.groupDefaults`) rather than
/// `UserDefaults.standard`, because the home-screen widget deals from the same
/// highlight table in its own process and must be able to honour the same
/// dismissals, or the widget and Flow disagree about what he has hidden. The
/// widget's read is `groupDefaults.stringArray(forKey: FlowSuppression.key)`;
/// this file is not compiled into that target, so the key is `static let`
/// and documented here rather than shared as a symbol.
///
/// Holds highlight ids AND quick-check (question) ids in one set: both are
/// UUIDs from disjoint tables, and one set means one read per batch and one
/// "Show hidden highlights again" that clears everything he hid. Flow-only by
/// design -- a hidden quick check keeps its FSRS schedule and still comes up
/// in the Quiz tab; what "never ask me again" should do to the schedule is a
/// separate ruling (docs/deferred.md), not something this store decides.
///
/// Lives here rather than in `Services/` for the reason `FlowResonanceProbe`
/// gives at the bottom of `FlowView.swift`: the project lists every source
/// file individually, so a new file would not join the target.
enum FlowSuppression {
    /// The App-Group key. Named once, here; the widget reads it by this value.
    static let key = "cobux.flow.suppressedHighlights"

    private static var defaults: UserDefaults { CobuxSchema.groupDefaults }

    /// Every id he has hidden. One array read and one decode -- the same cost
    /// as `FlowRecentlyShownStore.recentIDs()`, which every batch already pays.
    static func suppressedHighlightIDs() -> Set<UUID> {
        let stored = defaults.stringArray(forKey: key) ?? []
        return Set(stored.compactMap(UUID.init(uuidString:)))
    }

    static func isSuppressed(_ id: UUID) -> Bool {
        (defaults.stringArray(forKey: key) ?? []).contains(id.uuidString)
    }

    /// Anything hidden at all -- what decides whether the reverse path's row
    /// is shown. Never a count: the number of things he chose not to see is
    /// not information he asked for.
    static var hasSuppressions: Bool {
        !(defaults.stringArray(forKey: key) ?? []).isEmpty
    }

    /// Main-actor because it moves the signal below; every caller is a view
    /// action anyway.
    @MainActor
    static func suppress(_ id: UUID) {
        var stored = defaults.stringArray(forKey: key) ?? []
        guard !stored.contains(id.uuidString) else { return }
        stored.append(id.uuidString)
        defaults.set(stored, forKey: key)
        FlowSuppressionSignal.shared.bump()
    }

    /// "Show hidden highlights again." Everything at once, quietly: the
    /// hidden cards simply become dealable from the next batch on.
    @MainActor
    static func clearAll() {
        guard hasSuppressions else { return }
        defaults.removeObject(forKey: key)
        FlowSuppressionSignal.shared.bump()
    }
}

/// The suppression store's change signal -- `EbbSuppressionSignal`'s shape: a
/// `@MainActor @Observable` singleton a view folds into what it renders, so
/// the reverse path's row appears the moment something is hidden and leaves
/// the moment everything is shown again, without a callback threaded through
/// every card.
@MainActor
@Observable
final class FlowSuppressionSignal {
    static let shared = FlowSuppressionSignal()
    private init() {}

    private(set) var revision = 0

    func bump() { revision += 1 }
}
