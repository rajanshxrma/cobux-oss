import XCTest
import SwiftData
@testable import Cobux

@MainActor
final class DailyReviewServiceTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Book.self, Chapter.self, QuizQuestion.self, configurations: config)
        return ModelContext(container)
    }

    private func makeQuestion(due: Date?, reps: Int, suspended: Bool = false, in chapter: Chapter, book: Book, context: ModelContext) -> QuizQuestion {
        let q = QuizQuestion(book: book, chapter: chapter, questionType: .recallMCQ, prompt: "p", explanation: "e")
        q.dueDate = due
        q.fsrsReps = reps
        q.isSuspended = suspended
        context.insert(q)
        chapter.quizQuestions.append(q)
        return q
    }

    func testDueQuestionsOnlyIncludesPastOrPresentDueDates() throws {
        let context = try makeContext()
        let book = Book(title: "Robbins & Cotran Pathologic Basis of Disease", author: "Kumar")
        context.insert(book)
        let chapter = Chapter(title: "Ch 1", summary: "s")
        chapter.book = book
        book.chapters.append(chapter)

        let overdue = makeQuestion(due: Date().addingTimeInterval(-86400), reps: 1, in: chapter, book: book, context: context)
        let future = makeQuestion(due: Date().addingTimeInterval(86400), reps: 1, in: chapter, book: book, context: context)
        let neverIntroduced = makeQuestion(due: nil, reps: 0, in: chapter, book: book, context: context)

        let due = DailyReviewService.dueQuestions(in: [book])
        XCTAssertTrue(due.contains { $0.id == overdue.id })
        XCTAssertFalse(due.contains { $0.id == future.id })
        XCTAssertFalse(due.contains { $0.id == neverIntroduced.id }, "nil dueDate means never introduced, not 'always due'")
    }

    func testSuspendedQuestionsAreExcludedEvenIfDue() throws {
        let context = try makeContext()
        let book = Book(title: "Attached", author: "Amir Levine")
        context.insert(book)
        let chapter = Chapter(title: "Ch 1", summary: "s")
        chapter.book = book
        book.chapters.append(chapter)

        let suspended = makeQuestion(due: Date().addingTimeInterval(-100), reps: 5, suspended: true, in: chapter, book: book, context: context)

        let due = DailyReviewService.dueQuestions(in: [book])
        XCTAssertFalse(due.contains { $0.id == suspended.id })
    }

    func testDueQuestionsSpansMultipleBooks() throws {
        let context = try makeContext()
        let bookA = Book(title: "12 Rules for Life", author: "Jordan Peterson")
        let bookB = Book(title: "Essentials of Medical Microbiology", author: "Sastry")
        context.insert(bookA)
        context.insert(bookB)
        let chapterA = Chapter(title: "Ch 1", summary: "s")
        chapterA.book = bookA
        bookA.chapters.append(chapterA)
        let chapterB = Chapter(title: "Ch 1", summary: "s")
        chapterB.book = bookB
        bookB.chapters.append(chapterB)

        _ = makeQuestion(due: .now, reps: 1, in: chapterA, book: bookA, context: context)
        _ = makeQuestion(due: .now, reps: 1, in: chapterB, book: bookB, context: context)

        XCTAssertEqual(DailyReviewService.dueQuestions(in: [bookA, bookB]).count, 2, "Daily Review must span every book, not just one")
    }

    func testBudgetedQueueCapsNewAndReviewSeparately() {
        let newQuestions = (0..<50).map { _ in
            let q = QuizQuestion(book: nil, chapter: nil, questionType: .recallMCQ, prompt: "p", explanation: "e")
            q.fsrsReps = 0
            return q
        }
        let reviewQuestions = (0..<200).map { _ in
            let q = QuizQuestion(book: nil, chapter: nil, questionType: .recallMCQ, prompt: "p", explanation: "e")
            q.fsrsReps = 3
            return q
        }

        let queue = DailyReviewService.budgetedQueue(from: newQuestions + reviewQuestions, newPerDay: 20, reviewsPerDay: 120)

        let newCount = queue.filter { $0.fsrsReps == 0 }.count
        let reviewCount = queue.filter { $0.fsrsReps > 0 }.count
        XCTAssertEqual(newCount, 20, "must not exceed the daily new-card budget even with 50 available")
        XCTAssertEqual(reviewCount, 120, "must not exceed the daily review budget even with 200 available")
        XCTAssertEqual(queue.count, 140)
    }

    func testBudgetedQueueNeverExceedsWhatsAvailable() {
        let onlyThree = (0..<3).map { _ -> QuizQuestion in
            let q = QuizQuestion(book: nil, chapter: nil, questionType: .recallMCQ, prompt: "p", explanation: "e")
            q.fsrsReps = 0
            return q
        }
        let queue = DailyReviewService.budgetedQueue(from: onlyThree, newPerDay: 20, reviewsPerDay: 120)
        XCTAssertEqual(queue.count, 3, "must not pad the queue beyond what's actually available")
    }
}
