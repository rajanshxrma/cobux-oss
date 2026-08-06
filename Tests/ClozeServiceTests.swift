import XCTest
import SwiftData
@testable import Cobux

/// Regression coverage for a real, shipped bug: `ClozeService.generateIfNeeded` inserted
/// every free-tier cloze card with `dueDate == nil`, so `DailyReviewService.dueQuestions`
/// (which filters on a non-nil dueDate) never surfaced a single one -- the ~5,000 free cards
/// this service exists to generate were permanently invisible to Daily Review, the app's
/// flagship home mode.
@MainActor
final class ClozeServiceTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Book.self, Highlight.self, Chapter.self, QuizQuestion.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    func testGenerateIfNeededSetsDueDateSoDailyReviewCanSeeFreeCards() throws {
        let context = ModelContext(try makeContainer())
        let book = Book(title: "Test Book", author: "Author")
        context.insert(book)
        // Book.contentProfile defaults to .propositional, which is cloze-eligible.
        let chapter = Chapter(title: "Chapter 1", summary: "")
        chapter.book = book
        book.chapters.append(chapter)

        // Needs the "headword — body" shape ClozeGenerator.splitHeadwordBody looks for,
        // plus tags so scoredCandidates has something to pick from.
        let highlight = Highlight(
            text: "Apoptosis is programmed cell death — mediated by caspases and triggered by DNA damage or receptor signaling.",
            chapter: "Chapter 1",
            tags: ["apoptosis", "caspase", "programmed cell death"]
        )
        highlight.book = book
        book.highlights.append(highlight)
        try? context.save()

        ClozeService.generateIfNeeded(for: chapter, in: book, modelContext: context)

        let generated = chapter.quizQuestions.filter { $0.generationSourceRaw == "cloze" }
        XCTAssertFalse(generated.isEmpty, "a cloze-eligible highlight with tags should produce at least one card")
        for question in generated {
            XCTAssertNotNil(question.dueDate, "a freshly generated cloze card must have a dueDate or Daily Review can never surface it")
            XCTAssertEqual(question.fsrsReps, 0, "a freshly generated card is a new card, not yet reviewed")
        }
        let dueIDs = Set(DailyReviewService.dueQuestions(in: [book]).map(\.id))
        for question in generated {
            XCTAssertTrue(dueIDs.contains(question.id), "freshly generated cloze cards must actually appear in Daily Review's due set")
        }
    }
}
