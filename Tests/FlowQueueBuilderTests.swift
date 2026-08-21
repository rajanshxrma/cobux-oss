import XCTest
import SwiftData
@testable import Cobux

@MainActor
final class FlowQueueBuilderTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Book.self, Chapter.self, Highlight.self, QuizQuestion.self, configurations: config)
        return ModelContext(container)
    }

    private func makeLibrary(context: ModelContext, highlightCount: Int = 10, lessonsPerChapter: Int = 3) -> Book {
        let book = Book(title: "Sapiens", author: "Yuval Noah Harari")
        context.insert(book)
        let chapter = Chapter(title: "1. An Animal of No Significance", summary: "s")
        chapter.keyLessons = (0..<lessonsPerChapter).map { "Lesson \($0)" }
        chapter.book = book
        book.chapters.append(chapter)
        for index in 0..<highlightCount {
            let highlight = Highlight(text: "Highlight \(index)", chapter: chapter.title, tags: ["history"], isReminder: false)
            highlight.book = book
            context.insert(highlight)
            book.highlights.append(highlight)
        }
        return book
    }

    func testBatchIsFullSizeAndDeterministicPerSeed() throws {
        let context = try makeContext()
        let book = makeLibrary(context: context)

        var c = FlowQueueBuilder.BatchContinuation()
        let first = FlowQueueBuilder.buildBatch(books: [book], batch: 0, seedBase: 42, continuation: &c)
        var cRepeat = FlowQueueBuilder.BatchContinuation()
        let second = FlowQueueBuilder.buildBatch(books: [book], batch: 0, seedBase: 42, continuation: &cRepeat)

        XCTAssertEqual(first.count, FlowQueueBuilder.batchSize)
        XCTAssertEqual(first.map(\.id), second.map(\.id), "same seed base + same batch number must produce the same feed")

        let nextBatch = FlowQueueBuilder.buildBatch(books: [book], batch: 1, seedBase: 42, continuation: &c)
        XCTAssertNotEqual(first.map(\.id), nextBatch.map(\.id), "the next batch must differ")

        var c2 = FlowQueueBuilder.BatchContinuation()
        let freshOpen = FlowQueueBuilder.buildBatch(books: [book], batch: 0, seedBase: 43, continuation: &c2)
        XCTAssertNotEqual(first.map(\.id), freshOpen.map(\.id), "a new session's seed base must deal a different feed")
    }

    func testHighlightOnlyLibraryStillFillsAFeed() throws {
        let context = try makeContext()
        let book = Book(title: "Greenlights", author: "Matthew McConaughey")
        context.insert(book)
        for index in 0..<3 {
            let highlight = Highlight(text: "Quote \(index)", chapter: nil, tags: [], isReminder: false)
            highlight.book = book
            context.insert(highlight)
            book.highlights.append(highlight)
        }

        var c = FlowQueueBuilder.BatchContinuation()
        let cards = FlowQueueBuilder.buildBatch(books: [book], batch: 0, seedBase: 7, continuation: &c)
        XCTAssertEqual(cards.count, FlowQueueBuilder.batchSize, "empty pools degrade to highlights, not to a short feed")
        // Batch 0 opens with the daily-opener card; recap cards land every
        // recapInterval; this book has no chapters at all, so every OTHER
        // card must have degraded to a highlight.
        if case .dailyOpener = cards[0] {} else { XCTFail("batch 0 must open with the daily opener") }
        XCTAssertTrue(cards.dropFirst().allSatisfy { card in
            switch card {
            case .highlight, .sessionRecap: return true
            default: return false
            }
        })
    }

    func testRecapCardsLandOnTheSetRhythm() throws {
        let context = try makeContext()
        let book = makeLibrary(context: context)
        var c = FlowQueueBuilder.BatchContinuation()
        let cards = FlowQueueBuilder.buildBatch(books: [book], batch: 0, seedBase: 9, continuation: &c)
        let recapCount = cards.filter { if case .sessionRecap = $0 { return true } else { return false } }.count
        XCTAssertGreaterThanOrEqual(recapCount, 2, "a 40-card batch with a 12-card set rhythm carries recap beats")
    }

    func testRecapNumberingSurvivesBatchSeams() throws {
        let context = try makeContext()
        let book = makeLibrary(context: context)
        var c = FlowQueueBuilder.BatchContinuation()
        let batch0 = FlowQueueBuilder.buildBatch(books: [book], batch: 0, seedBase: 5, continuation: &c)
        let batch1 = FlowQueueBuilder.buildBatch(books: [book], batch: 1, seedBase: 5, continuation: &c)
        let setNumbers = (batch0 + batch1).compactMap { card -> Int? in
            if case .sessionRecap(let n, _, _) = card { return n }
            return nil
        }
        XCTAssertEqual(setNumbers, Array(1...setNumbers.count), "recap set numbers must be contiguous across batch seams")
    }

    func testResonancePairsRequireCrossBookSimilarity() {
        let bookA = UUID(), bookB = UUID()
        let vector: [Float] = [1, 0, 0]
        let candidates: [(id: UUID, bookID: UUID, embedding: [Float])] = [
            (UUID(), bookA, vector),
            (UUID(), bookB, vector),          // identical vector, different book -> pair
            (UUID(), bookA, vector),          // identical vector, SAME book as first -> never paired with it
            (UUID(), bookB, [0, 1, 0]),       // orthogonal -> below threshold
        ]
        let pairs = FlowQueueBuilder.resonancePairs(from: candidates)
        XCTAssertFalse(pairs.isEmpty)
        // Every returned pair must span two books by construction.
        XCTAssertLessThanOrEqual(pairs.count, 2)
    }

    func testEmptyLibraryProducesEmptyFeed() throws {
        _ = try makeContext()
        var c = FlowQueueBuilder.BatchContinuation()
        XCTAssertTrue(FlowQueueBuilder.buildBatch(books: [], batch: 0, seedBase: 7, continuation: &c).isEmpty)
    }

    // MARK: - Book progress cards are gone

    /// The card type itself is deleted, so the compiler is the real guard here.
    /// This is the belt-and-braces check: nothing in a chaptered library may
    /// produce a progress card, whose feed IDs were prefixed "progress-".
    func testNoProgressCardsAreEverDealt() throws {
        let context = try makeContext()
        let book = makeLibrary(context: context)
        book.chapters[0].isCompleted = true

        var c = FlowQueueBuilder.BatchContinuation()
        let cards = FlowQueueBuilder.buildBatch(books: [book], batch: 0, seedBase: 11, continuation: &c)
        XCTAssertFalse(cards.contains { $0.id.hasPrefix("progress-") },
                       "Flow must not surface incomplete-progress cards")
    }

    /// The freed eighth pattern slot became a key lesson, not a shorter
    /// seven-slot cycle -- an odd-length pattern would wrap highlight onto
    /// highlight and break the every-other-card alternation.
    func testHighlightAlternationSurvivesTheRemovedSlot() throws {
        let context = try makeContext()
        let book = makeLibrary(context: context, highlightCount: 30, lessonsPerChapter: 30)
        let chapter = book.chapters[0]
        // A fixed midday timestamp: night mode suppresses weak topics and caps
        // clozes at 2, which would empty the very pools this test needs full.
        let noon = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 12))!

        for index in 0..<8 {
            let question = QuizQuestion(book: book, chapter: chapter, questionType: .recallMCQ, prompt: "Q\(index)", explanation: "e")
            question.choices = ["a", "b"]
            question.correctAnswerIndex = 0
            question.dueDate = noon.addingTimeInterval(-3600)
            question.topicTags = ["topic-\(index)"]
            question.fsrsLapses = 2 + index
            context.insert(question)
            chapter.quizQuestions.append(question)
        }

        var c = FlowQueueBuilder.BatchContinuation()
        let cards = FlowQueueBuilder.buildBatch(books: [book], batch: 0, seedBase: 3, continuation: &c, now: noon)
        // Sanity: the pools this test depends on are genuinely non-empty, so a
        // pass can't come from everything degrading to highlights.
        XCTAssertTrue(cards.contains { if case .clozeTeaser = $0 { return true } else { return false } })
        XCTAssertTrue(cards.contains { if case .weakTopic = $0 { return true } else { return false } })
        XCTAssertTrue(cards.contains { if case .keyLesson = $0 { return true } else { return false } })
        // Ignore the structural cards (opener/recap) -- the alternation claim
        // is about the content rhythm the pattern drives.
        let content = cards.filter { card in
            switch card {
            case .dailyOpener, .sessionRecap, .resonance: return false
            default: return true
            }
        }
        var consecutiveHighlights = 0
        var worst = 0
        for card in content {
            if case .highlight = card {
                consecutiveHighlights += 1
                worst = max(worst, consecutiveHighlights)
            } else {
                consecutiveHighlights = 0
            }
        }
        XCTAssertLessThanOrEqual(worst, 1, "highlights must stay every-other-card, including across the pattern wrap")
    }

    // MARK: - Book inclusion filter

    func testExcludedBooksNeverReachAnyCardType() throws {
        let context = try makeContext()
        let kept = makeLibrary(context: context)
        let dropped = Book(title: "Meditations", author: "Marcus Aurelius")
        context.insert(dropped)
        let droppedChapter = Chapter(title: "Book I", summary: "s")
        droppedChapter.keyLessons = ["Excluded lesson"]
        droppedChapter.book = dropped
        dropped.chapters.append(droppedChapter)
        for index in 0..<10 {
            let highlight = Highlight(text: "Excluded quote \(index)", chapter: droppedChapter.title, tags: ["stoicism"], isReminder: false)
            highlight.book = dropped
            context.insert(highlight)
            dropped.highlights.append(highlight)
        }
        let droppedQuestion = QuizQuestion(book: dropped, chapter: droppedChapter, questionType: .recallMCQ, prompt: "excluded", explanation: "e")
        droppedQuestion.choices = ["a", "b"]
        droppedQuestion.correctAnswerIndex = 0
        droppedQuestion.dueDate = Date().addingTimeInterval(-3600)
        context.insert(droppedQuestion)
        droppedChapter.quizQuestions.append(droppedQuestion)

        var c = FlowQueueBuilder.BatchContinuation()
        let cards = FlowQueueBuilder.buildBatch(
            books: [kept, dropped],
            batch: 0,
            seedBase: 21,
            excludedBookIDs: [dropped.id],
            continuation: &c
        )

        XCTAssertEqual(cards.count, FlowQueueBuilder.batchSize, "one excluded book must not shorten the feed")
        for card in cards {
            switch card {
            case .highlight(let highlight):
                XCTAssertNotEqual(highlight.book?.id, dropped.id)
            case .keyLesson(let chapter, _):
                XCTAssertNotEqual(chapter.book?.id, dropped.id)
            case .clozeTeaser(let question):
                XCTAssertNotEqual(question.book?.id, dropped.id)
            case .resonance(let a, let b):
                XCTAssertNotEqual(a.book?.id, dropped.id)
                XCTAssertNotEqual(b.book?.id, dropped.id)
            case .sessionRecap(_, _, let nextBook):
                XCTAssertNotEqual(nextBook, dropped.title, "the recap's next-book line must respect the filter too")
            case .weakTopic, .dailyOpener:
                break
            }
        }
    }

    func testExcludingEveryBookProducesAnEmptyFeed() throws {
        let context = try makeContext()
        let book = makeLibrary(context: context)
        var c = FlowQueueBuilder.BatchContinuation()
        let cards = FlowQueueBuilder.buildBatch(
            books: [book],
            batch: 0,
            seedBase: 4,
            excludedBookIDs: [book.id],
            continuation: &c
        )
        XCTAssertTrue(cards.isEmpty, "excluding every book yields an empty feed, not a crash or a partial one")
    }

    func testEmptyFilterChangesNothing() throws {
        let context = try makeContext()
        let book = makeLibrary(context: context)
        var unfiltered = FlowQueueBuilder.BatchContinuation()
        let a = FlowQueueBuilder.buildBatch(books: [book], batch: 0, seedBase: 77, continuation: &unfiltered)
        var filtered = FlowQueueBuilder.BatchContinuation()
        let b = FlowQueueBuilder.buildBatch(books: [book], batch: 0, seedBase: 77, excludedBookIDs: [], continuation: &filtered)
        XCTAssertEqual(a.map(\.id), b.map(\.id), "the filter is opt-in — an empty exclusion set must be a no-op")
    }

    func testFilterEncodingRoundTripsAndIsStable() {
        let ids: Set<UUID> = [UUID(), UUID(), UUID()]
        let encoded = BookSourceFilter.encode(ids)
        XCTAssertEqual(BookSourceFilter.decode(encoded), ids)
        XCTAssertEqual(encoded, BookSourceFilter.encode(ids), "encoding must be order-stable so writes that change nothing don't churn the default")
        XCTAssertTrue(BookSourceFilter.decode("").isEmpty, "no stored value means no exclusions")
        XCTAssertTrue(BookSourceFilter.decode("not-a-uuid").isEmpty, "garbage in the default must not throw or exclude a real book")
    }

    /// A library of ordinary books must not be able to tell that
    /// profile-based defaulting exists at all.
    func testNoReferenceBooksMeansNoDefaultExclusions() throws {
        let context = try makeContext()
        let a = Book(title: "A", author: "A", contentProfile: .propositional)
        let b = Book(title: "B", author: "B", contentProfile: .narrative)
        context.insert(a)
        context.insert(b)
        XCTAssertTrue(
            BookSourceFilter.effectiveExcludedIDs(books: [a, b], excludedRaw: "", includedRaw: "").isEmpty,
            "a library with no reference texts must produce no default exclusions"
        )
        XCTAssertTrue(
            BookSourceFilter.effectiveExcludedIDs(books: [], excludedRaw: "", includedRaw: "").isEmpty,
            "an empty library must be a no-op, not an error"
        )
    }

    func testReferenceBooksAreExcludedByDefaultAndReversible() throws {
        let context = try makeContext()
        let selfHelp = Book(title: "Self Help", author: "A", contentProfile: .propositional)
        let reference = Book(title: "Robbins", author: "B", contentProfile: .academicReference)
        context.insert(selfHelp)
        context.insert(reference)
        let books = [selfHelp, reference]

        let defaults = BookSourceFilter.effectiveExcludedIDs(books: books, excludedRaw: "", includedRaw: "")
        XCTAssertEqual(defaults, [reference.id], "a reference text starts off, an ordinary book starts on")

        let optedIn = BookSourceFilter.effectiveExcludedIDs(
            books: books,
            excludedRaw: "",
            includedRaw: BookSourceFilter.encode([reference.id])
        )
        XCTAssertTrue(optedIn.isEmpty, "an explicit opt-in must fully reverse the default")

        let optedInThenOff = BookSourceFilter.effectiveExcludedIDs(
            books: books,
            excludedRaw: BookSourceFilter.encode([reference.id]),
            includedRaw: BookSourceFilter.encode([reference.id])
        )
        XCTAssertEqual(optedInThenOff, [reference.id], "an explicit exclusion outranks a stale opt-in")
    }

    /// Someone whose whole library is reference texts must not open Flow to an
    /// empty screen they never asked for.
    func testAllReferenceLibraryFallsBackToIncludingEverything() throws {
        let context = try makeContext()
        let first = Book(title: "Robbins", author: "A", contentProfile: .academicReference)
        let second = Book(title: "Microbiology", author: "B", contentProfile: .academicReference)
        context.insert(first)
        context.insert(second)

        XCTAssertTrue(
            BookSourceFilter.effectiveExcludedIDs(books: [first, second], excludedRaw: "", includedRaw: "").isEmpty,
            "a default that empties the feed must yield rather than hide the whole library"
        )

        // An explicit "switch everything off", though, is a real choice and
        // keeps its own honest empty state.
        let explicit = BookSourceFilter.encode([first.id, second.id])
        XCTAssertEqual(
            BookSourceFilter.effectiveExcludedIDs(books: [first, second], excludedRaw: explicit, includedRaw: ""),
            [first.id, second.id],
            "an explicit exclusion of every book must be honoured"
        )
    }

    /// The recap's "X has territory left" line should point at the book nearest
    /// to finished, not the one furthest behind.
    func testRecapNamesTheBookClosestToFinished() throws {
        let context = try makeContext()
        let nearlyDone = Book(title: "Almost", author: "A")
        context.insert(nearlyDone)
        let barelyStarted = Book(title: "Barely", author: "B")
        context.insert(barelyStarted)

        for (book, completed) in [(nearlyDone, 3), (barelyStarted, 0)] {
            for index in 0..<4 {
                let chapter = Chapter(title: "Ch \(index)", summary: "s")
                chapter.keyLessons = ["L"]
                chapter.isCompleted = index < completed
                chapter.book = book
                book.chapters.append(chapter)
            }
            let highlight = Highlight(text: "Quote from \(book.title)", chapter: nil, tags: [], isReminder: false)
            highlight.book = book
            context.insert(highlight)
            book.highlights.append(highlight)
        }

        var c = FlowQueueBuilder.BatchContinuation()
        let cards = FlowQueueBuilder.buildBatch(books: [nearlyDone, barelyStarted], batch: 0, seedBase: 8, continuation: &c)
        let nextBooks = cards.compactMap { card -> String? in
            if case .sessionRecap(_, _, let nextBook) = card { return nextBook }
            return nil
        }
        XCTAssertFalse(nextBooks.isEmpty)
        XCTAssertTrue(nextBooks.allSatisfy { $0 == "Almost" }, "the recap should name momentum, not the most-abandoned book")
    }

    func testRecentlyReviewedCardsAreExcludedFromClozeTeasers() throws {
        let context = try makeContext()
        let book = makeLibrary(context: context)
        let chapter = book.chapters[0]

        let fresh = QuizQuestion(book: book, chapter: chapter, questionType: .recallMCQ, prompt: "fresh", explanation: "e")
        fresh.choices = ["a", "b"]
        fresh.correctAnswerIndex = 0
        fresh.dueDate = Date().addingTimeInterval(-3600)
        context.insert(fresh)
        chapter.quizQuestions.append(fresh)

        let justReviewed = QuizQuestion(book: book, chapter: chapter, questionType: .recallMCQ, prompt: "just reviewed", explanation: "e")
        justReviewed.choices = ["a", "b"]
        justReviewed.correctAnswerIndex = 0
        justReviewed.dueDate = Date().addingTimeInterval(-3600)
        justReviewed.lastReviewedAt = Date().addingTimeInterval(-60 * 60) // 1h ago, inside the 12h guard
        context.insert(justReviewed)
        chapter.quizQuestions.append(justReviewed)

        var c = FlowQueueBuilder.BatchContinuation()
        let cards = FlowQueueBuilder.buildBatch(books: [book], batch: 0, seedBase: 7, continuation: &c)
        let clozePrompts = cards.compactMap { card -> String? in
            if case .clozeTeaser(let question) = card { return question.prompt }
            return nil
        }
        XCTAssertTrue(clozePrompts.contains("fresh"))
        XCTAssertFalse(clozePrompts.contains("just reviewed"), "12h re-review guard must hold")
    }
}
