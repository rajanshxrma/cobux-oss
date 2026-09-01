import SwiftData
import Foundation
import UniformTypeIdentifiers
import SwiftUI

/// Manual JSON export/import of the whole library -- the actual gap when
/// there's no CloudKit/cross-device sync at all: a lost or wiped phone loses
/// every authored highlight/chapter permanently. Covers the real content
/// (books, chapters, highlights), chat history, legacy spaced-repetition
/// state (`HighlightMemory`), FSRS quiz progress (`QuizQuestion`), and full
/// quiz-session history (`QuizAttempt`/`QuizAnswerRecord`) -- all genuinely
/// irreplaceable. `QuizQuestion` was originally left out on the theory that
/// questions are "regeneratable from the source textbooks/API" -- true of
/// the question CONTENT, but false of the earned FSRS scheduling state once
/// Phase 3 moved it onto `QuizQuestion` itself (stability/difficulty/reps/
/// lapses/dueDate). Regenerating a chapter's questions (which
/// `QuizGenerationService`/`ClozeService` do automatically whenever a
/// highlight changes) deletes and recreates every question in it, silently
/// discarding that progress -- this is the one place it can be recovered
/// from. `Figure`/`Theme` remain genuinely regeneratable (no earned state
/// attached to either) and stay omitted. `PersonalWritingEntry` rows are
/// covered too (2.2.0) -- irreplaceable the same way a highlight's
/// `personalNote` is, since the source is Rajan's own writing, not anything
/// the app itself generated.
///
/// This is also the ONE function protecting all of that data on restore, so
/// its own contract is worth stating plainly: importing is additive and
/// idempotent, and NEVER deletes or overwrites a value the user already has
/// -- a gap gets filled, a genuine conflict is left alone. `AutoBackupService`/
/// `AutoRestoreService` build automatic, private, off-device protection on
/// top of this same function rather than a second implementation of it.
enum BackupService {
    /// `.inline` (the long-standing default, unchanged for the two manual
    /// export call sites) embeds every journal photo's raw JPEG bytes
    /// directly in the JSON -- correct for a one-off "share this file"
    /// export. `.sidecar` (used by `AutoBackupService`) omits the bytes and
    /// records only `attachmentIDs`, because an automatic snapshot re-runs
    /// on a schedule: inlining tens of MB of already-unchanged photo bytes
    /// into a JSON that gets rewritten on every run wastes the exact
    /// bandwidth/storage this feature exists to spend wisely. Sidecar photo
    /// files are synced separately, once, immutably (see
    /// `AutoBackupService`'s own doc comment).
    enum AttachmentPolicy {
        case inline
        case sidecar
    }

    struct BackupDocument: Codable {
        /// Bumped only if a future change genuinely breaks backward
        /// compatibility with `init(from:)`'s decode-if-present tolerance --
        /// not incremented for every additive field, the way every other
        /// field in this file already gets added without one.
        var schemaVersion: Int = 1
        var exportDate: Date
        var books: [BookDTO]
        var chatMessages: [ChatMessageDTO]
        var highlightMemories: [HighlightMemoryDTO]
        var quizQuestions: [QuizQuestionDTO]
        var personalWritingEntries: [PersonalWritingEntryDTO]
        var quizAttempts: [QuizAttemptDTO]

        init(
            schemaVersion: Int = 1,
            exportDate: Date,
            books: [BookDTO],
            chatMessages: [ChatMessageDTO],
            highlightMemories: [HighlightMemoryDTO],
            quizQuestions: [QuizQuestionDTO],
            personalWritingEntries: [PersonalWritingEntryDTO] = [],
            quizAttempts: [QuizAttemptDTO] = []
        ) {
            self.schemaVersion = schemaVersion
            self.exportDate = exportDate
            self.books = books
            self.chatMessages = chatMessages
            self.highlightMemories = highlightMemories
            self.quizQuestions = quizQuestions
            self.personalWritingEntries = personalWritingEntries
            self.quizAttempts = quizAttempts
        }

        /// Custom decode so an older backup file (missing any of these keys
        /// entirely) still imports cleanly instead of throwing -- older
        /// backups simply restore whatever sections they have, with the
        /// rest empty.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            exportDate = try container.decode(Date.self, forKey: .exportDate)
            books = try container.decode([BookDTO].self, forKey: .books)
            chatMessages = try container.decodeIfPresent([ChatMessageDTO].self, forKey: .chatMessages) ?? []
            highlightMemories = try container.decodeIfPresent([HighlightMemoryDTO].self, forKey: .highlightMemories) ?? []
            quizQuestions = try container.decodeIfPresent([QuizQuestionDTO].self, forKey: .quizQuestions) ?? []
            personalWritingEntries = try container.decodeIfPresent([PersonalWritingEntryDTO].self, forKey: .personalWritingEntries) ?? []
            quizAttempts = try container.decodeIfPresent([QuizAttemptDTO].self, forKey: .quizAttempts) ?? []
        }
    }

    /// No stored embedding vector — same established pattern as `HighlightDTO`
    /// (which also omits `embeddingData`): a restored entry gets its vector
    /// filled in lazily by `CobuxApp.backfillPersonalWritingEmbeddings`, the
    /// exact same "backfill anything with a nil embedding on next launch"
    /// mechanism `Highlight` already relies on, rather than a synchronous
    /// on-device ML call per entry inside this already-synchronous import
    /// path (which could freeze the UI at real export scale — the reason
    /// `PersonalWritingImportService`'s own import is `async` in the first
    /// place).
    /// `attachments` holds each photo's raw already-downsampled JPEG bytes
    /// (`.inline` policy) -- ids are meaningless across devices/restores, so
    /// only the actual pixels round-trip that way. `attachmentIDs` (`.sidecar`
    /// policy) instead carries each attachment's stable UUID string, so
    /// import can recreate the `JournalAttachment` ROW with that exact id
    /// (matching the sidecar file `AutoBackupService` already wrote under
    /// the same id) without needing the bytes present in this document at
    /// all. Both are ever populated together only by accident of policy --
    /// import prefers inline bytes when present, sidecar ids otherwise.
    struct PersonalWritingEntryDTO: Codable {
        var source: String
        var title: String
        var text: String
        var modifiedDate: Date?
        var dateImported: Date
        /// Lifetime compose-session seconds (`PersonalWritingEntry.writingSeconds`)
        /// -- optional at every layer so backups from before the field existed
        /// decode cleanly, same convention as `attachments` below.
        var writingSeconds: Int?
        var attachments: [Data] = []
        var attachmentIDs: [String] = []

        /// Custom decode so a backup taken before attachments (or
        /// attachmentIDs) existed still restores cleanly instead of throwing
        /// and failing the WHOLE personal-writing array -- same
        /// "older backup, missing key, decode as empty" convention
        /// `BackupDocument.init(from:)` above already establishes at the
        /// top level, just needed here too since this type is otherwise
        /// pure `Codable` synthesis with no forwarding compatibility.
        init(source: String, title: String, text: String, modifiedDate: Date?, dateImported: Date, writingSeconds: Int? = nil, attachments: [Data] = [], attachmentIDs: [String] = []) {
            self.source = source
            self.title = title
            self.text = text
            self.modifiedDate = modifiedDate
            self.dateImported = dateImported
            self.writingSeconds = writingSeconds
            self.attachments = attachments
            self.attachmentIDs = attachmentIDs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            source = try container.decode(String.self, forKey: .source)
            title = try container.decode(String.self, forKey: .title)
            text = try container.decode(String.self, forKey: .text)
            modifiedDate = try container.decodeIfPresent(Date.self, forKey: .modifiedDate)
            dateImported = try container.decode(Date.self, forKey: .dateImported)
            writingSeconds = try container.decodeIfPresent(Int.self, forKey: .writingSeconds)
            attachments = try container.decodeIfPresent([Data].self, forKey: .attachments) ?? []
            attachmentIDs = try container.decodeIfPresent([String].self, forKey: .attachmentIDs) ?? []
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

    /// One user answer within an attempt -- pure history, nothing this app
    /// can regenerate. `questionPrompt`, not a stored id, is the join key
    /// back to a restored `QuizQuestion` on the far side of a restore, same
    /// content-is-the-key convention `QuizQuestionDTO.sourceHighlightTexts`
    /// already uses; `QuizAnswerRecord.question` is optional, so an
    /// unresolvable link degrades to `nil` rather than failing the import.
    struct QuizAnswerRecordDTO: Codable {
        var questionPrompt: String?
        var selectedAnswerIndex: Int?
        var isCorrect: Bool
        var confidenceRaw: Int?
        var timeSpentSeconds: Double
        var markedForReview: Bool
        var answerText: String?
        var presentedChoiceOrder: [Int]
    }

    /// A completed (or in-progress) quiz session -- exam scores, timing, and
    /// free-recall answers, none of which any part of this app can
    /// reconstruct after the fact. Nests its answers directly rather than a
    /// flat top-level array joined by an id, sidestepping the need for a
    /// stable cross-reference key for the attempt itself. Always imports
    /// regardless of whether its book was new or already existed -- unlike
    /// books/highlights/questions, an attempt is pure history with nothing
    /// local it could conflict with.
    struct QuizAttemptDTO: Codable {
        var bookTitle: String?
        var scopeDescription: String
        var modeRaw: String
        var startedAt: Date
        var completedAt: Date?
        var totalQuestions: Int
        var correctCount: Int
        var skippedCount: Int
        var answeredCount: Int
        var timeLimitSeconds: Int?
        var timeTakenSeconds: Int?
        var deadline: Date?
        var answers: [QuizAnswerRecordDTO]
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

    private static func personalWritingEntryDTO(from entry: PersonalWritingEntry, policy: AttachmentPolicy) -> PersonalWritingEntryDTO {
        switch policy {
        case .inline:
            let attachmentData = entry.attachments.compactMap { JournalAttachmentStore.data(for: $0.id) }
            return PersonalWritingEntryDTO(source: entry.source, title: entry.title, text: entry.text, modifiedDate: entry.modifiedDate, dateImported: entry.dateImported, writingSeconds: entry.writingSeconds, attachments: attachmentData)
        case .sidecar:
            let ids = entry.attachments.map { $0.id.uuidString }
            return PersonalWritingEntryDTO(source: entry.source, title: entry.title, text: entry.text, modifiedDate: entry.modifiedDate, dateImported: entry.dateImported, attachmentIDs: ids)
        }
    }

    private static func quizAnswerRecordDTO(from record: QuizAnswerRecord) -> QuizAnswerRecordDTO {
        QuizAnswerRecordDTO(
            questionPrompt: record.question?.prompt,
            selectedAnswerIndex: record.selectedAnswerIndex,
            isCorrect: record.isCorrect,
            confidenceRaw: record.confidenceRaw,
            timeSpentSeconds: record.timeSpentSeconds,
            markedForReview: record.markedForReview,
            answerText: record.answerText,
            presentedChoiceOrder: record.presentedChoiceOrder
        )
    }

    private static func quizAttemptDTO(from attempt: QuizAttempt) -> QuizAttemptDTO {
        QuizAttemptDTO(
            bookTitle: attempt.book?.title,
            scopeDescription: attempt.scopeDescription,
            modeRaw: attempt.modeRaw,
            startedAt: attempt.startedAt,
            completedAt: attempt.completedAt,
            totalQuestions: attempt.totalQuestions,
            correctCount: attempt.correctCount,
            skippedCount: attempt.skippedCount,
            answeredCount: attempt.answeredCount,
            timeLimitSeconds: attempt.timeLimitSeconds,
            timeTakenSeconds: attempt.timeTakenSeconds,
            deadline: attempt.deadline,
            answers: attempt.answers.map(quizAnswerRecordDTO(from:))
        )
    }

    static func exportData(
        books: [Book],
        chatMessages: [ChatMessage] = [],
        personalWritingEntries: [PersonalWritingEntry] = [],
        quizAttempts: [QuizAttempt] = [],
        attachmentPolicy: AttachmentPolicy = .inline
    ) throws -> Data {
        let bookDTOs: [BookDTO] = books.map(bookDTO(from:))
        // `uniqueKeysWithValues:` traps on a duplicate `Book.id` -- exactly the
        // condition `CobuxApp.repairDuplicateIDs` exists to fix, but export can
        // run before that repair pass has landed (or on a device that hasn't
        // relaunched since acquiring a duplicate). `uniquingKeysWith:` degrades
        // to "one of the two titles wins" instead of crashing the export.
        let bookTitlesByID = Dictionary(books.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let chatDTOs = chatMessages.map { chatMessageDTO(from: $0, bookTitlesByID: bookTitlesByID) }
        let memoryDTOs = books.flatMap(highlightMemoryDTOs(from:))
        let questionDTOs = books.flatMap(quizQuestionDTOs(from:))
        let personalWritingDTOs = personalWritingEntries.map { personalWritingEntryDTO(from: $0, policy: attachmentPolicy) }
        let quizAttemptDTOs = quizAttempts.map(quizAttemptDTO(from:))
        let document = BackupDocument(
            exportDate: .now,
            books: bookDTOs,
            chatMessages: chatDTOs,
            highlightMemories: memoryDTOs,
            quizQuestions: questionDTOs,
            personalWritingEntries: personalWritingDTOs,
            quizAttempts: quizAttemptDTOs
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // `.sortedKeys` always -- byte-stable output is what makes
        // `AutoBackupService`'s digest-based change detection possible.
        // `.prettyPrinted` only for `.inline` (the manual, "share this file"
        // export someone might actually open): it roughly doubles a
        // multi-MB automatic snapshot nobody reads by hand.
        encoder.outputFormatting = attachmentPolicy == .inline ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(document)
    }

    /// Every SwiftData model this file inserts, whether directly (`.insert`)
    /// or transitively (a `Book`'s cascade-deleted chapters/highlights/etc),
    /// tracked here so a caller (`AutoRestoreService`'s Undo action) can
    /// remove EXACTLY what one import inserted and nothing else. Tracked as
    /// `PersistentIdentifier`, not each model's own `id: UUID` -- `ChatMessage`
    /// has no such field, and `PersistentIdentifier` is the one identity every
    /// `@Model` type carries automatically, so this needs no per-type special
    /// case. Deleting a tracked `Book` cascades away its own tracked
    /// chapters/highlights/questions/memories for free; the rest of this
    /// list only ever holds ids for objects added to an already-existing
    /// (merged) book, which deleting the book wouldn't reach.
    struct InsertedIdentifiers {
        var books: [PersistentIdentifier] = []
        var chapters: [PersistentIdentifier] = []
        var highlights: [PersistentIdentifier] = []
        var quizQuestions: [PersistentIdentifier] = []
        var highlightMemories: [PersistentIdentifier] = []
        var chatMessages: [PersistentIdentifier] = []
        var personalWritingEntries: [PersistentIdentifier] = []
        var journalAttachments: [PersistentIdentifier] = []
        var quizAttempts: [PersistentIdentifier] = []

        var isEmpty: Bool {
            books.isEmpty && chapters.isEmpty && highlights.isEmpty && quizQuestions.isEmpty
                && highlightMemories.isEmpty && chatMessages.isEmpty && personalWritingEntries.isEmpty
                && journalAttachments.isEmpty && quizAttempts.isEmpty
        }
    }

    struct ImportResult {
        var booksImported: Int
        /// Existing books this import found content to fold into (a new
        /// chapter/highlight, or a gap-fill on one that already existed) --
        /// distinct from `booksImported`, which only counts genuinely new
        /// books. On a real restore (see `AutoRestoreService`), the local
        /// store already has every seed book from its own launch-time
        /// seeding, so this is almost always where the actually-recovered
        /// value shows up, not `booksImported`.
        var booksMerged: Int = 0
        var chatMessagesImported: Int
        var highlightMemoriesImported: Int
        var quizQuestionsImported: Int
        var personalWritingEntriesImported: Int = 0
        var quizAttemptsImported: Int = 0
        var insertedIdentifiers = InsertedIdentifiers()
    }

    /// Merges into a book whose title already exists rather than skipping it
    /// outright, so restoring onto a phone that already has the seed library
    /// (true immediately after any reseed, including the ordinary "device
    /// died, reinstalled, restored" case this whole feature exists for)
    /// actually recovers content instead of silently discarding it. Before
    /// this fix, EVERY book below was skipped whenever its title already
    /// existed -- which after a fresh reseed is every seed book -- so quiz
    /// progress, personal notes, and highlight memories never survived a
    /// restore at all; only chat messages and personal-writing entries
    /// (neither of which depends on a newly-created book) actually came
    /// back. A chapter/highlight not already present by title/text is
    /// appended; one that already exists gets `personalNote`/`tags` filled
    /// in only where the LOCAL value is empty (never overwritten) and
    /// `isReminder` OR'd in -- never destructive, same contract as every
    /// other DTO here, just no longer additive-only-into-emptiness.
    @discardableResult
    static func importData(
        _ data: Data,
        existingBooks: [Book],
        existingChatMessages: [ChatMessage] = [],
        existingPersonalWritingEntries: [PersonalWritingEntry] = [],
        existingQuizAttempts: [QuizAttempt] = [],
        modelContext: ModelContext
    ) throws -> ImportResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(BackupDocument.self, from: data)
        var inserted = InsertedIdentifiers()

        let existingBooksByLowercasedTitle = Dictionary(existingBooks.map { ($0.title.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var booksImported = 0
        var booksMerged = 0

        // (book title lowercased, highlight text) -> the Highlight, whether
        // just-created or a matched-existing one -- so HighlightMemory can be
        // reattached after the loop either way.
        var newHighlightsByKey: [String: Highlight] = [:]
        // (book title lowercased, chapter title) -> the Chapter, same "new or
        // matched-existing" coverage, so QuizQuestion can be reattached to
        // the right chapter after the loop.
        var newChaptersByKey: [String: Chapter] = [:]
        // Every book title this import touched, new OR merged -- the two
        // loops below key off this to decide whether a question/memory has
        // anywhere to attach, and don't otherwise care which case it was.
        var newBookTitlesByLowercased: [String: String] = [:]
        // The actual `Book` object per title touched -- used by the quiz-
        // attempt loop below to resolve a book directly, rather than
        // reverse-engineering it from a highlight (which would silently fail
        // for a book with zero highlights).
        var booksByLowercasedTitle: [String: Book] = [:]

        for bookDTO in document.books {
            let lowerTitle = bookDTO.title.lowercased()

            let book: Book
            if let existing = existingBooksByLowercasedTitle[lowerTitle] {
                book = existing
                booksMerged += 1
            } else {
                book = Book(
                    title: bookDTO.title,
                    author: bookDTO.author,
                    coverColorHex: bookDTO.coverColorHex,
                    coverImageURL: bookDTO.coverImageURL,
                    dateAdded: bookDTO.dateAdded,
                    dateFinished: bookDTO.dateFinished
                )
                modelContext.insert(book)
                inserted.books.append(book.persistentModelID)
                booksImported += 1
            }
            newBookTitlesByLowercased[lowerTitle] = bookDTO.title
            booksByLowercasedTitle[lowerTitle] = book

            // Snapshot BEFORE this loop's own appends, so a book with two
            // same-titled chapters in one backup (shouldn't happen, but this
            // keeps the lookup honest either way) can't self-match against
            // something it just inserted a moment ago.
            let existingChaptersByTitle = Dictionary(book.chapters.map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })
            for chapterDTO in bookDTO.chapters {
                let chapter: Chapter
                if let existingChapter = existingChaptersByTitle[chapterDTO.title] {
                    chapter = existingChapter
                } else {
                    chapter = Chapter(title: chapterDTO.title, summary: chapterDTO.summary, keyLessons: chapterDTO.keyLessons, chapterNumber: chapterDTO.chapterNumber, isCompleted: chapterDTO.isCompleted)
                    book.chapters.append(chapter)
                    inserted.chapters.append(chapter.persistentModelID)
                }
                newChaptersByKey["\(lowerTitle)|||\(chapterDTO.title)"] = chapter
            }

            let existingHighlightsByText = Dictionary(book.highlights.map { ($0.text, $0) }, uniquingKeysWith: { first, _ in first })
            for highlightDTO in bookDTO.highlights {
                let highlight: Highlight
                if let existingHighlight = existingHighlightsByText[highlightDTO.text] {
                    highlight = existingHighlight
                    // Fill gaps only -- a non-empty local value always wins,
                    // this never overwrites something the user already has.
                    if (highlight.personalNote ?? "").isEmpty, let note = highlightDTO.personalNote, !note.isEmpty {
                        highlight.personalNote = note
                    }
                    if highlight.tags.isEmpty, !highlightDTO.tags.isEmpty {
                        highlight.tags = highlightDTO.tags
                    }
                    if highlightDTO.isReminder {
                        highlight.isReminder = true
                    }
                } else {
                    highlight = Highlight(text: highlightDTO.text, chapter: highlightDTO.chapter, page: highlightDTO.page, personalNote: highlightDTO.personalNote, tags: highlightDTO.tags, isReminder: highlightDTO.isReminder, dateAdded: highlightDTO.dateAdded)
                    book.highlights.append(highlight)
                    inserted.highlights.append(highlight.persistentModelID)
                }
                newHighlightsByKey["\(lowerTitle)|||\(highlightDTO.text)"] = highlight
            }
        }

        // Restore quiz questions (content + FSRS state) onto the book/chapter/highlights
        // resolved above -- new or matched-existing, either way.
        var quizQuestionsImported = 0
        for questionDTO in document.quizQuestions {
            let lowerTitle = questionDTO.bookTitle.lowercased()
            guard newBookTitlesByLowercased[lowerTitle] != nil else { continue }
            let chapter = questionDTO.chapterTitle.flatMap { newChaptersByKey["\(lowerTitle)|||\($0)"] }
            // A merged (already-existing) chapter can already have this exact
            // question -- prompt is the same no-stored-UUID content key this
            // whole file already uses elsewhere, so re-running a restore
            // never duplicates a question that survived locally.
            if let chapter, chapter.quizQuestions.contains(where: { $0.prompt == questionDTO.prompt }) {
                continue
            }
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
            // A hand-edited or corrupted backup file can encode a state FSRS's own
            // scheduling could never produce (stability 0 or non-finite with reps > 0)
            // -- `FSRS.schedule`'s `pow(S, -w[9])` sends that straight to a NaN that
            // used to trap `Int(Double.nan)` at grading time (fixed at the trap site
            // too, but this is the actual source -- don't persist garbage a future
            // review would just have to survive). Reset to a fresh, never-reviewed
            // state instead of trusting stability blindly.
            let isValidReviewedState = questionDTO.fsrsStability.isFinite && questionDTO.fsrsStability > 0
            if questionDTO.fsrsReps > 0 && !isValidReviewedState {
                question.fsrsStability = 0
                question.fsrsDifficulty = 0
                question.fsrsReps = 0
                question.fsrsLapses = 0
                question.lastReviewedAt = nil
                // The imported `dueDate` was itself possibly computed from the same
                // bad stability -- don't trust it either. Due now, same as any other
                // freshly-generated question.
                question.dueDate = .now
            } else {
                question.fsrsStability = questionDTO.fsrsStability
                question.fsrsDifficulty = questionDTO.fsrsDifficulty
                question.fsrsReps = questionDTO.fsrsReps
                question.fsrsLapses = questionDTO.fsrsLapses
                question.lastReviewedAt = questionDTO.lastReviewedAt
                question.dueDate = questionDTO.dueDate
            }
            question.isSuspended = questionDTO.isSuspended
            modelContext.insert(question)
            inserted.quizQuestions.append(question.persistentModelID)
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
            inserted.highlightMemories.append(memory.persistentModelID)
            highlightMemoriesImported += 1
        }

        // Chat messages restore against whatever book now exists in the store --
        // either one that already existed, or one just imported above.
        // `booksByLowercasedTitle` (built in the loop above) already maps
        // every touched title straight to its `Book` -- the old version here
        // re-derived the same answer by scanning ALL of `newHighlightsByKey`
        // per book, an O(books x highlights) relationship-faulting search
        // for something already sitting in a dictionary one line away.
        var titleToBookID: [String: UUID] = [:]
        for book in existingBooks { titleToBookID[book.title.lowercased()] = book.id }
        for bookDTO in document.books {
            let lowerTitle = bookDTO.title.lowercased()
            if let book = booksByLowercasedTitle[lowerTitle] {
                titleToBookID[lowerTitle] = book.id
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
            inserted.chatMessages.append(message.persistentModelID)
            chatMessagesImported += 1
        }

        // Same (source, title, text) dedup key as `PersonalWritingImportService`
        // -- kept as a duplicate literal rather than a shared helper since the
        // two services have no other coupling and this is a three-line key, not
        // worth introducing a cross-service dependency for.
        var existingPersonalWritingKeys = Set(existingPersonalWritingEntries.map { "\($0.source)|||\($0.title)|||\($0.text)" })
        var personalWritingEntriesImported = 0
        for entryDTO in document.personalWritingEntries {
            let key = "\(entryDTO.source)|||\(entryDTO.title)|||\(entryDTO.text)"
            guard !existingPersonalWritingKeys.contains(key) else { continue }
            existingPersonalWritingKeys.insert(key)
            let entry = PersonalWritingEntry(source: entryDTO.source, title: entryDTO.title, text: entryDTO.text, modifiedDate: entryDTO.modifiedDate, dateImported: entryDTO.dateImported)
            entry.writingSeconds = entryDTO.writingSeconds
            modelContext.insert(entry)
            inserted.personalWritingEntries.append(entry.persistentModelID)
            if !entryDTO.attachments.isEmpty {
                // `.restore`, not `.save` -- these bytes are already the
                // downsampled JPEG output of a prior `.save` call (see
                // `JournalAttachmentStore.restore`'s own doc comment), so this
                // writes them back verbatim instead of re-processing.
                for attachmentData in entryDTO.attachments {
                    let attachment = JournalAttachment(entry: entry)
                    modelContext.insert(attachment)
                    inserted.journalAttachments.append(attachment.persistentModelID)
                    JournalAttachmentStore.restore(attachmentData, id: attachment.id)
                }
            } else {
                // Sidecar policy: no bytes in this document at all -- create
                // the row with the SAME id the sidecar file was written
                // under (`AutoBackupService` mirrors `JournalAttachmentStore`'s
                // own uuid-keyed filename exactly), so a later resumable
                // download pass (`AutoRestoreService`) can find and copy the
                // file in by that id. Direct `.id` reassignment after init is
                // already an established, safe pattern here -- see
                // `CobuxApp.repairDuplicateIDs`.
                for idString in entryDTO.attachmentIDs {
                    guard let restoredID = UUID(uuidString: idString) else { continue }
                    let attachment = JournalAttachment(entry: entry)
                    attachment.id = restoredID
                    modelContext.insert(attachment)
                    inserted.journalAttachments.append(attachment.persistentModelID)
                }
            }
            personalWritingEntriesImported += 1
        }

        // Attempts are pure history -- always import regardless of whether
        // their book was new or already existed, since nothing local can
        // conflict with a past quiz session. Dedupe on (book, scope,
        // startedAt) so re-running restore never duplicates the same
        // attempt.
        let existingAttemptKeys = Set(existingQuizAttempts.map { "\($0.book?.title.lowercased() ?? "")|||\($0.scopeDescription)|||\($0.startedAt.timeIntervalSince1970)" })
        var quizAttemptsImported = 0
        for attemptDTO in document.quizAttempts {
            let lowerTitle = attemptDTO.bookTitle?.lowercased() ?? ""
            let dedupeKey = "\(lowerTitle)|||\(attemptDTO.scopeDescription)|||\(attemptDTO.startedAt.timeIntervalSince1970)"
            guard !existingAttemptKeys.contains(dedupeKey) else { continue }

            // `booksByLowercasedTitle` (every book this import touched,
            // populated directly from the main book loop) for a book new or
            // merged this run; `existingBooksByLowercasedTitle` for one this
            // import didn't touch at all (the attempt's book already existed
            // and had nothing new in this backup to merge). Doesn't depend
            // on the book having any highlights, unlike reverse-resolving
            // through `newHighlightsByKey` would.
            let book = attemptDTO.bookTitle.flatMap { title -> Book? in
                let lower = title.lowercased()
                return booksByLowercasedTitle[lower] ?? existingBooksByLowercasedTitle[lower]
            }
            let attempt = QuizAttempt(book: book, scopeDescription: attemptDTO.scopeDescription, mode: QuizMode(rawValue: attemptDTO.modeRaw) ?? .practice, timeLimitSeconds: attemptDTO.timeLimitSeconds, startedAt: attemptDTO.startedAt)
            attempt.completedAt = attemptDTO.completedAt
            attempt.totalQuestions = attemptDTO.totalQuestions
            attempt.correctCount = attemptDTO.correctCount
            attempt.skippedCount = attemptDTO.skippedCount
            attempt.answeredCount = attemptDTO.answeredCount
            attempt.timeTakenSeconds = attemptDTO.timeTakenSeconds
            attempt.deadline = attemptDTO.deadline
            modelContext.insert(attempt)
            inserted.quizAttempts.append(attempt.persistentModelID)

            // Built ONCE per attempt, not per answer -- the old version
            // rebuilt this book's entire flattened question list (faulting
            // every chapter relationship) inside the answers loop below, an
            // O(answers x questions) scan for what a single dictionary
            // lookup answers. On a real quiz history against a real
            // question bank this was a genuine main-thread hang/jetsam risk
            // at restore time, invisible to a test suite whose fixtures
            // never go past one attempt with one answer.
            let questionsByPrompt = Dictionary(
                (book?.chapters.flatMap(\.quizQuestions) ?? []).map { ($0.prompt, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for answerDTO in attemptDTO.answers {
                // `book`, the attempt's OWN resolved book -- an earlier
                // version of this line accidentally reached for
                // `newHighlightsByKey.values.first?.book`, an arbitrary
                // highlight's book with no relation to this attempt at all,
                // which would have resolved every restored answer's question
                // against whichever book happened to be first in that
                // dictionary. Caught in review before ever shipping.
                let question = answerDTO.questionPrompt.flatMap { questionsByPrompt[$0] }
                let record = QuizAnswerRecord(attempt: attempt, question: question)
                record.selectedAnswerIndex = answerDTO.selectedAnswerIndex
                record.isCorrect = answerDTO.isCorrect
                record.confidenceRaw = answerDTO.confidenceRaw
                record.timeSpentSeconds = answerDTO.timeSpentSeconds
                record.markedForReview = answerDTO.markedForReview
                record.answerText = answerDTO.answerText
                record.presentedChoiceOrder = answerDTO.presentedChoiceOrder
                modelContext.insert(record)
                attempt.answers.append(record)
            }
            quizAttemptsImported += 1
        }

        try modelContext.save()
        return ImportResult(
            booksImported: booksImported,
            booksMerged: booksMerged,
            chatMessagesImported: chatMessagesImported,
            highlightMemoriesImported: highlightMemoriesImported,
            quizQuestionsImported: quizQuestionsImported,
            personalWritingEntriesImported: personalWritingEntriesImported,
            quizAttemptsImported: quizAttemptsImported,
            insertedIdentifiers: inserted
        )
    }

    /// Precise counterpart to `importData` -- deletes exactly the objects one
    /// import call inserted, nothing else. Deleting a tracked `Book` first
    /// cascades away its own tracked chapters/highlights/questions/memories,
    /// so re-deleting those explicitly afterward must be a safe no-op, not a
    /// double-delete crash.
    ///
    /// `ModelContext.model(for:)` is NOT what makes that safe -- its real SDK
    /// signature is non-throwing and non-optional (`-> any PersistentModel`),
    /// so a `try?`/`guard` around it is a silent no-op and any failure inside
    /// it (e.g. resolving an identifier whose row a cascade already removed)
    /// is an uncatchable trap, not a thrown error the old doc comment here
    /// claimed. `ModelContext.registeredModel<T>(for:) -> T?` is the actual
    /// safe check: it only looks at what's already registered in this
    /// context's memory (never faults the store), and genuinely returns
    /// `nil` -- no trap -- for an identifier that's no longer there.
    static func undoImport(_ identifiers: InsertedIdentifiers, modelContext: ModelContext) {
        func delete<T: PersistentModel>(_ ids: [PersistentIdentifier], as type: T.Type) {
            for id in ids {
                guard let model: T = modelContext.registeredModel(for: id) else { continue }
                modelContext.delete(model)
            }
        }
        delete(identifiers.books, as: Book.self)
        delete(identifiers.chapters, as: Chapter.self)
        delete(identifiers.highlights, as: Highlight.self)
        delete(identifiers.quizQuestions, as: QuizQuestion.self)
        delete(identifiers.highlightMemories, as: HighlightMemory.self)
        delete(identifiers.chatMessages, as: ChatMessage.self)
        for id in identifiers.personalWritingEntries {
            guard let model: PersonalWritingEntry = modelContext.registeredModel(for: id) else { continue }
            for attachment in model.attachments {
                JournalAttachmentStore.delete(id: attachment.id)
            }
            modelContext.delete(model)
        }
        delete(identifiers.journalAttachments, as: JournalAttachment.self)
        delete(identifiers.quizAttempts, as: QuizAttempt.self)
        try? modelContext.save()
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
