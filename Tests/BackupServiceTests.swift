import XCTest
import SwiftData
@testable import Cobux

/// Regression coverage for a real, shipped gap: `QuizQuestion` (and the FSRS scheduling
/// state that lives on it since Phase 3) was entirely excluded from backup/restore, on the
/// stale theory that questions are "regeneratable" -- true of their content, false of the
/// FSRS progress earned by actually reviewing them. Since chapter regeneration deletes and
/// recreates every question in a chapter (see `QuizGenerationServiceTests`'s
/// `WipesPreviousBankOnRegeneration` test), a backup was the one thing that could have
/// protected that progress, and it didn't cover it at all.
@MainActor
final class BackupServiceTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Book.self, Chapter.self, Highlight.self, QuizQuestion.self, ChatMessage.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    func testQuizQuestionFSRSStateRoundTripsThroughExportAndImport() throws {
        let sourceContext = try makeContext()
        let book = Book(title: "Robbins & Cotran Pathologic Basis of Disease", author: "Kumar")
        sourceContext.insert(book)
        let chapter = Chapter(title: "Ch 1: Cell Injury", summary: "s")
        chapter.book = book
        book.chapters.append(chapter)
        let highlight = Highlight(text: "Apoptosis is programmed cell death.", chapter: "Ch 1: Cell Injury")
        highlight.book = book
        book.highlights.append(highlight)

        let question = QuizQuestion(
            book: book, chapter: chapter, questionType: .recallMCQ,
            prompt: "What triggers apoptosis?", choices: ["A", "B"], correctAnswerIndex: 0,
            explanation: "Because.", difficulty: 2, topicTags: ["apoptosis"]
        )
        question.sourceHighlights = [highlight]
        question.generationSourceRaw = "cloze"
        // Real, non-default FSRS state -- exactly what a backup exists to protect.
        question.fsrsStability = 12.5
        question.fsrsDifficulty = 4.2
        question.fsrsReps = 3
        question.fsrsLapses = 1
        question.lastReviewedAt = Date(timeIntervalSince1970: 1_700_000_000)
        question.dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        sourceContext.insert(question)
        chapter.quizQuestions.append(question)
        try sourceContext.save()

        let data = try BackupService.exportData(books: [book])

        // Restore into a fresh, empty store -- the "lost/wiped phone" scenario this exists for.
        let targetContext = try makeContext()
        let result = try BackupService.importData(data, existingBooks: [], modelContext: targetContext)

        XCTAssertEqual(result.quizQuestionsImported, 1)

        let restoredBooks = try targetContext.fetch(FetchDescriptor<Book>())
        let restoredQuestions = try targetContext.fetch(FetchDescriptor<QuizQuestion>())
        XCTAssertEqual(restoredBooks.count, 1)
        XCTAssertEqual(restoredQuestions.count, 1)

        let restored = try XCTUnwrap(restoredQuestions.first)
        XCTAssertEqual(restored.prompt, "What triggers apoptosis?")
        XCTAssertEqual(restored.fsrsStability, 12.5)
        XCTAssertEqual(restored.fsrsDifficulty, 4.2)
        XCTAssertEqual(restored.fsrsReps, 3)
        XCTAssertEqual(restored.fsrsLapses, 1)
        XCTAssertEqual(restored.lastReviewedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(restored.dueDate, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(restored.chapter?.title, "Ch 1: Cell Injury")
        XCTAssertEqual(restored.sourceHighlights.first?.text, "Apoptosis is programmed cell death.")
    }

    /// A book that already exists locally keeps its own live questions/progress untouched --
    /// same "skip, don't merge" rule as `HighlightMemory` restore, so importing an old backup
    /// can never stomp on newer local progress.
    func testExistingBookSkipsQuizQuestionImportEntirely() throws {
        let sourceContext = try makeContext()
        let book = Book(title: "Attached", author: "Amir Levine")
        sourceContext.insert(book)
        let chapter = Chapter(title: "Ch 1", summary: "s")
        chapter.book = book
        book.chapters.append(chapter)
        let question = QuizQuestion(book: book, chapter: chapter, questionType: .recallMCQ, prompt: "p", explanation: "e")
        question.fsrsReps = 5
        sourceContext.insert(question)
        chapter.quizQuestions.append(question)
        try sourceContext.save()
        let data = try BackupService.exportData(books: [book])

        let targetContext = try makeContext()
        let existingBook = Book(title: "Attached", author: "Amir Levine")
        targetContext.insert(existingBook)
        try targetContext.save()

        let result = try BackupService.importData(data, existingBooks: [existingBook], modelContext: targetContext)

        XCTAssertEqual(result.quizQuestionsImported, 0, "an already-existing book's questions must not be touched by import")
        XCTAssertEqual(try targetContext.fetch(FetchDescriptor<QuizQuestion>()).count, 0)
    }
}
