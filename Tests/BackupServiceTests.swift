import XCTest
import SwiftData
@testable import Cobux

/// Regression coverage for two real, shipped gaps.
///
/// 1. `QuizQuestion` (and the FSRS scheduling state that lives on it since Phase 3) was
///    entirely excluded from backup/restore, on the stale theory that questions are
///    "regeneratable" -- true of their content, false of the FSRS progress earned by
///    actually reviewing them. Since chapter regeneration deletes and recreates every
///    question in a chapter (see `QuizGenerationServiceTests`'s `WipesPreviousBankOnRegeneration`
///    test), a backup was the one thing that could have protected that progress, and it
///    didn't cover it at all.
/// 2. `importData` used to skip EVERY book whose title already existed locally, full stop --
///    which after any reseed (the ordinary "device died, reinstalled, restored" case this
///    whole feature exists for) is every seed book. So a restore silently dropped all FSRS
///    progress, personal notes, and highlight memories; only chat messages and personal
///    writing (neither gated on a newly-created book) actually survived. `testExistingBook...`
///    below used to assert that exact bug as correct behavior -- it's been rewritten to
///    assert the fix instead: an existing book now MERGES in new content, while genuinely
///    pre-existing local progress is never overwritten.
@MainActor
final class BackupServiceTests: XCTestCase {

    /// Widened to match `CobuxSchema.all` in full -- it used to omit
    /// `JournalAttachment`/`Figure`/`Theme`, which meant the `.sidecar`/
    /// `attachmentIDs` import branch (the one automatic backup actually
    /// uses) was never exercised by a single test in this suite. A schema
    /// that doesn't declare a model type used elsewhere in a fixture would
    /// trap on insert, not throw -- so this omission wasn't just a coverage
    /// gap, it was silently steering every test away from that code path.
    private func makeContext() throws -> ModelContext {
        let schema = Schema(CobuxSchema.all)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    /// Genuinely persists to a temporary on-disk store and reopens it in a
    /// fresh `ModelContext` -- unlike `makeContext()`, an unsaved in-memory
    /// context keeps cascade-deleted objects registered as if nothing
    /// happened, which is exactly what let `testUndoImportRemovesExactlyWhatWasInserted`
    /// pass despite the real `model(for:)`/`registeredModel(for:)` divergence
    /// this suite's own history flagged as "unverifiable without a saved
    /// store." This closes that gap for real.
    private func makeSavedContext() throws -> (context: ModelContext, reload: () throws -> ModelContext) {
        let schema = Schema(CobuxSchema.all)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cobux-backup-test-\(UUID().uuidString).sqlite")
        let config = ModelConfiguration(schema: schema, url: url)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)
        let reload: () throws -> ModelContext = {
            let reopened = try ModelContainer(for: schema, configurations: config)
            return ModelContext(reopened)
        }
        return (context, reload)
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

    /// The core fix, exercised directly: restoring onto a book that already exists locally
    /// (but has nothing in it yet -- the exact shape of a freshly-reseeded book before any
    /// of the backup's content has landed) now MERGES the backup's chapter/question/FSRS
    /// state in, rather than skipping the whole book the way it used to.
    func testExistingEmptyBookMergesInNewContentFromBackup() throws {
        let sourceContext = try makeContext()
        let book = Book(title: "Attached", author: "Amir Levine")
        sourceContext.insert(book)
        let chapter = Chapter(title: "Ch 1", summary: "s")
        chapter.book = book
        book.chapters.append(chapter)
        let question = QuizQuestion(book: book, chapter: chapter, questionType: .recallMCQ, prompt: "p", explanation: "e")
        question.fsrsReps = 5
        question.fsrsStability = 7.5
        sourceContext.insert(question)
        chapter.quizQuestions.append(question)
        try sourceContext.save()
        let data = try BackupService.exportData(books: [book])

        let targetContext = try makeContext()
        // Same title, but nothing in it yet -- exactly what a reseeded book looks like
        // before restore lands.
        let existingBook = Book(title: "Attached", author: "Amir Levine")
        targetContext.insert(existingBook)
        try targetContext.save()

        let result = try BackupService.importData(data, existingBooks: [existingBook], modelContext: targetContext)

        XCTAssertEqual(result.booksImported, 0, "the book itself already existed -- this is a merge, not a new insert")
        XCTAssertEqual(result.booksMerged, 1)
        XCTAssertEqual(result.quizQuestionsImported, 1, "the chapter/question genuinely didn't exist locally yet, so they should be merged in")

        let restoredQuestions = try targetContext.fetch(FetchDescriptor<QuizQuestion>())
        XCTAssertEqual(restoredQuestions.count, 1)
        XCTAssertEqual(restoredQuestions.first?.fsrsReps, 5)
        XCTAssertEqual(restoredQuestions.first?.fsrsStability, 7.5)
    }

    /// The other half of the same fix: a question that DOES already exist locally (same
    /// prompt, in the same chapter of the same book) keeps its own real local progress --
    /// restoring an older backup must never roll a more-advanced local FSRS state backward.
    func testExistingQuestionProgressIsNeverOverwrittenByRestore() throws {
        let sourceContext = try makeContext()
        let book = Book(title: "Attached", author: "Amir Levine")
        sourceContext.insert(book)
        let chapter = Chapter(title: "Ch 1", summary: "s")
        chapter.book = book
        book.chapters.append(chapter)
        let question = QuizQuestion(book: book, chapter: chapter, questionType: .recallMCQ, prompt: "p", explanation: "e")
        question.fsrsReps = 1 // an OLDER backup's state
        sourceContext.insert(question)
        chapter.quizQuestions.append(question)
        try sourceContext.save()
        let data = try BackupService.exportData(books: [book])

        let targetContext = try makeContext()
        let existingBook = Book(title: "Attached", author: "Amir Levine")
        targetContext.insert(existingBook)
        let existingChapter = Chapter(title: "Ch 1", summary: "s")
        existingChapter.book = existingBook
        existingBook.chapters.append(existingChapter)
        let existingQuestion = QuizQuestion(book: existingBook, chapter: existingChapter, questionType: .recallMCQ, prompt: "p", explanation: "e")
        existingQuestion.fsrsReps = 9 // NEWER, more-advanced real local progress
        targetContext.insert(existingQuestion)
        existingChapter.quizQuestions.append(existingQuestion)
        try targetContext.save()

        let result = try BackupService.importData(data, existingBooks: [existingBook], modelContext: targetContext)

        XCTAssertEqual(result.quizQuestionsImported, 0, "the question already exists locally (same prompt, same chapter) -- must not be duplicated or touched")
        let questions = try targetContext.fetch(FetchDescriptor<QuizQuestion>())
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions.first?.fsrsReps, 9, "local progress must survive untouched, not get rolled back by an older backup")
    }

    /// `personalNote`/`tags`/`isReminder` on a highlight that already exists locally (same
    /// book, same text) get filled in from the backup only where the local value is empty --
    /// never overwriting something the user already wrote.
    func testHighlightPersonalNoteFillsGapWithoutOverwritingExisting() throws {
        let sourceContext = try makeContext()
        let book = Book(title: "Walden", author: "Thoreau")
        sourceContext.insert(book)
        let noted = Highlight(text: "Simplify, simplify.", personalNote: "From the backup.", tags: ["simplicity"])
        noted.book = book
        book.highlights.append(noted)
        let untouched = Highlight(text: "I went to the woods.", personalNote: "Backup's own note -- must not overwrite local.")
        untouched.book = book
        book.highlights.append(untouched)
        try sourceContext.save()
        let data = try BackupService.exportData(books: [book])

        let targetContext = try makeContext()
        let existingBook = Book(title: "Walden", author: "Thoreau")
        targetContext.insert(existingBook)
        // No local note yet -- should be filled in from the backup.
        let localNoted = Highlight(text: "Simplify, simplify.")
        localNoted.book = existingBook
        existingBook.highlights.append(localNoted)
        // Already has a real local note -- must survive untouched.
        let localUntouched = Highlight(text: "I went to the woods.", personalNote: "My own real note.")
        localUntouched.book = existingBook
        existingBook.highlights.append(localUntouched)
        try targetContext.save()

        try BackupService.importData(data, existingBooks: [existingBook], modelContext: targetContext)

        let highlights = try targetContext.fetch(FetchDescriptor<Highlight>())
        let restoredNoted = try XCTUnwrap(highlights.first { $0.text == "Simplify, simplify." })
        XCTAssertEqual(restoredNoted.personalNote, "From the backup.", "gap should be filled in")
        XCTAssertEqual(restoredNoted.tags, ["simplicity"])

        let restoredUntouched = try XCTUnwrap(highlights.first { $0.text == "I went to the woods." })
        XCTAssertEqual(restoredUntouched.personalNote, "My own real note.", "an existing note must never be overwritten by a restore")
    }

    /// The end-to-end scenario the whole feature exists for: a reinstall reseeds every book
    /// fresh (so every title already exists, matching `testExistingEmptyBookMergesInNewContentFromBackup`'s
    /// setup), and restoring an old backup on top of that must bring back highlight memories
    /// too, not just questions and notes.
    func testHighlightMemoryRestoresOntoAlreadyExistingBook() throws {
        let sourceContext = try makeContext()
        let book = Book(title: "Sapiens", author: "Harari")
        sourceContext.insert(book)
        let highlight = Highlight(text: "Fiction has enabled us to cooperate.")
        highlight.book = book
        book.highlights.append(highlight)
        let memory = HighlightMemory(highlight: highlight, nextReviewDate: Date(timeIntervalSince1970: 1_900_000_000))
        memory.box = 3
        memory.timesSeen = 4
        memory.timesCorrect = 3
        highlight.memory = memory
        sourceContext.insert(memory)
        try sourceContext.save()
        let data = try BackupService.exportData(books: [book])

        let targetContext = try makeContext()
        let existingBook = Book(title: "Sapiens", author: "Harari")
        targetContext.insert(existingBook)
        try targetContext.save()

        let result = try BackupService.importData(data, existingBooks: [existingBook], modelContext: targetContext)

        XCTAssertEqual(result.highlightMemoriesImported, 1)
        let highlights = try targetContext.fetch(FetchDescriptor<Highlight>())
        let restored = try XCTUnwrap(highlights.first)
        XCTAssertEqual(restored.memory?.box, 3)
        XCTAssertEqual(restored.memory?.timesSeen, 4)
    }

    /// `QuizAttempt`/`QuizAnswerRecord` -- exam scores, timing, free-recall answers -- had
    /// zero backup coverage at all before this. Pure history: always imports regardless of
    /// whether the book was new or already existed, since there's nothing local it could
    /// conflict with.
    func testQuizAttemptAndAnswersRoundTrip() throws {
        let sourceContext = try makeContext()
        let book = Book(title: "Sapiens", author: "Harari")
        sourceContext.insert(book)
        let chapter = Chapter(title: "Ch 1", summary: "s")
        chapter.book = book
        book.chapters.append(chapter)
        let question = QuizQuestion(book: book, chapter: chapter, questionType: .recallMCQ, prompt: "What enabled cooperation?", choices: ["Fiction", "Fire"], correctAnswerIndex: 0, explanation: "e")
        sourceContext.insert(question)
        chapter.quizQuestions.append(question)

        let attempt = QuizAttempt(book: book, scopeDescription: "Ch 1", mode: .examSimulation, timeLimitSeconds: 600, startedAt: Date(timeIntervalSince1970: 1_750_000_000))
        attempt.completedAt = Date(timeIntervalSince1970: 1_750_000_500)
        attempt.totalQuestions = 1
        attempt.correctCount = 1
        attempt.answeredCount = 1
        sourceContext.insert(attempt)

        let answer = QuizAnswerRecord(attempt: attempt, question: question)
        answer.selectedAnswerIndex = 0
        answer.isCorrect = true
        answer.answerText = "Fiction"
        answer.timeSpentSeconds = 12.5
        sourceContext.insert(answer)
        attempt.answers.append(answer)
        try sourceContext.save()

        let data = try BackupService.exportData(books: [book], quizAttempts: [attempt])

        let targetContext = try makeContext()
        let result = try BackupService.importData(data, existingBooks: [], modelContext: targetContext)

        XCTAssertEqual(result.quizAttemptsImported, 1)
        let restoredAttempts = try targetContext.fetch(FetchDescriptor<QuizAttempt>())
        XCTAssertEqual(restoredAttempts.count, 1)
        let restoredAttempt = try XCTUnwrap(restoredAttempts.first)
        XCTAssertEqual(restoredAttempt.correctCount, 1)
        XCTAssertEqual(restoredAttempt.answers.count, 1)
        // The real bug caught in review before shipping: the restored answer's
        // `question` link used to resolve against an arbitrary highlight's book
        // instead of the attempt's own book.
        XCTAssertEqual(restoredAttempt.answers.first?.question?.prompt, "What enabled cooperation?")
        XCTAssertEqual(restoredAttempt.answers.first?.answerText, "Fiction")
    }

    /// Re-running the exact same restore a second time must not duplicate the attempt --
    /// same idempotence guarantee every other DTO in this file already has.
    func testQuizAttemptImportIsIdempotent() throws {
        let sourceContext = try makeContext()
        let book = Book(title: "Sapiens", author: "Harari")
        sourceContext.insert(book)
        let attempt = QuizAttempt(book: book, scopeDescription: "Ch 1", mode: .practice, startedAt: Date(timeIntervalSince1970: 1_750_000_000))
        sourceContext.insert(attempt)
        try sourceContext.save()
        let data = try BackupService.exportData(books: [book], quizAttempts: [attempt])

        let targetContext = try makeContext()
        _ = try BackupService.importData(data, existingBooks: [], modelContext: targetContext)
        let existingAttempts = try targetContext.fetch(FetchDescriptor<QuizAttempt>())
        let existingBooksAfterFirstImport = try targetContext.fetch(FetchDescriptor<Book>())

        let result = try BackupService.importData(data, existingBooks: existingBooksAfterFirstImport, existingQuizAttempts: existingAttempts, modelContext: targetContext)

        XCTAssertEqual(result.quizAttemptsImported, 0, "the exact same attempt re-imported a second time must not duplicate")
        XCTAssertEqual(try targetContext.fetch(FetchDescriptor<QuizAttempt>()).count, 1)
    }

    /// Precise Undo: deletes exactly the objects one import inserted, leaving everything
    /// that already existed locally completely untouched.
    func testUndoImportRemovesExactlyWhatWasInserted() throws {
        let sourceContext = try makeContext()
        let book = Book(title: "Walden", author: "Thoreau")
        sourceContext.insert(book)
        let highlight = Highlight(text: "Simplify, simplify.")
        highlight.book = book
        book.highlights.append(highlight)
        try sourceContext.save()
        let data = try BackupService.exportData(books: [book])

        let targetContext = try makeContext()
        // A real, pre-existing entry that must survive the undo untouched.
        let survivor = PersonalWritingEntry(source: "journal", title: "Mine", text: "Untouched by any of this.")
        targetContext.insert(survivor)
        try targetContext.save()

        let result = try BackupService.importData(data, existingBooks: [], modelContext: targetContext)
        XCTAssertEqual(result.booksImported, 1)
        XCTAssertEqual(try targetContext.fetch(FetchDescriptor<Book>()).count, 1)

        BackupService.undoImport(result.insertedIdentifiers, modelContext: targetContext)

        XCTAssertEqual(try targetContext.fetch(FetchDescriptor<Book>()).count, 0, "the restored book should be gone")
        XCTAssertEqual(try targetContext.fetch(FetchDescriptor<Highlight>()).count, 0, "cascaded away with its book")
        let remainingEntries = try targetContext.fetch(FetchDescriptor<PersonalWritingEntry>())
        XCTAssertEqual(remainingEntries.count, 1, "the pre-existing entry must survive an undo of an unrelated import")
        XCTAssertEqual(remainingEntries.first?.title, "Mine")
    }

    /// The `.sidecar` branch is what `AutoBackupService` actually uses in
    /// production (photo bytes sync as separate immutable files, never
    /// inlined into the JSON) -- and until now it had zero coverage,
    /// because `makeContext()`'s schema didn't even declare `JournalAttachment`.
    /// Confirms a sidecar-policy export restores `JournalAttachment` rows
    /// under the SAME id the DTO carried, which is the one thing
    /// `AutoRestoreService.downloadPendingAttachments` depends on to find
    /// the matching file later.
    func testSidecarAttachmentImportRestoresJournalAttachmentRowsWithMatchingIDs() throws {
        let sourceContext = try makeContext()
        let entry = PersonalWritingEntry(source: "journal", title: "Morning pages", text: "Real entry text.")
        sourceContext.insert(entry)
        let attachment = JournalAttachment(entry: entry)
        sourceContext.insert(attachment)
        entry.attachments.append(attachment)
        try sourceContext.save()
        let originalAttachmentID = attachment.id

        let data = try BackupService.exportData(
            books: [], personalWritingEntries: [entry], attachmentPolicy: .sidecar
        )

        let targetContext = try makeContext()
        let result = try BackupService.importData(data, existingBooks: [], modelContext: targetContext)

        XCTAssertEqual(result.personalWritingEntriesImported, 1)
        let restoredAttachments = try targetContext.fetch(FetchDescriptor<JournalAttachment>())
        XCTAssertEqual(restoredAttachments.count, 1, "sidecar policy must still create the row, just no inline bytes")
        XCTAssertEqual(restoredAttachments.first?.id, originalAttachmentID, "AutoRestoreService's resumable download matches sidecar files by this id")
        XCTAssertEqual(result.insertedIdentifiers.journalAttachments.count, 1)
    }

    /// Both quadratic paths this session found (`titleToBookID` resolution
    /// and the per-answer question lookup) were invisible to every existing
    /// fixture here, all of which top out at one book / one attempt / one
    /// answer. This exercises multiple books each with their own attempts
    /// and multiple answers per attempt, and just asserts the restored data
    /// is still exactly right at that scale -- a regression back to the
    /// O(n^2) form wouldn't fail this on correctness, but it's the shape of
    /// fixture that would have caught the actual bugs, and a future
    /// performance regression here is now visible to anyone reading the test.
    func testMultiBookMultiAttemptImportStaysCorrectAtScale() throws {
        let sourceContext = try makeContext()
        var books: [Book] = []
        var attempts: [QuizAttempt] = []
        for bookIndex in 0..<4 {
            let book = Book(title: "Book \(bookIndex)", author: "Author")
            sourceContext.insert(book)
            let chapter = Chapter(title: "Ch 1", summary: "s")
            chapter.book = book
            book.chapters.append(chapter)
            var questions: [QuizQuestion] = []
            for q in 0..<5 {
                let question = QuizQuestion(book: book, chapter: chapter, questionType: .recallMCQ, prompt: "Book \(bookIndex) Q\(q)", choices: ["A", "B"], correctAnswerIndex: 0, explanation: "e")
                sourceContext.insert(question)
                chapter.quizQuestions.append(question)
                questions.append(question)
            }
            let attempt = QuizAttempt(book: book, scopeDescription: "Ch 1", mode: .practice, startedAt: Date(timeIntervalSince1970: 1_750_000_000 + Double(bookIndex)))
            sourceContext.insert(attempt)
            for question in questions {
                let answer = QuizAnswerRecord(attempt: attempt, question: question)
                answer.answerText = question.prompt
                sourceContext.insert(answer)
                attempt.answers.append(answer)
            }
            books.append(book)
            attempts.append(attempt)
        }
        try sourceContext.save()

        let data = try BackupService.exportData(books: books, quizAttempts: attempts)
        let targetContext = try makeContext()
        let result = try BackupService.importData(data, existingBooks: [], modelContext: targetContext)

        XCTAssertEqual(result.quizAttemptsImported, 4)
        let restoredAttempts = try targetContext.fetch(FetchDescriptor<QuizAttempt>())
        for attempt in restoredAttempts {
            let bookTitle = try XCTUnwrap(attempt.book?.title)
            XCTAssertEqual(attempt.answers.count, 5)
            for answer in attempt.answers {
                // Each answer's question must resolve against ITS OWN attempt's
                // book, never a different one -- exactly the class of bug the
                // per-answer question lookup rewrite guards against.
                XCTAssertEqual(answer.question?.prompt, answer.answerText)
                XCTAssertTrue(answer.question?.prompt.hasPrefix(bookTitle) ?? false)
            }
        }
    }

    /// `makeContext()` is in-memory and unsaved, which lets a cascade-deleted
    /// child stay registered as if nothing happened -- masking exactly the
    /// divergence this session found between `ModelContext.model(for:)`
    /// (non-throwing, traps on failure) and `registeredModel(for:)` (the
    /// actual safe check `undoImport` now uses). This runs the same undo
    /// against a genuinely saved-and-reopened SQLite store instead.
    func testUndoImportRemovesExactlyWhatWasInsertedOnASavedStore() throws {
        let (sourceContext, _) = try makeSavedContext()
        let book = Book(title: "Meditations", author: "Marcus Aurelius")
        sourceContext.insert(book)
        let highlight = Highlight(text: "You have power over your mind.")
        highlight.book = book
        book.highlights.append(highlight)
        try sourceContext.save()
        let data = try BackupService.exportData(books: [book])

        let (targetContext, reload) = try makeSavedContext()
        let survivor = PersonalWritingEntry(source: "journal", title: "Mine", text: "Untouched.")
        targetContext.insert(survivor)
        try targetContext.save()

        let result = try BackupService.importData(data, existingBooks: [], modelContext: targetContext)
        try targetContext.save()
        XCTAssertEqual(result.booksImported, 1)

        // Reopen against the same on-disk store -- a fresh context, exactly
        // like undo happening on a later launch, not the same in-memory
        // session the import just ran in.
        let reopenedContext = try reload()
        BackupService.undoImport(result.insertedIdentifiers, modelContext: reopenedContext)
        try reopenedContext.save()

        XCTAssertEqual(try reopenedContext.fetch(FetchDescriptor<Book>()).count, 0, "the restored book should be gone")
        XCTAssertEqual(try reopenedContext.fetch(FetchDescriptor<Highlight>()).count, 0, "cascaded away with its book")
        let remainingEntries = try reopenedContext.fetch(FetchDescriptor<PersonalWritingEntry>())
        XCTAssertEqual(remainingEntries.count, 1, "the pre-existing entry must survive an undo of an unrelated import")
        XCTAssertEqual(remainingEntries.first?.title, "Mine")
    }
}
