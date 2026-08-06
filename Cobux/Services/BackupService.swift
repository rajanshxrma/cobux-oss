import SwiftData
import Foundation
import UniformTypeIdentifiers
import SwiftUI

/// Manual JSON export/import of the whole library -- the actual gap when
/// there's no CloudKit/cross-device sync at all: a lost or wiped phone loses
/// every authored highlight/chapter permanently. Covers the real content
/// (books, chapters, highlights), chat history, legacy spaced-repetition
/// state (`HighlightMemory`), and FSRS quiz progress (`QuizQuestion`) --
/// all genuinely irreplaceable. `QuizQuestion` was originally left out on
/// the theory that questions are "regeneratable from the source textbooks/
/// API" -- true of the question CONTENT, but false of the earned FSRS
/// scheduling state once Phase 3 moved it onto `QuizQuestion` itself
/// (stability/difficulty/reps/lapses/dueDate). Regenerating a chapter's
/// questions (which `QuizGenerationService`/`ClozeService` do automatically
/// whenever a highlight changes) deletes and recreates every question in
/// it, silently discarding that progress -- this is the one place it can
/// be recovered from. `Figure` remains genuinely regeneratable (no earned
/// state attached to it) and stays omitted.
enum BackupService {
    struct BackupDocument: Codable {
        var exportDate: Date
        var books: [BookDTO]
        var chatMessages: [ChatMessageDTO]
        var highlightMemories: [HighlightMemoryDTO]
        var quizQuestions: [QuizQuestionDTO]

        init(exportDate: Date, books: [BookDTO], chatMessages: [ChatMessageDTO], highlightMemories: [HighlightMemoryDTO], quizQuestions: [QuizQuestionDTO]) {
            self.exportDate = exportDate
            self.books = books
            self.chatMessages = chatMessages
            self.highlightMemories = highlightMemories
            self.quizQuestions = quizQuestions
        }

        /// Custom decode so an older backup file (missing any of these keys
        /// entirely) still imports cleanly instead of throwing -- older
        /// backups simply restore whatever sections they have, with the
        /// rest empty.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            exportDate = try container.decode(Date.self, forKey: .exportDate)
            books = try container.decode([BookDTO].self, forKey: .books)
            chatMessages = try container.decodeIfPresent([ChatMessageDTO].self, forKey: .chatMessages) ?? []
            highlightMemories = try container.decodeIfPresent([HighlightMemoryDTO].self, forKey: .highlightMemories) ?? []
            quizQuestions = try container.decodeIfPresent([QuizQuestionDTO].self, forKey: .quizQuestions) ?? []
        }
    }

    struct ChatMessageDTO: Codable {
        var content: String
        var isUser: Bool
        var timestamp: Date
        var referencedBooks: [String]
        /// Book title, not `Book.id` -- import always mints fresh UUIDs for
        /// restored books, so a UUID captured at export time would never
        /// resolve to anything on the far side of a restore. `nil` means the
        /// general "Cobux" thread, exactly matching `ChatMessage.bookID`'s
        /// own nil-means-general convention.
        var bookTitle: String?
    }

    /// Keyed by (book title, highlight text) rather than any stored UUID, for
    /// the same reason as `ChatMessageDTO.bookTitle` -- highlight IDs don't
    /// survive a restore either, but the text content does.
    struct HighlightMemoryDTO: Codable {
        var bookTitle: String
        var highlightText: String
        var box: Int
        var nextReviewDate: Date
        var lastReviewedDate: Date?
        var timesSeen: Int
        var timesCorrect: Int
        var consecutiveCorrect: Int
        var lastConfidenceRaw: Int?
    }

    struct BookDTO: Codable {
        var title: String
        var author: String
        var coverColorHex: String
        var coverImageURL: String?
        var dateAdded: Date
        var dateFinished: Date?
        var chapters: [ChapterDTO]
        var highlights: [HighlightDTO]
    }

    struct ChapterDTO: Codable {
        var title: String
        var summary: String
        var keyLessons: [String]
        var chapterNumber: Int?
        var isCompleted: Bool
    }

    struct HighlightDTO: Codable {
        var text: String
        var chapter: String?
        var page: Int?
        var personalNote: String?
        var tags: [String]
        var isReminder: Bool
        var dateAdded: Date
    }

    /// Keyed by (book title, chapter title, prompt) on restore, same
    /// no-stored-UUID convention as the other DTOs -- `QuizQuestion.id`
    /// doesn't survive a restore either. Carries both the question's own
    /// content (so a restore doesn't depend on regeneration ever running)
    /// and its FSRS scheduling state, which is the actual irreplaceable
    /// part this type exists to protect.
    struct QuizQuestionDTO: Codable {
        var bookTitle: String
        var chapterTitle: String?
        var questionTypeRaw: String
        var prompt: String
        var choices: [String]
        var correctAnswerIndex: Int?
        var explanation: String
        var difficulty: Int
        var topicTags: [String]
        var generationSourceRaw: String
        var sourceHighlightTexts: [String]
        var fsrsStability: Double
        var fsrsDifficulty: Double
        var fsrsReps: Int
        var fsrsLapses: Int
        var lastReviewedAt: Date?
        var dueDate: Date?
        var isSuspended: Bool
    }

    private static func chapterDTO(from chapter: Chapter) -> ChapterDTO {
        ChapterDTO(title: chapter.title, summary: chapter.summary, keyLessons: chapter.keyLessons, chapterNumber: chapter.chapterNumber, isCompleted: chapter.isCompleted)
    }

    private static func highlightDTO(from highlight: Highlight) -> HighlightDTO {
        HighlightDTO(text: highlight.text, chapter: highlight.chapter, page: highlight.page, personalNote: highlight.personalNote, tags: highlight.tags, isReminder: highlight.isReminder, dateAdded: highlight.dateAdded)
    }

    private static func bookDTO(from book: Book) -> BookDTO {
        let chapterDTOs: [ChapterDTO] = book.chapters.map(chapterDTO(from:))
        let highlightDTOs: [HighlightDTO] = book.highlights.map(highlightDTO(from:))
        return BookDTO(
            title: book.title,
            author: book.author,
            coverColorHex: book.coverColorHex,
            coverImageURL: book.coverImageURL,
            dateAdded: book.dateAdded,
            dateFinished: book.dateFinished,
            chapters: chapterDTOs,
            highlights: highlightDTOs
        )
    }

    private static func chatMessageDTO(from message: ChatMessage, bookTitlesByID: [UUID: String]) -> ChatMessageDTO {
        ChatMessageDTO(
            content: message.content,
            isUser: message.isUser,
            timestamp: message.timestamp,
            referencedBooks: message.referencedBooks,
            bookTitle: message.bookID.flatMap { bookTitlesByID[$0] }
        )
    }

    private static func highlightMemoryDTOs(from book: Book) -> [HighlightMemoryDTO] {
        book.highlights.compactMap { highlight in
            guard let memory = highlight.memory else { return nil }
            return HighlightMemoryDTO(
                bookTitle: book.title,
                highlightText: highlight.text,
                box: memory.box,
                nextReviewDate: memory.nextReviewDate,
                lastReviewedDate: memory.lastReviewedDate,
                timesSeen: memory.timesSeen,
                timesCorrect: memory.timesCorrect,
                consecutiveCorrect: memory.consecutiveCorrect,
                lastConfidenceRaw: memory.lastConfidenceRaw
            )
        }
    }

    private static func quizQuestionDTOs(from book: Book) -> [QuizQuestionDTO] {
        book.chapters.flatMap { chapter in
            chapter.quizQuestions.map { question in
                QuizQuestionDTO(
                    bookTitle: book.title,
                    chapterTitle: chapter.title,
                    questionTypeRaw: question.questionTypeRaw,
                    prompt: question.prompt,
                    choices: question.choices,
                    correctAnswerIndex: question.correctAnswerIndex,
                    explanation: question.explanation,
                    difficulty: question.difficulty,
                    topicTags: question.topicTags,
                    generationSourceRaw: question.generationSourceRaw,
                    sourceHighlightTexts: question.sourceHighlights.map(\.text),
                    fsrsStability: question.fsrsStability,
                    fsrsDifficulty: question.fsrsDifficulty,
                    fsrsReps: question.fsrsReps,
                    fsrsLapses: question.fsrsLapses,
                    lastReviewedAt: question.lastReviewedAt,
                    dueDate: question.dueDate,
                    isSuspended: question.isSuspended
                )
            }
        }
    }

    static func exportData(books: [Book], chatMessages: [ChatMessage] = []) throws -> Data {
        let bookDTOs: [BookDTO] = books.map(bookDTO(from:))
        let bookTitlesByID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0.title) })
        let chatDTOs = chatMessages.map { chatMessageDTO(from: $0, bookTitlesByID: bookTitlesByID) }
        let memoryDTOs = books.flatMap(highlightMemoryDTOs(from:))
        let questionDTOs = books.flatMap(quizQuestionDTOs(from:))
        let document = BackupDocument(exportDate: .now, books: bookDTOs, chatMessages: chatDTOs, highlightMemories: memoryDTOs, quizQuestions: questionDTOs)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    struct ImportResult {
        var booksImported: Int
        var chatMessagesImported: Int
        var highlightMemoriesImported: Int
        var quizQuestionsImported: Int
    }

    /// Skips any book whose title already exists in the store, so importing
    /// the same backup twice (or restoring onto a phone that already has
    /// some content) never creates duplicates. Chat messages and scheduling
    /// state are restored the same way -- skipped if an identical entry
    /// already exists, so a repeat import is always safe to run again.
    @discardableResult
    static func importData(
        _ data: Data,
        existingBooks: [Book],
        existingChatMessages: [ChatMessage] = [],
        modelContext: ModelContext
    ) throws -> ImportResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(BackupDocument.self, from: data)

        let existingTitles = Set(existingBooks.map { $0.title.lowercased() })
        var booksImported = 0

        // (book title lowercased, highlight text) -> the newly-created Highlight,
        // so HighlightMemory can be reattached after the loop. Only newly-imported
        // highlights are eligible -- a book that already existed was skipped above
        // and keeps whatever local scheduling state it already has, untouched.
        var newHighlightsByKey: [String: Highlight] = [:]
        // (book title lowercased, chapter title) -> the newly-created Chapter, so
        // QuizQuestion can be reattached to the right chapter after the loop.
        var newChaptersByKey: [String: Chapter] = [:]
        var newBookTitlesByLowercased: [String: String] = [:]

        for bookDTO in document.books {
            let lowerTitle = bookDTO.title.lowercased()
            guard !existingTitles.contains(lowerTitle) else { continue }

            let book = Book(
                title: bookDTO.title,
                author: bookDTO.author,
                coverColorHex: bookDTO.coverColorHex,
                coverImageURL: bookDTO.coverImageURL,
                dateAdded: bookDTO.dateAdded,
                dateFinished: bookDTO.dateFinished
            )
            modelContext.insert(book)
            newBookTitlesByLowercased[lowerTitle] = bookDTO.title

            for chapterDTO in bookDTO.chapters {
                let chapter = Chapter(title: chapterDTO.title, summary: chapterDTO.summary, keyLessons: chapterDTO.keyLessons, chapterNumber: chapterDTO.chapterNumber, isCompleted: chapterDTO.isCompleted)
                book.chapters.append(chapter)
                newChaptersByKey["\(lowerTitle)|||\(chapterDTO.title)"] = chapter
            }

            for highlightDTO in bookDTO.highlights {
                let highlight = Highlight(text: highlightDTO.text, chapter: highlightDTO.chapter, page: highlightDTO.page, personalNote: highlightDTO.personalNote, tags: highlightDTO.tags, isReminder: highlightDTO.isReminder, dateAdded: highlightDTO.dateAdded)
                book.highlights.append(highlight)
                newHighlightsByKey["\(lowerTitle)|||\(highlightDTO.text)"] = highlight
            }

            booksImported += 1
        }

        // Restore quiz questions (content + FSRS state) onto the book/chapter/highlights
        // just recreated above. Only eligible for newly-imported books -- an already-existing
        // book keeps whatever local questions/progress it has, untouched, same rule as
        // HighlightMemory above.
        var quizQuestionsImported = 0
        for questionDTO in document.quizQuestions {
            let lowerTitle = questionDTO.bookTitle.lowercased()
            guard newBookTitlesByLowercased[lowerTitle] != nil else { continue }
            let chapter = questionDTO.chapterTitle.flatMap { newChaptersByKey["\(lowerTitle)|||\($0)"] }
            let sources = questionDTO.sourceHighlightTexts.compactMap { newHighlightsByKey["\(lowerTitle)|||\($0)"] }

            let question = QuizQuestion(
                book: chapter?.book,
                chapter: chapter,
                questionType: QuizQuestionType(rawValue: questionDTO.questionTypeRaw) ?? .recallMCQ,
                prompt: questionDTO.prompt,
                choices: questionDTO.choices,
                correctAnswerIndex: questionDTO.correctAnswerIndex,
                explanation: questionDTO.explanation,
                difficulty: questionDTO.difficulty,
                topicTags: questionDTO.topicTags
            )
            question.generationSourceRaw = questionDTO.generationSourceRaw
            question.sourceHighlights = sources
            question.fsrsStability = questionDTO.fsrsStability
            question.fsrsDifficulty = questionDTO.fsrsDifficulty
            question.fsrsReps = questionDTO.fsrsReps
            question.fsrsLapses = questionDTO.fsrsLapses
            question.lastReviewedAt = questionDTO.lastReviewedAt
            question.dueDate = questionDTO.dueDate
            question.isSuspended = questionDTO.isSuspended
            modelContext.insert(question)
            chapter?.quizQuestions.append(question)
            quizQuestionsImported += 1
        }

        // Restore scheduling state onto the highlights that were just recreated.
        var highlightMemoriesImported = 0
        for memoryDTO in document.highlightMemories {
            let key = "\(memoryDTO.bookTitle.lowercased())|||\(memoryDTO.highlightText)"
            guard let highlight = newHighlightsByKey[key], highlight.memory == nil else { continue }
            let memory = HighlightMemory(highlight: highlight, nextReviewDate: memoryDTO.nextReviewDate)
            memory.box = memoryDTO.box
            memory.lastReviewedDate = memoryDTO.lastReviewedDate
            memory.timesSeen = memoryDTO.timesSeen
            memory.timesCorrect = memoryDTO.timesCorrect
            memory.consecutiveCorrect = memoryDTO.consecutiveCorrect
            memory.lastConfidenceRaw = memoryDTO.lastConfidenceRaw
            highlight.memory = memory
            modelContext.insert(memory)
            highlightMemoriesImported += 1
        }

        // Chat messages restore against whatever book now exists in the store --
        // either one that already existed, or one just imported above.
        var titleToBookID: [String: UUID] = [:]
        for book in existingBooks { titleToBookID[book.title.lowercased()] = book.id }
        for bookDTO in document.books {
            let lowerTitle = bookDTO.title.lowercased()
            if newBookTitlesByLowercased[lowerTitle] != nil, let inserted = newHighlightsByKey.values.first(where: { $0.book?.title.lowercased() == lowerTitle })?.book {
                titleToBookID[lowerTitle] = inserted.id
            }
        }

        let existingMessageKeys = Set(existingChatMessages.map { "\($0.content)|||\($0.isUser)|||\($0.timestamp.timeIntervalSince1970)|||\($0.bookID?.uuidString ?? "")" })
        var chatMessagesImported = 0
        for messageDTO in document.chatMessages {
            let bookID = messageDTO.bookTitle.flatMap { titleToBookID[$0.lowercased()] }
            let dedupeKey = "\(messageDTO.content)|||\(messageDTO.isUser)|||\(messageDTO.timestamp.timeIntervalSince1970)|||\(bookID?.uuidString ?? "")"
            guard !existingMessageKeys.contains(dedupeKey) else { continue }
            let message = ChatMessage(
                content: messageDTO.content,
                isUser: messageDTO.isUser,
                timestamp: messageDTO.timestamp,
                referencedBooks: messageDTO.referencedBooks,
                bookID: bookID
            )
            modelContext.insert(message)
            chatMessagesImported += 1
        }

        try modelContext.save()
        return ImportResult(
            booksImported: booksImported,
            chatMessagesImported: chatMessagesImported,
            highlightMemoriesImported: highlightMemoriesImported,
            quizQuestionsImported: quizQuestionsImported
        )
    }
}

struct BackupFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
