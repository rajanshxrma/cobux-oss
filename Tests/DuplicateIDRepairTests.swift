import XCTest
import SwiftData
@testable import Cobux

/// Regression test for a real bug Rajan hit on a live device: `Chapter.init` never assigned
/// `self.id` explicitly (unlike every other model with the same `var id: UUID = UUID()`
/// pattern), so SwiftData's schema-level default meant every chapter shared one `id` --
/// collapsing `BookDetailView`'s chapter list down to showing only one chapter per book,
/// since SwiftUI's `ForEach`/`Identifiable` diffing treats same-`id` rows as the same item.
/// `Chapter.init` is now fixed going forward; this covers the data-repair side for chapters
/// (and the four other models -- `QuizQuestion`/`HighlightMemory`/`QuizAttempt`/
/// `QuizAnswerRecord` -- that already had the init-time fix but never got the backfill pass
/// `Book`/`Highlight`/`Theme` already had).
@MainActor
final class DuplicateIDRepairTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Book.self, Highlight.self, Chapter.self, ChatMessage.self,
            QuizQuestion.self, HighlightMemory.self, QuizAttempt.self, QuizAnswerRecord.self,
            configurations: config
        )
        return ModelContext(container)
    }

    func testDuplicateChapterIDsGetRepairedToUniqueValues() throws {
        let context = try makeContext()
        let book = Book(title: "Test Book", author: "Author")
        context.insert(book)

        let sharedID = UUID()
        let chapterA = Chapter(title: "Chapter 1", summary: "First")
        let chapterB = Chapter(title: "Chapter 2", summary: "Second")
        chapterA.id = sharedID
        chapterB.id = sharedID
        chapterA.book = book
        chapterB.book = book
        book.chapters.append(chapterA)
        book.chapters.append(chapterB)

        CobuxApp.repairDuplicateIDs(context: context)

        XCTAssertNotEqual(chapterA.id, chapterB.id, "duplicate chapter IDs must be repaired to unique values")
    }

    func testDuplicateQuizQuestionIDsGetRepairedToUniqueValues() throws {
        let context = try makeContext()
        let book = Book(title: "Test Book", author: "Author")
        context.insert(book)

        let sharedID = UUID()
        let questionA = QuizQuestion(book: book, chapter: nil, questionType: .recallMCQ, prompt: "Q1", choices: ["a", "b"], correctAnswerIndex: 0, explanation: "")
        let questionB = QuizQuestion(book: book, chapter: nil, questionType: .recallMCQ, prompt: "Q2", choices: ["a", "b"], correctAnswerIndex: 0, explanation: "")
        questionA.id = sharedID
        questionB.id = sharedID
        context.insert(questionA)
        context.insert(questionB)

        CobuxApp.repairDuplicateIDs(context: context)

        XCTAssertNotEqual(questionA.id, questionB.id, "duplicate quiz question IDs must be repaired to unique values")
    }

    func testUniqueIDsAreLeftUntouched() throws {
        let context = try makeContext()
        let book = Book(title: "Test Book", author: "Author")
        context.insert(book)

        let chapterA = Chapter(title: "Chapter 1", summary: "First")
        let chapterB = Chapter(title: "Chapter 2", summary: "Second")
        chapterA.book = book
        chapterB.book = book
        book.chapters.append(chapterA)
        book.chapters.append(chapterB)
        let originalIDA = chapterA.id
        let originalIDB = chapterB.id

        CobuxApp.repairDuplicateIDs(context: context)

        XCTAssertEqual(chapterA.id, originalIDA)
        XCTAssertEqual(chapterB.id, originalIDB)
    }

    func testFreshlyCreatedChaptersAlwaysGetDistinctIDs() {
        // Guards the actual root cause, not just the repair pass: Chapter.init must assign
        // self.id explicitly, same as every other model with this property-default pattern.
        let chapters = (0..<10).map { Chapter(title: "Chapter \($0)", summary: "Summary") }
        XCTAssertEqual(Set(chapters.map(\.id)).count, 10, "every freshly created Chapter must get its own unique id")
    }
}
