import XCTest
import SwiftData
@testable import Cobux

/// Guards the one non-negotiable constraint of the 2.0.0 release: "I don't want the
/// Cobux app with our new builds to lose our previous chats." Covers the two real ways
/// data could be lost across an upgrade — (1) the store itself persisting correctly
/// across app launches, and (2) the manual backup/restore path added this cycle, since
/// restoring a backup used to silently wipe chat history and quiz review progress.
@MainActor
final class MigrationTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Book.self, Highlight.self, Chapter.self, ChatMessage.self, Theme.self, Figure.self,
            QuizQuestion.self, HighlightMemory.self, QuizAttempt.self, QuizAnswerRecord.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    /// Builds a store shaped like a real pre-2.0.0 install: a book with a chapter and a
    /// highlight, a general chat thread message, a book-scoped chat thread message, and
    /// spaced-repetition progress on the highlight (the exact shape `HighlightMemory` has
    /// held since it shipped, unrelated to any 2.0.0 model change).
    private func seedRealisticInstall(in context: ModelContext) -> (book: Book, highlight: Highlight) {
        let book = Book(title: "Attached", author: "Amir Levine", coverColorHex: "#7C6BA6")
        context.insert(book)

        let chapter = Chapter(title: "Chapter 1", summary: "Attachment styles.", keyLessons: ["Secure vs anxious vs avoidant"], chapterNumber: 1)
        chapter.book = book
        book.chapters.append(chapter)

        let highlight = Highlight(text: "Anxious attachment involves a fear of abandonment.", chapter: "Chapter 1", tags: ["attachment", "anxiety"])
        highlight.book = book
        book.highlights.append(highlight)

        let memory = HighlightMemory(highlight: highlight)
        memory.box = 3
        memory.timesSeen = 5
        memory.timesCorrect = 4
        memory.consecutiveCorrect = 2
        memory.lastConfidenceRaw = 3
        highlight.memory = memory
        context.insert(memory)

        let generalMessage = ChatMessage(content: "How do I stop being so anxious in relationships?", isUser: true, bookID: nil)
        context.insert(generalMessage)
        let bookScopedMessage = ChatMessage(
            content: "Naming the anxiety directly helps.",
            isUser: false,
            referencedBooks: ["Attached"],
            bookID: book.id
        )
        context.insert(bookScopedMessage)

        try? context.save()
        return (book, highlight)
    }

    // MARK: In-place persistence — the store itself survives a "relaunch"

    func testExistingDataSurvivesReopeningTheSameStore() throws {
        let container = try makeContainer()
        let writeContext = ModelContext(container)
        let (book, _) = seedRealisticInstall(in: writeContext)
        let bookID = book.id

        // A fresh ModelContext against the same container is the in-memory equivalent
        // of relaunching the app against the same on-disk store.
        let readContext = ModelContext(container)

        let books = try readContext.fetch(FetchDescriptor<Book>())
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.title, "Attached")
        XCTAssertEqual(books.first?.highlights.count, 1)
        XCTAssertEqual(books.first?.chapters.count, 1)

        let messages = try readContext.fetch(FetchDescriptor<ChatMessage>())
        XCTAssertEqual(messages.count, 2, "both the general-thread and book-scoped chat messages must survive")
        XCTAssertTrue(messages.contains { $0.bookID == nil && $0.isUser })
        XCTAssertTrue(messages.contains { $0.bookID == bookID && !$0.isUser })

        let memories = try readContext.fetch(FetchDescriptor<HighlightMemory>())
        XCTAssertEqual(memories.count, 1)
        XCTAssertEqual(memories.first?.box, 3)
        XCTAssertEqual(memories.first?.timesSeen, 5)
    }

    // MARK: Backup round-trip — the actual restore path a user would use

    func testBackupRoundTripPreservesChatHistoryAndReviewProgress() throws {
        let sourceContainer = try makeContainer()
        let sourceContext = ModelContext(sourceContainer)
        let (_, sourceHighlight) = seedRealisticInstall(in: sourceContext)

        let books = try sourceContext.fetch(FetchDescriptor<Book>())
        let messages = try sourceContext.fetch(FetchDescriptor<ChatMessage>())
        let data = try BackupService.exportData(books: books, chatMessages: messages)

        // Restoring onto a completely empty store — the real "lost/wiped phone" scenario.
        let destContainer = try makeContainer()
        let destContext = ModelContext(destContainer)
        let result = try BackupService.importData(data, existingBooks: [], existingChatMessages: [], modelContext: destContext)

        XCTAssertEqual(result.booksImported, 1)
        XCTAssertEqual(result.chatMessagesImported, 2, "restoring a backup must not drop chat history")
        XCTAssertEqual(result.highlightMemoriesImported, 1, "restoring a backup must not drop earned spaced-repetition progress")

        let restoredMessages = try destContext.fetch(FetchDescriptor<ChatMessage>())
        XCTAssertEqual(restoredMessages.count, 2)
        XCTAssertTrue(restoredMessages.contains { $0.content == "How do I stop being so anxious in relationships?" })

        let restoredBookScoped = restoredMessages.first { !$0.isUser }
        XCTAssertNotNil(restoredBookScoped?.bookID, "a book-scoped message must resolve to the restored book's NEW id, not remain nil or point at the old one")

        let restoredMemories = try destContext.fetch(FetchDescriptor<HighlightMemory>())
        XCTAssertEqual(restoredMemories.count, 1)
        XCTAssertEqual(restoredMemories.first?.box, sourceHighlight.memory?.box)
        XCTAssertEqual(restoredMemories.first?.timesSeen, 5)
        XCTAssertEqual(restoredMemories.first?.timesCorrect, 4)
    }

    func testReimportingTheSameBackupTwiceDoesNotDuplicateAnything() throws {
        let sourceContainer = try makeContainer()
        let sourceContext = ModelContext(sourceContainer)
        _ = seedRealisticInstall(in: sourceContext)
        let books = try sourceContext.fetch(FetchDescriptor<Book>())
        let messages = try sourceContext.fetch(FetchDescriptor<ChatMessage>())
        let data = try BackupService.exportData(books: books, chatMessages: messages)

        let destContainer = try makeContainer()
        let destContext = ModelContext(destContainer)
        _ = try BackupService.importData(data, existingBooks: [], existingChatMessages: [], modelContext: destContext)

        let existingBooksNow = try destContext.fetch(FetchDescriptor<Book>())
        let existingMessagesNow = try destContext.fetch(FetchDescriptor<ChatMessage>())
        let second = try BackupService.importData(data, existingBooks: existingBooksNow, existingChatMessages: existingMessagesNow, modelContext: destContext)

        XCTAssertEqual(second.booksImported, 0)
        XCTAssertEqual(second.chatMessagesImported, 0)
        XCTAssertEqual(second.highlightMemoriesImported, 0)

        let finalMessages = try destContext.fetch(FetchDescriptor<ChatMessage>())
        XCTAssertEqual(finalMessages.count, 2, "a repeat import must never duplicate chat history")
    }

    func testPre2_0_0BackupWithoutChatOrMemoryKeysStillDecodes() throws {
        // Exactly what a real 1.2.0-era export file looked like -- no
        // "chatMessages"/"highlightMemories" keys at all.
        let legacyJSON = """
        {
          "exportDate": "2026-07-01T00:00:00Z",
          "books": [
            {
              "title": "Attached",
              "author": "Amir Levine",
              "coverColorHex": "#7C6BA6",
              "dateAdded": "2026-07-01T00:00:00Z",
              "chapters": [],
              "highlights": []
            }
          ]
        }
        """
        let container = try makeContainer()
        let context = ModelContext(container)
        let result = try BackupService.importData(Data(legacyJSON.utf8), existingBooks: [], modelContext: context)
        XCTAssertEqual(result.booksImported, 1)
        XCTAssertEqual(result.chatMessagesImported, 0)
        XCTAssertEqual(result.highlightMemoriesImported, 0)
    }

    // MARK: - Pre-2.0.0 quiz progress must reach Daily Review, not just chapter-scoped quizzing

    /// Reproduces the real bug found post-2.0.0-ship: a question generated before FSRS shipped
    /// has `dueDate == nil` and real Leitner box progress on its source highlight, but
    /// `FSRSService.migrateIfNeeded` only ever ran from inside `recordReview` — so until the
    /// bulk pass in `CobuxApp.migrateLeitnerProgressToFSRS` existed, this exact shape was
    /// invisible to `DailyReviewService.dueQuestions` (which requires a non-nil `dueDate`)
    /// until the user happened to review it via a chapter/book-scoped quiz first. That
    /// contradicted 2.0.0's own changelog claim that progress "carried over automatically."
    func testPre2_0_0QuestionIsInvisibleToDailyReviewBeforeBulkMigration() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let book = Book(title: "Attached", author: "Amir Levine", coverColorHex: "#7C6BA6")
        context.insert(book)
        let highlight = Highlight(text: "Anxious attachment.", chapter: "Chapter 1")
        highlight.book = book
        book.highlights.append(highlight)
        let memory = HighlightMemory(highlight: highlight)
        memory.box = 3
        context.insert(memory)

        let question = QuizQuestion(book: book, chapter: nil, questionType: .recallMCQ, prompt: "What is anxious attachment?", explanation: "x")
        question.sourceHighlights = [highlight]
        context.insert(question)
        // The exact shape a real pre-2.0.0 question has: never scheduled under FSRS.
        XCTAssertNil(question.dueDate)

        XCTAssertTrue(DailyReviewService.dueQuestions(in: [book]).isEmpty, "an unmigrated question must not silently vanish, but it also must not be spuriously due before migration runs")
    }

    func testBulkMigrationMakesPreexistingProgressVisibleToDailyReviewWithoutAnyReviewHappening() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let book = Book(title: "Attached", author: "Amir Levine", coverColorHex: "#7C6BA6")
        context.insert(book)
        let chapter = Chapter(title: "Chapter 1", summary: "s")
        chapter.book = book
        book.chapters.append(chapter)
        let highlight = Highlight(text: "Anxious attachment.", chapter: "Chapter 1")
        highlight.book = book
        book.highlights.append(highlight)
        let memory = HighlightMemory(highlight: highlight)
        memory.box = 3
        context.insert(memory)

        // DailyReviewService.dueQuestions reaches questions via books.flatMap(\.chapters)
        // .flatMap(\.quizQuestions) -- a question only linked via .book/.sourceHighlights
        // (as every real question created by QuizGenerationService/ClozeService never is,
        // both always set a real chapter) would be invisible to it regardless of dueDate.
        let question = QuizQuestion(book: book, chapter: chapter, questionType: .recallMCQ, prompt: "What is anxious attachment?", explanation: "x")
        question.sourceHighlights = [highlight]
        context.insert(question)
        chapter.quizQuestions.append(question)

        CobuxApp.migrateLeitnerProgressToFSRS(context: context)

        XCTAssertNotNil(question.dueDate, "the bulk pass must seed a dueDate without needing the question to be individually reviewed first")
        XCTAssertEqual(DailyReviewService.dueQuestions(in: [book]).count, 1, "migrated progress must actually surface in Daily Review, the flagship entry point -- not just become reachable via chapter-scoped quizzing")
    }

    func testBulkMigrationIsIdempotentAndDoesNotDisturbAlreadyMigratedQuestions() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let book = Book(title: "Attached", author: "Amir Levine", coverColorHex: "#7C6BA6")
        context.insert(book)
        let question = QuizQuestion(book: book, chapter: nil, questionType: .recallMCQ, prompt: "Already-scheduled question.", explanation: "x")
        // Shape of a question that's already been reviewed under FSRS at least once.
        question.fsrsReps = 3
        question.dueDate = Date().addingTimeInterval(86400 * 5)
        let dueDateBefore = question.dueDate
        context.insert(question)

        CobuxApp.migrateLeitnerProgressToFSRS(context: context)

        XCTAssertEqual(question.dueDate, dueDateBefore, "a question with real FSRS history must never be reset by the bulk migration pass")
    }
}
