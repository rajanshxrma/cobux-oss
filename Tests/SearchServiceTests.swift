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
