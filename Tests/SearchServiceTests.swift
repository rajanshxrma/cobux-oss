import XCTest
import SwiftData
@testable import Cobux

@MainActor
final class SearchServiceTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Book.self, Highlight.self, Chapter.self, ChatMessage.self, configurations: config)
        return ModelContext(container)
    }

    private func makeBook(_ title: String, author: String, in context: ModelContext) -> Book {
        let book = Book(title: title, author: author)
        context.insert(book)
        let highlight = Highlight(text: "A highlight from \(title).", chapter: "Chapter 1")
        highlight.book = book
        book.highlights.append(highlight)
        let chapter = Chapter(title: "Chapter 1", summary: "Summary of \(title).", keyLessons: ["Lesson"], chapterNumber: 1)
        chapter.book = book
        book.chapters.append(chapter)
        return book
    }

    func testEmptyLibraryReturnsPlaceholderAndNoTitles() {
        let result = SearchService.buildContext(query: "anything", books: [])
        XCTAssertEqual(result.context, "No books in library yet.")
        XCTAssertTrue(result.bookTitles.isEmpty)
    }

    func testQueryMatchingOneTitleIncludesOnlyThatBookInFull() throws {
        let context = try makeContext()
        let matched = makeBook("Beyond Order", author: "Jordan B. Peterson", in: context)
        let other = makeBook("12 Rules for Life", author: "Jordan B. Peterson", in: context)

        let result = SearchService.buildContext(query: "What does Beyond Order say about ideology?", books: [matched, other])

        XCTAssertEqual(result.bookTitles, ["Beyond Order"])
        XCTAssertTrue(result.context.contains("A highlight from Beyond Order."))
        XCTAssertFalse(result.context.contains("A highlight from 12 Rules for Life."))
        // The unmatched book is still listed so the model knows it exists.
        XCTAssertTrue(result.context.contains("Other books in library"))
        XCTAssertTrue(result.context.contains("12 Rules for Life"))
    }

    func testQueryMatchingNothingFallsBackToAllBooksButCitesNone() throws {
        let context = try makeContext()
        let bookA = makeBook("Beyond Order", author: "Jordan B. Peterson", in: context)
        let bookB = makeBook("12 Rules for Life", author: "Jordan B. Peterson", in: context)

        let result = SearchService.buildContext(query: "How do I deal with resentment at work?", books: [bookA, bookB])

        // Context still gets every book (the model needs something to work
        // with on a vague query), but per the citation rewrite (6a6c0d3),
        // nothing is reported as "cited" when nothing was actually matched —
        // citing a book as referenced when it didn't genuinely contribute to
        // this turn would be misleading in the UI.
        XCTAssertTrue(result.bookTitles.isEmpty)
        XCTAssertTrue(result.context.contains("A highlight from Beyond Order."))
        XCTAssertTrue(result.context.contains("A highlight from 12 Rules for Life."))
        XCTAssertFalse(result.context.contains("Other books in library"))
    }

    func testChapterSummariesAndLessonsAppearInContext() throws {
        let context = try makeContext()
        let book = makeBook("Beyond Order", author: "Jordan B. Peterson", in: context)

        let result = SearchService.buildContext(query: "unrelated", books: [book])

        XCTAssertTrue(result.context.contains("Summary of Beyond Order."))
        XCTAssertTrue(result.context.contains("Key lessons: Lesson"))
    }

    // MARK: Semantic ranking parity

    /// Deterministic pseudo-random vectors, distinct per seed, so no two rows
    /// tie -- ties are the one thing the relationship pool and the probe's
    /// table are allowed to order differently (see `SearchService.rankedHits`).
    private func vector(seed: Int, dimension: Int = 8) -> [Float] {
        var state = UInt64(seed &+ 1) &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return (0..<dimension).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24) - 0.5
        }
    }

    /// `SemanticSearchProbe.buildTable()` must yield exactly the pool
    /// `books.flatMap(\.highlights)` did -- same rows, same book grouping,
    /// same skips (a row with no vector, a row with the backfill's empty
    /// marker) -- and both must rank through `rankedHits` to the same ids in
    /// the same order with the same scores. This is the claim that lets the
    /// synchronous chat path and the off-main Library path share one ranking.
    func testProbeTableRanksIdenticallyToRelationshipPool() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Book.self, Highlight.self, Chapter.self, ChatMessage.self, configurations: config)
        let context = ModelContext(container)

        var books: [Book] = []
        var seed = 0
        for title in ["Beyond Order", "12 Rules for Life", "The Art of Seduction"] {
            let book = Book(title: title, author: "Author")
            context.insert(book)
            for n in 0..<7 {
                let highlight = Highlight(text: "\(title) line \(n)")
                highlight.book = book
                book.highlights.append(highlight)
                highlight.embedding = vector(seed: seed)
                seed += 1
            }
            // Skipped by both pools: no vector yet, and the empty "nothing to
            // index" marker.
            let unembedded = Highlight(text: "\(title) not yet embedded")
            unembedded.book = book
            book.highlights.append(unembedded)
            let marker = Highlight(text: "\(title) nothing to index")
            marker.book = book
            book.highlights.append(marker)
            marker.embedding = []
            books.append(book)
        }
        try context.save()

        let query = vector(seed: 999)
        let fromRelationships = SearchService.rankedHits(
            queryVector: query, highlights: books.flatMap(\.highlights), topK: 5)

        let table = await SemanticSearchProbe(modelContainer: container).buildTable()
        XCTAssertEqual(table.entries.count, 21, "seven embedded rows per book, the two unscorable rows skipped")
        let scope = Set(books.map(\.id))
        let fromTable = SearchService.rankedHits(
            queryVector: query, entries: table.entries(inBooks: scope), topK: 5)

        XCTAssertFalse(fromRelationships.isEmpty)
        XCTAssertEqual(fromRelationships, fromTable)

        // Scoping the table to one book is the same pool `books: [one]` was.
        let one = books[1]
        XCTAssertEqual(
            SearchService.rankedHits(queryVector: query, entries: table.entries(inBooks: [one.id]), topK: 5),
            SearchService.rankedHits(queryVector: query, highlights: one.highlights, topK: 5))

        // And the synchronous entry point hands back those rows, in that order.
        let rows = SearchService.semanticSearch(queryVector: query, books: books, topK: 5)
        XCTAssertEqual(rows.map(\.id), fromRelationships.map(\.id))
    }
}

@MainActor
final class SeedDataTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Book.self, Highlight.self, Chapter.self, ChatMessage.self, configurations: config)
        return ModelContext(container)
    }

    func testSeedsAreIdempotent() throws {
        let context = try makeContext()

        SeedData.seed12Rules(modelContext: context)
        SeedData.seedBeyondOrder(modelContext: context)
        SeedData.seed12Rules(modelContext: context)
        SeedData.seedBeyondOrder(modelContext: context)

        let books = try context.fetch(FetchDescriptor<Book>())
        XCTAssertEqual(books.count, 2)
    }

    func testBeyondOrderSeedHasTwelveChaptersAndHighlights() throws {
        let context = try makeContext()
        SeedData.seedBeyondOrder(modelContext: context)

        let fetch = FetchDescriptor<Book>(predicate: #Predicate { $0.title == "Beyond Order" })
        let book = try XCTUnwrap(try context.fetch(fetch).first)

        XCTAssertEqual(book.author, "Jordan B. Peterson")
        XCTAssertEqual(book.chapters.count, 12)
        XCTAssertEqual(book.highlights.count, 12)
        XCTAssertEqual(Set(book.chapters.compactMap(\.chapterNumber)), Set(1...12))
    }
}
