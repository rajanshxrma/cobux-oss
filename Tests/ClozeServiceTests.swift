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

    // MARK: Regression — correctAnswerIndex used to point into a DIFFERENT shuffle than `choices`

    /// `generateIfNeeded` used to call the private `shuffledChoices(answer:distractors:)`
    /// TWICE per card -- once building `choices`, once building `correctAnswerIndex` --
    /// and each call does its own independent `Int.random` shuffle. The index from call
    /// #2 almost never matched call #1's actual arrangement, so most on-device cloze MCQs
    /// were graded against the wrong answer, and that wrong grade fed straight into FSRS
    /// scheduling. The only way to actually catch this class of bug is to assert the
    /// stored index really does point at the real answer text inside the stored choices
    /// array -- a test that only checks "an index exists" would have passed on the buggy
    /// code too.
    func testCorrectAnswerIndexPointsAtTheRealAnswerInStoredChoices() throws {
        let context = ModelContext(try makeContainer())
        let book = Book(title: "Test Book", author: "Author")
        context.insert(book)
        let chapter = Chapter(title: "Chapter 1", summary: "")
        chapter.book = book
        book.chapters.append(chapter)

        // Multiple similarly-shaped highlights so ClozeGenerator has real distractor
        // material to work with -- a single highlight with no siblings tends to produce
        // free-recall cards only, which have no `choices`/`correctAnswerIndex` at all.
        let highlights = [
            Highlight(text: "Apoptosis is programmed cell death — mediated by caspases and triggered by DNA damage.", chapter: "Chapter 1", tags: ["apoptosis", "programmed cell death"]),
            Highlight(text: "Necrosis is uncontrolled cell death — caused by injury, triggering inflammation.", chapter: "Chapter 1", tags: ["necrosis", "cell death"]),
            Highlight(text: "Autophagy is programmed self-digestion — a cell recycling its own damaged components.", chapter: "Chapter 1", tags: ["autophagy", "programmed"])
        ]
        for highlight in highlights {
            highlight.book = book
            book.highlights.append(highlight)
        }
        try? context.save()

        ClozeService.generateIfNeeded(for: chapter, in: book, modelContext: context)

        let mcqCards = chapter.quizQuestions.filter { $0.generationSourceRaw == "cloze" && !$0.choices.isEmpty }
        XCTAssertFalse(mcqCards.isEmpty, "this fixture should produce at least one recall MCQ card, not only free-recall")

        for question in mcqCards {
            guard let index = question.correctAnswerIndex else {
                XCTFail("an MCQ card (non-empty choices) must have a correctAnswerIndex")
                continue
            }
            XCTAssertTrue(question.choices.indices.contains(index), "correctAnswerIndex must be a valid index into choices")

            // `explanation` is always "Answer: <the real answer>" -- the ground truth this
            // bug corrupted. The stored index must point at THAT exact text, not just any
            // valid index.
            XCTAssertTrue(question.explanation.hasPrefix("Answer: "))
            let realAnswer = String(question.explanation.dropFirst("Answer: ".count))
            XCTAssertEqual(question.choices[index], realAnswer, "correctAnswerIndex pointed at a different choice than the actual answer — this is the double-shuffle mis-grading bug")
        }
    }
}
