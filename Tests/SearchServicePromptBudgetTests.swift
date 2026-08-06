import XCTest
import SwiftData
@testable import Cobux

/// Guards against the exact regression that made a genuinely first chat
/// message (or any message after the ~5-minute prompt-cache TTL lapses)
/// able to time out on real devices: `buildSplitContext`'s stable prefix
/// silently grew from a titles-only index into every book's full chapter
/// summaries, and the empty-`unionBooks` fallback dumped every book's full
/// highlight set into the uncached dynamic section. Both are now bounded —
/// this test fails loudly the moment either bound regresses, rather than
/// waiting for another live-device timeout report to notice.
@MainActor
final class SearchServicePromptBudgetTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Book.self, Highlight.self, Chapter.self, ChatMessage.self, configurations: config)
        return ModelContext(container)
    }

    /// Simulates a library at well beyond today's real scale (20 books, 40
    /// chapters/book with realistic-length summaries, 60 highlights/book) so
    /// the budget guarantees hold as the library keeps growing, not just at
    /// today's size.
    private func makeLargeLibrary(in context: ModelContext) -> [Book] {
        (0..<20).map { bookIndex in
            let book = Book(title: "Reference Book \(bookIndex)", author: "Author \(bookIndex)")
            context.insert(book)

            for chapterIndex in 0..<40 {
                let chapter = Chapter(
                    title: "Chapter \(chapterIndex): A Realistically Long Chapter Title About Topic \(chapterIndex)",
                    summary: String(repeating: "This chapter covers a detailed clinical or conceptual topic in real depth. ", count: 20),
                    keyLessons: ["Lesson A about topic \(chapterIndex)", "Lesson B about topic \(chapterIndex)", "Lesson C about topic \(chapterIndex)"],
                    chapterNumber: chapterIndex
                )
                chapter.book = book
                book.chapters.append(chapter)
            }

            for highlightIndex in 0..<60 {
                let highlight = Highlight(
                    text: String(repeating: "A highlighted passage with real substance. ", count: 8) + "Highlight \(highlightIndex) of book \(bookIndex).",
                    chapter: "Chapter \(highlightIndex % 40)"
                )
                highlight.book = book
                book.highlights.append(highlight)
            }

            return book
        }
    }

    func testStablePrefixStaysTitlesOnlyEvenForALargeLibrary() throws {
        let context = try makeContext()
        let books = makeLargeLibrary(in: context)

        let (stable, _, _) = SearchService.buildSplitContext(query: "anything", books: books)

        // A titles-only index for 20 books × 40 chapters must stay small
        // regardless of how long chapter summaries/key lessons are — those
        // no longer live in the stable prefix at all. 60k is a generous
        // ceiling for 800 short chapter-title lines.
        XCTAssertLessThan(stable.count, 60_000, "stable prefix must stay a titles-only index, not grow with chapter summary length")
        XCTAssertFalse(stable.contains("This chapter covers a detailed"), "chapter summaries must not appear in the cached stable prefix")
        XCTAssertFalse(stable.contains("Lesson A about topic"), "key lessons must not appear in the cached stable prefix")
    }

    func testEmptyUnionFallbackStaysWithinDynamicBudget() throws {
        let context = try makeContext()
        let books = makeLargeLibrary(in: context)

        // A query that matches no title/author and has no embeddings set up
        // (the real first-message scenario, before background embedding
        // backfill completes) exercises the empty-`unionBooks` fallback —
        // the exact path that used to dump every book's full highlight set,
        // uncached, into a single turn.
        let (_, dynamic, _) = SearchService.buildSplitContext(query: "a totally unrelated vague query", books: books)

        XCTAssertLessThanOrEqual(dynamic.count, SearchService.dynamicContextCharBudget + 500, "dynamic section must respect the hard character budget even on the full-library fallback path")
    }

    func testEmptyUnionFallbackForSingleBookStaysWithinDynamicBudget() throws {
        let context = try makeContext()
        let books = makeLargeLibrary(in: context)
        let book = try XCTUnwrap(books.first)

        let (_, dynamic) = SearchService.buildSplitContextForBook(query: "a totally unrelated vague query", book: book)

        XCTAssertLessThanOrEqual(dynamic.count, SearchService.dynamicContextCharBudget + 500)
    }
}
