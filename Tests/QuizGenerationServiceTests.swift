import XCTest
import SwiftData
@testable import Cobux

/// Covers the pure decode/apply logic Phase 4's generation pipeline shares
/// between the live per-chapter call (`QuizGenerationService.generateQuestions`)
/// and the background Batch API path (`BatchGenerationService`) --
/// `applyGeneratedQuestions` is the one place a structured-output response
/// actually becomes `QuizQuestion` rows, so both paths inherit whatever this
/// covers. No network involved; the response text stands in for what
/// Claude's structured-output JSON schema guarantees the shape of.
@MainActor
final class QuizGenerationServiceTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Book.self, Highlight.self, Chapter.self, QuizQuestion.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func seedChapterWithHighlights(in context: ModelContext) -> (book: Book, chapter: Chapter) {
        let book = Book(title: "Test Book", author: "Author")
        context.insert(book)
        let chapter = Chapter(title: "Chapter 1", summary: "")
        chapter.book = book
        book.chapters.append(chapter)

        let h0 = Highlight(text: "Fact one.", chapter: "Chapter 1")
        let h1 = Highlight(text: "Fact two.", chapter: "Chapter 1")
        h0.book = book
        h1.book = book
        book.highlights.append(contentsOf: [h0, h1])
        try? context.save()
        return (book, chapter)
    }

    func testApplyGeneratedQuestionsDecodesStructuredResponseIntoQuizQuestions() throws {
        let context = ModelContext(try makeContainer())
        let (book, chapter) = seedChapterWithHighlights(in: context)

        let responseJSON = """
        {"questions": [
            {"questionType": "recallMCQ", "prompt": "What is fact one?", "choices": ["A", "B"], "correctAnswerIndex": 0, "explanation": "Because.", "difficulty": 1, "topicTags": ["tag"], "sourceHighlightIndexes": [0]}
        ]}
        """

        let inserted = try QuizGenerationService.applyGeneratedQuestions(from: responseJSON, to: chapter, in: book, modelContext: context)

        XCTAssertEqual(inserted, 1)
        XCTAssertEqual(chapter.quizQuestions.count, 1)
        XCTAssertEqual(chapter.quizQuestions.first?.prompt, "What is fact one?")
        XCTAssertEqual(chapter.quizQuestions.first?.sourceHighlights.first?.text, "Fact one.")
        XCTAssertEqual(chapter.quizGenerationHash, QuizGenerationService.contentHash(for: chapter, in: book), "applying a response must mark the chapter as generated for its current content hash")
    }

    func testApplyGeneratedQuestionsWipesPreviousBankOnRegeneration() throws {
        let context = ModelContext(try makeContainer())
        let (book, chapter) = seedChapterWithHighlights(in: context)

        let firstPass = """
        {"questions": [{"questionType": "recallMCQ", "prompt": "Old question", "choices": ["A"], "correctAnswerIndex": 0, "explanation": "x", "difficulty": 1, "topicTags": [], "sourceHighlightIndexes": [0]}]}
        """
        try QuizGenerationService.applyGeneratedQuestions(from: firstPass, to: chapter, in: book, modelContext: context)
        XCTAssertEqual(chapter.quizQuestions.count, 1)

        let secondPass = """
        {"questions": [
            {"questionType": "recallMCQ", "prompt": "New question A", "choices": ["A"], "correctAnswerIndex": 0, "explanation": "x", "difficulty": 1, "topicTags": [], "sourceHighlightIndexes": [0]},
            {"questionType": "recallMCQ", "prompt": "New question B", "choices": ["A"], "correctAnswerIndex": 0, "explanation": "x", "difficulty": 1, "topicTags": [], "sourceHighlightIndexes": [1]}
        ]}
        """
        try QuizGenerationService.applyGeneratedQuestions(from: secondPass, to: chapter, in: book, modelContext: context)

        XCTAssertEqual(chapter.quizQuestions.count, 2, "regenerating must replace the old bank, not append to it")
        XCTAssertFalse(chapter.quizQuestions.contains { $0.prompt == "Old question" })
    }

    func testApplyGeneratedQuestionsThrowsOnMalformedJSON() throws {
        let context = ModelContext(try makeContainer())
        let (book, chapter) = seedChapterWithHighlights(in: context)

        XCTAssertThrowsError(
            try QuizGenerationService.applyGeneratedQuestions(from: "not json", to: chapter, in: book, modelContext: context)
        ) { error in
            XCTAssertTrue(error is QuizGenerationError)
        }
    }

    func testApplyGeneratedQuestionsHandlesApplicationTypeWithNullCorrectAnswer() throws {
        // Reflective-book "application" questions have no fixed correct
        // choice -- structured output must still round-trip a null cleanly.
        let context = ModelContext(try makeContainer())
        let (book, chapter) = seedChapterWithHighlights(in: context)

        let responseJSON = """
        {"questions": [{"questionType": "application", "prompt": "How would you apply this?", "choices": [], "correctAnswerIndex": null, "explanation": "Self-assess.", "difficulty": 1, "topicTags": [], "sourceHighlightIndexes": [0, 1]}]}
        """
        try QuizGenerationService.applyGeneratedQuestions(from: responseJSON, to: chapter, in: book, modelContext: context)

        let question = try XCTUnwrap(chapter.quizQuestions.first)
        XCTAssertNil(question.correctAnswerIndex)
        XCTAssertEqual(question.sourceHighlights.count, 2)
    }

    func testOutOfRangeSourceHighlightIndexesAreSkippedNotCrashed() throws {
        let context = ModelContext(try makeContainer())
        let (book, chapter) = seedChapterWithHighlights(in: context)

        let responseJSON = """
        {"questions": [{"questionType": "recallMCQ", "prompt": "Q", "choices": ["A"], "correctAnswerIndex": 0, "explanation": "x", "difficulty": 1, "topicTags": [], "sourceHighlightIndexes": [0, 99]}]}
        """
        try QuizGenerationService.applyGeneratedQuestions(from: responseJSON, to: chapter, in: book, modelContext: context)

        let question = try XCTUnwrap(chapter.quizQuestions.first)
        XCTAssertEqual(question.sourceHighlights.count, 1, "an out-of-range index (a model hallucination) must be dropped, not crash")
    }

    // MARK: - Chapter.id (new field added for BatchGenerationService)

    func testEachChapterGetsAUniqueStableID() throws {
        let context = ModelContext(try makeContainer())
        let book = Book(title: "Test Book", author: "Author")
        context.insert(book)
        let chapterA = Chapter(title: "A", summary: "")
        let chapterB = Chapter(title: "B", summary: "")
        chapterA.book = book
        chapterB.book = book
        book.chapters.append(contentsOf: [chapterA, chapterB])
        try context.save()

        XCTAssertNotEqual(chapterA.id, chapterB.id)

        let targetID = chapterA.id
        let refetched = try XCTUnwrap(try context.fetch(FetchDescriptor<Chapter>(predicate: #Predicate { $0.id == targetID })).first)
        XCTAssertEqual(refetched.title, "A", "a chapter must be resolvable by its own id after a save -- BatchGenerationService relies on exactly this to match a finished batch item back to its chapter")
    }
}
