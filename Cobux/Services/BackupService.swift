import SwiftData
import Foundation
import UniformTypeIdentifiers
import SwiftUI
import CryptoKit

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
/// the app itself generated. `JournalKeep` (what he chose to hold, the
/// question he wrote to his future self, the ladder state that earned) and
/// `SituationThread` (the name and pinned note he gave a thread) joined in
/// 3.0, together with each chat message's thread identity -- until then a
/// message from the journal or a situation thread came back from a restore
/// in the unlocked General thread (see `ChatMessageDTO.thread`).
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
        var journalKeeps: [JournalKeepDTO]
        var situations: [SituationThreadDTO]
        var journalPeople: [JournalPersonDTO]

        init(
            schemaVersion: Int = 1,
            exportDate: Date,
            books: [BookDTO],
            chatMessages: [ChatMessageDTO],
            highlightMemories: [HighlightMemoryDTO],
            quizQuestions: [QuizQuestionDTO],
            personalWritingEntries: [PersonalWritingEntryDTO] = [],
            quizAttempts: [QuizAttemptDTO] = [],
            journalKeeps: [JournalKeepDTO] = [],
            situations: [SituationThreadDTO] = [],
            journalPeople: [JournalPersonDTO] = []
        ) {
            self.schemaVersion = schemaVersion
            self.exportDate = exportDate
            self.books = books
            self.chatMessages = chatMessages
            self.highlightMemories = highlightMemories
            self.quizQuestions = quizQuestions
            self.personalWritingEntries = personalWritingEntries
            self.quizAttempts = quizAttempts
            self.journalKeeps = journalKeeps
            self.situations = situations
            self.journalPeople = journalPeople
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
            journalKeeps = try container.decodeIfPresent([JournalKeepDTO].self, forKey: .journalKeeps) ?? []
            situations = try container.decodeIfPresent([SituationThreadDTO].self, forKey: .situations) ?? []
            journalPeople = try container.decodeIfPresent([JournalPersonDTO].self, forKey: .journalPeople) ?? []
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
        /// The entry's own `PersonalWritingEntry.id`, carried since 3.0 so
        /// everything that points at an entry by id -- a `JournalKeep`, a
        /// correspondence reply -- still resolves on the far side of a
        /// restore. Reused on import unless something local already holds
        /// that id (then a fresh one is minted and the references are
        /// remapped instead); nil for any backup written before this existed.
        var id: UUID?
        var source: String
        var title: String
        var text: String
        var modifiedDate: Date?
        var dateImported: Date
        /// Lifetime compose-session seconds (`PersonalWritingEntry.writingSeconds`)
        /// -- optional at every layer so backups from before the field existed
        /// decode cleanly, same convention as `attachments` below.
        var writingSeconds: Int?
        /// Correspondence link (The Correspondence), decoded below with
        /// `decodeIfPresent` so an older snapshot reads as nil. NOT left to
        /// synthesis: this type has a hand-written `init(from:)`, and a field
        /// missing from it is silently dropped on every restore -- which is
        /// exactly what happened to this, `answersEntryDate` and `locality`
        /// until 3.0 (exported, never read back). Resolves after a restore
        /// because `id` above round-trips; `importData` remaps it onto the
        /// local twin whenever the id itself could not be reused.
        var answersEntryID: UUID?
        var answersEntryDate: Date?
        var locality: String?
        var attachments: [Data] = []
        var attachmentIDs: [String] = []

        /// Custom decode so a backup taken before attachments (or
        /// attachmentIDs) existed still restores cleanly instead of throwing
        /// and failing the WHOLE personal-writing array -- same
        /// "older backup, missing key, decode as empty" convention
        /// `BackupDocument.init(from:)` above already establishes at the
        /// top level, just needed here too since this type is otherwise
        /// pure `Codable` synthesis with no forwarding compatibility.
        init(source: String, title: String, text: String, modifiedDate: Date?, dateImported: Date, writingSeconds: Int? = nil, answersEntryID: UUID? = nil, answersEntryDate: Date? = nil, locality: String? = nil, attachments: [Data] = [], attachmentIDs: [String] = [], id: UUID? = nil) {
            self.id = id
            self.source = source
            self.title = title
            self.text = text
            self.modifiedDate = modifiedDate
            self.dateImported = dateImported
            self.writingSeconds = writingSeconds
            self.answersEntryID = answersEntryID
            self.answersEntryDate = answersEntryDate
            self.locality = locality
            self.attachments = attachments
            self.attachmentIDs = attachmentIDs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(UUID.self, forKey: .id)
            source = try container.decode(String.self, forKey: .source)
            title = try container.decode(String.self, forKey: .title)
            text = try container.decode(String.self, forKey: .text)
            modifiedDate = try container.decodeIfPresent(Date.self, forKey: .modifiedDate)
            dateImported = try container.decode(Date.self, forKey: .dateImported)
            writingSeconds = try container.decodeIfPresent(Int.self, forKey: .writingSeconds)
            answersEntryID = try container.decodeIfPresent(UUID.self, forKey: .answersEntryID)
            answersEntryDate = try container.decodeIfPresent(Date.self, forKey: .answersEntryDate)
            locality = try container.decodeIfPresent(String.self, forKey: .locality)
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
        /// resolve to anything on the far side of a restore. `nil` here AND
        /// in `thread` means the general "Cobux" thread, exactly matching
        /// `ChatMessage.bookID`'s own nil-means-general convention.
        var bookTitle: String?
        /// The non-book thread this message lives in, when it does. Before
        /// 3.0 export derived thread identity from book titles alone, so
        /// every message in the "My Journal" thread (whose id is a sentinel,
        /// `ChatPromptBuilder.journalThreadID`, never a book) or in a
        /// situation thread came back from a restore with `bookID == nil`:
        /// in the unlocked General thread, outside the journal's Face ID gate
        /// and outside `CrossChatMemory`'s journal exclusion. Synthesized
        /// decode-if-present, so every backup written before this field
        /// existed still reads exactly as it did.
        var thread: ThreadRef? = nil

        enum ThreadRef: Codable, Equatable {
            case journal
            /// The situation's own stable id (what `ChatMessage.bookID` points
            /// at) plus its name, so the thread can be recreated from the
            /// message alone if the document carries no `situations` section.
            case situation(id: UUID, name: String)
            /// A thread id that resolved to nothing at export time -- a book
            /// deleted after the conversation. Restored verbatim: on the source
            /// device that conversation is unreachable, and a restore
            /// reproduces that rather than promoting it into General.
            case detached(threadID: UUID)
        }
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
        /// Decode-if-present so a backup taken before likes existed still
        /// restores; without a default an older snapshot would fail to decode
        /// entirely rather than just lacking the field.
        var isLiked: Bool? = nil
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

    /// A passage he chose to hold and the question he wrote to his future
    /// self (`JournalKeep`), with the ladder state that choice earned through
    /// time -- his act, never the app's, and none of it regeneratable. Carries
    /// `id` and `entryID` verbatim, unlike the title/text-keyed DTOs above:
    /// keeps are only ever minted in-app, so a keep's id is stable across
    /// every snapshot of the same device, and `entryID` resolves after a
    /// restore because `PersonalWritingEntryDTO.id` round-trips too.
    struct JournalKeepDTO: Codable {
        var id: UUID
        var entryID: UUID
        var passage: String
        var question: String?
        var sourceDate: Date
        var createdDate: Date
        var lastSurfacedDate: Date?
        var releasedDate: Date?
        var rung: Int
    }

    /// One situation thread's own row (`SituationThread`): the name he gave
    /// it and the note he pinned -- his writing, and the only structured
    /// memory that feature has. Its `id` is what every message in the thread
    /// carries as `bookID`, so it is preserved rather than re-minted, for the
    /// same reason as `JournalKeepDTO.id`.
    struct SituationThreadDTO: Codable {
        var id: UUID
        var name: String
        var note: String?
        var createdDate: Date
        var lastActivityDate: Date
    }

    /// One person the journal noticed and everything HE decided about them
    /// (`JournalPerson`): the name he confirmed, the forms he folded in,
    /// whether it is him or not a person at all, the contact he linked, and
    /// the summary he asked for. Pointers to his entries ride as ids and
    /// resolve after a restore because `PersonalWritingEntryDTO.id`
    /// round-trips -- `JournalKeepDTO`'s exact reasoning. What the machine
    /// derived on its own (the scan ledger) never rides: it is regenerable.
    /// `decodeIfPresent` throughout, so a snapshot from before any of these
    /// fields restores.
    struct JournalPersonDTO: Codable {
        var id: UUID
        var name: String
        var aliases: [String]
        var kind: String
        var entryIDs: [UUID]
        var firstSeen: Date?
        var lastSeen: Date?
        var contactIdentifier: String?
        var contactLinkedDate: Date?
        var summary: String?
        var summaryFingerprint: String?
        var summaryBasis: String?
        var summaryGeneratedDate: Date?
        var confirmedAt: Date?
        var createdAt: Date
        var updatedAt: Date

        init(id: UUID, name: String, aliases: [String], kind: String, entryIDs: [UUID],
             firstSeen: Date?, lastSeen: Date?, contactIdentifier: String?, contactLinkedDate: Date?,
             summary: String?, summaryFingerprint: String?, summaryBasis: String?, summaryGeneratedDate: Date?,
             confirmedAt: Date?, createdAt: Date, updatedAt: Date) {
            self.id = id
            self.name = name
            self.aliases = aliases
            self.kind = kind
            self.entryIDs = entryIDs
            self.firstSeen = firstSeen
            self.lastSeen = lastSeen
            self.contactIdentifier = contactIdentifier
            self.contactLinkedDate = contactLinkedDate
            self.summary = summary
            self.summaryFingerprint = summaryFingerprint
            self.summaryBasis = summaryBasis
            self.summaryGeneratedDate = summaryGeneratedDate
            self.confirmedAt = confirmedAt
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
            kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? JournalPersonKind.person.rawValue
            entryIDs = try container.decodeIfPresent([UUID].self, forKey: .entryIDs) ?? []
            firstSeen = try container.decodeIfPresent(Date.self, forKey: .firstSeen)
            lastSeen = try container.decodeIfPresent(Date.self, forKey: .lastSeen)
            contactIdentifier = try container.decodeIfPresent(String.self, forKey: .contactIdentifier)
            contactLinkedDate = try container.decodeIfPresent(Date.self, forKey: .contactLinkedDate)
            summary = try container.decodeIfPresent(String.self, forKey: .summary)
            summaryFingerprint = try container.decodeIfPresent(String.self, forKey: .summaryFingerprint)
            summaryBasis = try container.decodeIfPresent(String.self, forKey: .summaryBasis)
            summaryGeneratedDate = try container.decodeIfPresent(Date.self, forKey: .summaryGeneratedDate)
            confirmedAt = try container.decodeIfPresent(Date.self, forKey: .confirmedAt)
            let created = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
            createdAt = created
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? created
        }
    }

    private static func chapterDTO(from chapter: Chapter) -> ChapterDTO {
        ChapterDTO(title: chapter.title, summary: chapter.summary, keyLessons: chapter.keyLessons, chapterNumber: chapter.chapterNumber, isCompleted: chapter.isCompleted)
    }

    private static func highlightDTO(from highlight: Highlight) -> HighlightDTO {
        HighlightDTO(text: highlight.text, chapter: highlight.chapter, page: highlight.page, personalNote: highlight.personalNote, tags: highlight.tags, isReminder: highlight.isReminder, dateAdded: highlight.dateAdded, isLiked: highlight.isLiked)
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

    private static func chatMessageDTO(from message: ChatMessage, bookTitlesByID: [UUID: String], situationsByID: [UUID: SituationThread]) -> ChatMessageDTO {
        var bookTitle: String?
        var thread: ChatMessageDTO.ThreadRef?
        if let bookID = message.bookID {
            // The journal sentinel is checked before books on purpose: it is a
            // fixed id that no `Book` can ever carry, and it was exactly the id
            // the old title-only lookup turned into "general".
            if bookID == ChatPromptBuilder.journalThreadID {
                thread = .journal
            } else if let title = bookTitlesByID[bookID] {
                bookTitle = title
            } else if let situation = situationsByID[bookID] {
                thread = .situation(id: bookID, name: situation.name)
            } else {
                thread = .detached(threadID: bookID)
            }
        }
        return ChatMessageDTO(
            content: message.content,
            isUser: message.isUser,
            timestamp: message.timestamp,
            referencedBooks: message.referencedBooks,
            bookTitle: bookTitle,
            thread: thread
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
            return PersonalWritingEntryDTO(source: entry.source, title: entry.title, text: entry.text, modifiedDate: entry.modifiedDate, dateImported: entry.dateImported, writingSeconds: entry.writingSeconds, answersEntryID: entry.answersEntryID, answersEntryDate: entry.answersEntryDate, locality: entry.locality, attachments: attachmentData, id: entry.id)
        case .sidecar:
            let ids = entry.attachments.map { $0.id.uuidString }
            return PersonalWritingEntryDTO(source: entry.source, title: entry.title, text: entry.text, modifiedDate: entry.modifiedDate, dateImported: entry.dateImported, writingSeconds: entry.writingSeconds, answersEntryID: entry.answersEntryID, answersEntryDate: entry.answersEntryDate, locality: entry.locality, attachmentIDs: ids, id: entry.id)
        }
    }

    private static func journalKeepDTO(from keep: JournalKeep) -> JournalKeepDTO {
        JournalKeepDTO(
            id: keep.id,
            entryID: keep.entryID,
            passage: keep.passage,
            question: keep.question,
            sourceDate: keep.sourceDate,
            createdDate: keep.createdDate,
            lastSurfacedDate: keep.lastSurfacedDate,
            releasedDate: keep.releasedDate,
            rung: keep.rung
        )
    }

    private static func journalPersonDTO(from person: JournalPerson) -> JournalPersonDTO {
        JournalPersonDTO(
            id: person.id,
            name: person.name,
            aliases: person.aliases,
            kind: person.kindRaw,
            entryIDs: person.entryIDs,
            firstSeen: person.firstSeen,
            lastSeen: person.lastSeen,
            contactIdentifier: person.contactIdentifier,
            contactLinkedDate: person.contactLinkedDate,
            summary: person.summary,
            summaryFingerprint: person.summaryFingerprint,
            summaryBasis: person.summaryBasis,
            summaryGeneratedDate: person.summaryGeneratedDate,
            confirmedAt: person.confirmedAt,
            createdAt: person.createdAt,
            updatedAt: person.updatedAt
        )
    }

    private static func situationThreadDTO(from situation: SituationThread) -> SituationThreadDTO {
        SituationThreadDTO(
            id: situation.id,
            name: situation.name,
            note: situation.note,
            createdDate: situation.createdDate,
            lastActivityDate: situation.lastActivityDate
        )
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
        journalKeeps: [JournalKeep] = [],
        situations: [SituationThread] = [],
        journalPeople: [JournalPerson] = [],
        attachmentPolicy: AttachmentPolicy = .inline
    ) throws -> Data {
        let bookDTOs: [BookDTO] = books.map(bookDTO(from:))
        // `uniqueKeysWithValues:` traps on a duplicate `Book.id` -- exactly the
        // condition `CobuxApp.repairDuplicateIDs` exists to fix, but export can
        // run before that repair pass has landed (or on a device that hasn't
        // relaunched since acquiring a duplicate). `uniquingKeysWith:` degrades
        // to "one of the two titles wins" instead of crashing the export.
        let bookTitlesByID = Dictionary(books.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let situationsByID = Dictionary(situations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let chatDTOs = chatMessages.map { chatMessageDTO(from: $0, bookTitlesByID: bookTitlesByID, situationsByID: situationsByID) }
        let memoryDTOs = books.flatMap(highlightMemoryDTOs(from:))
        let questionDTOs = books.flatMap(quizQuestionDTOs(from:))
        let personalWritingDTOs = personalWritingEntries.map { personalWritingEntryDTO(from: $0, policy: attachmentPolicy) }
        let quizAttemptDTOs = quizAttempts.map(quizAttemptDTO(from:))
        let keepDTOs = journalKeeps.map(journalKeepDTO(from:))
        let situationDTOs = situations.map(situationThreadDTO(from:))
        let personDTOs = journalPeople.map(journalPersonDTO(from:))
        let document = BackupDocument(
            exportDate: .now,
            books: bookDTOs,
            chatMessages: chatDTOs,
            highlightMemories: memoryDTOs,
            quizQuestions: questionDTOs,
            personalWritingEntries: personalWritingDTOs,
            quizAttempts: quizAttemptDTOs,
            journalKeeps: keepDTOs,
            situations: situationDTOs,
            journalPeople: personDTOs
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
        /// Fingerprints rather than bare identifiers -- see
        /// `RestoredEntryFingerprint` for why Undo must be able to tell a
        /// restored entry from one he has since written into.
        var personalWritingEntries: [RestoredEntryFingerprint] = []
        var journalAttachments: [PersistentIdentifier] = []
        var quizAttempts: [PersistentIdentifier] = []
        /// `JournalKeep.id` / `SituationThread.id`, not `PersistentIdentifier`:
        /// both carry a stable UUID that `importData` preserves, and resolving
        /// by it is one plain fetch that works in whatever context Undo runs
        /// in -- `registeredModel(for:)` only answers for objects this context
        /// still holds in memory.
        var journalKeeps: [UUID] = []
        var situations: [UUID] = []
        /// `JournalPerson.id`, preserved by `importData` like a keep's.
        var journalPeople: [UUID] = []

        var isEmpty: Bool {
            books.isEmpty && chapters.isEmpty && highlights.isEmpty && quizQuestions.isEmpty
                && highlightMemories.isEmpty && chatMessages.isEmpty && personalWritingEntries.isEmpty
                && journalAttachments.isEmpty && quizAttempts.isEmpty
                && journalKeeps.isEmpty && situations.isEmpty && journalPeople.isEmpty
        }
    }

    /// What one restored entry looked like the moment it was inserted, so
    /// Undo can tell "still exactly what the backup put here" from "he has
    /// written into this since". Text is compared by digest -- stable across
    /// processes, unlike `Hasher` -- and any of text, `modifiedDate` or the
    /// attachment count differing marks the entry as his: Undo then leaves it
    /// alone and reports it. Journal writing has no delete path anywhere else
    /// in this app; the restore's own Undo must not be the exception.
    struct RestoredEntryFingerprint: Equatable {
        var entryID: UUID
        var textDigest: String
        var modifiedDate: Date?
        var attachmentCount: Int

        init(entry: PersonalWritingEntry, attachmentCount: Int) {
            entryID = entry.id
            textDigest = Self.digest(of: entry.text)
            modifiedDate = entry.modifiedDate
            self.attachmentCount = attachmentCount
        }

        func matches(_ entry: PersonalWritingEntry) -> Bool {
            guard Self.sameInstant(entry.modifiedDate, modifiedDate) else { return false }
            return entry.attachments.count == attachmentCount
                && Self.digest(of: entry.text) == textDigest
        }

        static func digest(of text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        /// Sub-millisecond tolerance: a `Date` that has been through the
        /// store and back need not be bit-identical to the one it was
        /// written from, and a false "changed" here would only ever err
        /// toward keeping -- but a false "kept" reads as Undo not working.
        private static func sameInstant(_ lhs: Date?, _ rhs: Date?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil):
                return true
            case let (lhs?, rhs?):
                return abs(lhs.timeIntervalSince(rhs)) < 0.001
            default:
                return false
            }
        }
    }

    struct ImportResult {
        var booksImported: Int
        /// Existing books this import actually folded content INTO -- a
        /// chapter or highlight that was appended, or a gap-fill (note, tags,
        /// isReminder) on one that already existed. A title match alone is not
        /// enough: it used to be, which meant re-importing an identical file
        /// reported "saved progress on 156 existing book(s)" while changing
        /// nothing, and made "Nothing new to import" unreachable on any phone
        /// carrying the seed library. Distinct from `booksImported`, which
        /// only counts genuinely new books. On a real restore (see
        /// `AutoRestoreService`), the local store already has every seed book
        /// from its own launch-time seeding, so this is almost always where
        /// the actually-recovered value shows up, not `booksImported`.
        var booksMerged: Int = 0
        var chatMessagesImported: Int
        var highlightMemoriesImported: Int
        var quizQuestionsImported: Int
        var personalWritingEntriesImported: Int = 0
        var quizAttemptsImported: Int = 0
        var journalKeepsImported: Int = 0
        var situationsImported: Int = 0
        var journalPeopleImported: Int = 0
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
            // `booksMerged` is counted at the END of this iteration rather than
            // here, because a title match on its own restores nothing. Counting
            // it here made a re-import of a file the store already held in full
            // report "saved progress on 156 existing book(s)", and made the
            // "Nothing new to import" case unreachable for anyone carrying the
            // seed library -- which is everyone. `foldedIntoExistingBook`
            // records whether any of the appends or gap-fills below actually
            // landed. Nothing about WHAT gets imported changes; only the count
            // that gets reported afterwards.
            let isExistingBook: Bool
            var foldedIntoExistingBook = false
            if let existing = existingBooksByLowercasedTitle[lowerTitle] {
                book = existing
                isExistingBook = true
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
                isExistingBook = false
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
                    foldedIntoExistingBook = true
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
                        foldedIntoExistingBook = true
                    }
                    if highlight.tags.isEmpty, !highlightDTO.tags.isEmpty {
                        highlight.tags = highlightDTO.tags
                        foldedIntoExistingBook = true
                    }
                    // `!highlight.isReminder` as well, so re-importing a file
                    // that says what the store already says is not counted as a
                    // restore (and is not a pointless write to the store).
                    if highlightDTO.isReminder, !highlight.isReminder {
                        highlight.isReminder = true
                        foldedIntoExistingBook = true
                    }
                } else {
                    highlight = Highlight(text: highlightDTO.text, chapter: highlightDTO.chapter, page: highlightDTO.page, personalNote: highlightDTO.personalNote, tags: highlightDTO.tags, isReminder: highlightDTO.isReminder, dateAdded: highlightDTO.dateAdded)
                    // Likes are a deliberate curation -- More > Liked is a list
                    // he built by hand, one double-tap at a time -- and it was
                    // absent from the DTO entirely, so every like was lost on
                    // restore with nothing indicating it.
                    highlight.isLiked = highlightDTO.isLiked ?? false
                    book.highlights.append(highlight)
                    inserted.highlights.append(highlight.persistentModelID)
                    foldedIntoExistingBook = true
                }
                newHighlightsByKey["\(lowerTitle)|||\(highlightDTO.text)"] = highlight
            }

            if isExistingBook, foldedIntoExistingBook { booksMerged += 1 }
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

        // Situation threads before their messages, so each has a thread to
        // land in. Keyed by the situation's own stable id (preserved, never
        // re-minted) -- a name is not an identity here, two threads may share
        // one by design (see `SituationThread`). An existing situation only
        // gets its note gap-filled, same contract as a highlight's
        // `personalNote`. Fetched here rather than passed in, so no import
        // call site can forget it.
        var situationsByID: [UUID: SituationThread] = [:]
        var situationsImported = 0
        let documentMentionsSituations = !document.situations.isEmpty || document.chatMessages.contains { message in
            if case .some(.situation) = message.thread { return true }
            return false
        }
        if documentMentionsSituations {
            let existingSituations = (try? modelContext.fetch(FetchDescriptor<SituationThread>())) ?? []
            situationsByID = Dictionary(existingSituations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for situationDTO in document.situations {
                if let existing = situationsByID[situationDTO.id] {
                    if (existing.note ?? "").isEmpty, let note = situationDTO.note, !note.isEmpty {
                        existing.note = note
                    }
                    continue
                }
                let situation = SituationThread(name: situationDTO.name, note: situationDTO.note)
                situation.id = situationDTO.id
                situation.createdDate = situationDTO.createdDate
                situation.lastActivityDate = situationDTO.lastActivityDate
                modelContext.insert(situation)
                situationsByID[situation.id] = situation
                inserted.situations.append(situation.id)
                situationsImported += 1
            }
        }
        // A message can reference a situation the document never listed (a
        // manual export from a call site that passed no `situations`). The
        // row is recreated from the reference itself -- id and name -- so the
        // conversation stays its own thread instead of falling into General.
        func situationThreadID(_ id: UUID, name: String) -> UUID {
            if situationsByID[id] == nil {
                let situation = SituationThread(name: name)
                situation.id = id
                modelContext.insert(situation)
                situationsByID[id] = situation
                inserted.situations.append(id)
                situationsImported += 1
            }
            return id
        }

        let existingMessageKeys = Set(existingChatMessages.map { "\($0.content)|||\($0.isUser)|||\($0.timestamp.timeIntervalSince1970)|||\($0.bookID?.uuidString ?? "")" })
        var chatMessagesImported = 0
        for messageDTO in document.chatMessages {
            let bookID: UUID?
            switch messageDTO.thread {
            case .some(.journal):
                bookID = ChatPromptBuilder.journalThreadID
            case .some(.situation(let id, let name)):
                bookID = situationThreadID(id, name: name)
            case .some(.detached(let threadID)):
                bookID = threadID
            case .none:
                bookID = messageDTO.bookTitle.flatMap { titleToBookID[$0.lowercased()] }
            }
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
        // worth introducing a cross-service dependency for. A map to the LOCAL
        // entry's id rather than a bare set of keys, because the keeps and
        // correspondence links below must land on whatever row this store
        // holds for a backup entry -- pre-existing twin or just inserted --
        // whatever id the backup carried for it.
        var localEntryIDsByKey: [String: UUID] = [:]
        for entry in existingPersonalWritingEntries {
            let key = "\(entry.source)|||\(entry.title)|||\(entry.text)"
            if localEntryIDsByKey[key] == nil { localEntryIDsByKey[key] = entry.id }
        }
        var takenEntryIDs = Set(existingPersonalWritingEntries.map(\.id))
        // Backup id -> local id for everything in this document that points
        // at an entry by id. Identity wherever the backup's own id was
        // reusable, which after a genuine wipe-and-restore is every entry.
        var entryIDRemap: [UUID: UUID] = [:]
        var pendingAnswerLinks: [(entry: PersonalWritingEntry, answersID: UUID)] = []
        var personalWritingEntriesImported = 0
        for entryDTO in document.personalWritingEntries {
            let key = "\(entryDTO.source)|||\(entryDTO.title)|||\(entryDTO.text)"
            if let localID = localEntryIDsByKey[key] {
                if let backupID = entryDTO.id { entryIDRemap[backupID] = localID }
                continue
            }
            let entry = PersonalWritingEntry(source: entryDTO.source, title: entryDTO.title, text: entryDTO.text, modifiedDate: entryDTO.modifiedDate, dateImported: entryDTO.dateImported)
            // Keep the backup's own id whenever nothing local holds it yet --
            // that is what lets a `JournalKeep.entryID` or a reply's
            // `answersEntryID` resolve after a restore at all. A collision
            // (the id already lives on a different entry here) mints fresh
            // and relies on the remap instead. Direct `.id` reassignment
            // after init is the established pattern -- see the sidecar branch
            // below and `CobuxApp.repairDuplicateIDs`.
            if let backupID = entryDTO.id, !takenEntryIDs.contains(backupID) {
                entry.id = backupID
            }
            takenEntryIDs.insert(entry.id)
            if let backupID = entryDTO.id { entryIDRemap[backupID] = entry.id }
            localEntryIDsByKey[key] = entry.id
            entry.writingSeconds = entryDTO.writingSeconds
            entry.answersEntryDate = entryDTO.answersEntryDate
            entry.locality = entryDTO.locality
            if let answersID = entryDTO.answersEntryID {
                pendingAnswerLinks.append((entry: entry, answersID: answersID))
            }
            modelContext.insert(entry)
            var attachmentCount = 0
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
                    attachmentCount += 1
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
                    attachmentCount += 1
                }
            }
            inserted.personalWritingEntries.append(RestoredEntryFingerprint(entry: entry, attachmentCount: attachmentCount))
            personalWritingEntriesImported += 1
        }
        // Correspondence links resolve after the whole loop, since the entry
        // a reply answers may sit later in the same document. Through the
        // remap, so a reply lands on the local twin of its original; an
        // original in neither this backup nor this store leaves the link
        // dangling, which the detail view already renders as a dated line.
        for link in pendingAnswerLinks {
            link.entry.answersEntryID = entryIDRemap[link.answersID] ?? link.answersID
        }

        // Keeps: his own act of holding a passage, the question he wrote to
        // his future self, and the ladder state that act earned through time
        // -- none of it regeneratable, none of it graded. Keyed by the keep's
        // own id: keeps are only ever minted in-app, so the id is stable
        // across every snapshot of the same device and a re-run never
        // duplicates one. `entryID` goes through the remap so a keep points
        // at the local twin of its entry. A keep whose entry is in neither
        // this backup nor this store is imported anyway: the passage, the
        // question and the record that he chose to hold them are his and
        // render on their own (`HeldView`), while the deck's own fail-closed
        // rule keeps it from being dealt until the entry exists.
        var journalKeepsImported = 0
        if !document.journalKeeps.isEmpty {
            var knownKeepIDs = Set(((try? modelContext.fetch(FetchDescriptor<JournalKeep>())) ?? []).map(\.id))
            for keepDTO in document.journalKeeps {
                guard !knownKeepIDs.contains(keepDTO.id) else { continue }
                knownKeepIDs.insert(keepDTO.id)
                let keep = JournalKeep(
                    entryID: entryIDRemap[keepDTO.entryID] ?? keepDTO.entryID,
                    passage: keepDTO.passage,
                    sourceDate: keepDTO.sourceDate,
                    question: keepDTO.question
                )
                keep.id = keepDTO.id
                keep.createdDate = keepDTO.createdDate
                keep.lastSurfacedDate = keepDTO.lastSurfacedDate
                keep.releasedDate = keepDTO.releasedDate
                // `isDue` indexes the ladder by rung -- a hand-edited file must
                // not be able to hand it a negative index.
                keep.rung = max(0, keepDTO.rung)
                modelContext.insert(keep)
                inserted.journalKeeps.append(keep.id)
                journalKeepsImported += 1
            }
        }

        // People: his decisions about who is who, keyed by the row's own
        // stable id like a keep. A row already here by id is left alone --
        // it is his, possibly edited since. Entry ids go through the remap
        // so a page points at the local twins of its entries; an id that
        // resolves to nothing is kept as-is and simply renders no card
        // (the next indexer pass recomputes every `person` row's ids from
        // the entries that actually exist). The scan ledger is not in the
        // backup and is rebuilt by that pass.
        var journalPeopleImported = 0
        if !document.journalPeople.isEmpty {
            var knownPersonIDs = Set(((try? modelContext.fetch(FetchDescriptor<JournalPerson>())) ?? []).map(\.id))
            for personDTO in document.journalPeople {
                guard !knownPersonIDs.contains(personDTO.id) else { continue }
                knownPersonIDs.insert(personDTO.id)
                let person = JournalPerson(
                    name: personDTO.name,
                    kind: JournalPersonKind(rawValue: personDTO.kind) ?? .person,
                    aliases: personDTO.aliases,
                    entryIDs: personDTO.entryIDs.map { entryIDRemap[$0] ?? $0 },
                    firstSeen: personDTO.firstSeen,
                    lastSeen: personDTO.lastSeen
                )
                person.id = personDTO.id
                person.contactIdentifier = personDTO.contactIdentifier
                person.contactLinkedDate = personDTO.contactLinkedDate
                person.summary = personDTO.summary
                person.summaryFingerprint = personDTO.summaryFingerprint
                person.summaryBasis = personDTO.summaryBasis
                person.summaryGeneratedDate = personDTO.summaryGeneratedDate
                person.confirmedAt = personDTO.confirmedAt
                person.createdAt = personDTO.createdAt
                person.updatedAt = personDTO.updatedAt
                modelContext.insert(person)
                inserted.journalPeople.append(person.id)
                journalPeopleImported += 1
            }
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
            journalKeepsImported: journalKeepsImported,
            situationsImported: situationsImported,
            journalPeopleImported: journalPeopleImported,
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
    ///
    /// Restored journal entries are the one class this does NOT remove
    /// unconditionally. An entry he has since continued writing into -- text,
    /// `modifiedDate` or attachment count differing from its
    /// `RestoredEntryFingerprint` -- is his now, and this app has no delete
    /// path for his writing: it stays, its photos and keeps stay with it, and
    /// the count comes back in `UndoResult` so the banner can say "kept N"
    /// instead of implying a wholesale revert. A restored situation thread he
    /// has since messaged in stays for the same reason -- only the restored
    /// messages go, never the thread he kept talking in.
    @discardableResult
    static func undoImport(_ identifiers: InsertedIdentifiers, modelContext: ModelContext) -> UndoResult {
        var result = UndoResult()
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

        var keptEntryIDs = Set<UUID>()
        if !identifiers.personalWritingEntries.isEmpty {
            let fingerprints = Dictionary(identifiers.personalWritingEntries.map { ($0.entryID, $0) }, uniquingKeysWith: { first, _ in first })
            // One fetch by stable id, not `registeredModel(for:)`: that only
            // answers for objects this context still holds in memory, and a
            // silent nil here would mean Undo quietly did nothing.
            let liveEntries = (try? modelContext.fetch(FetchDescriptor<PersonalWritingEntry>())) ?? []
            for entry in liveEntries {
                guard let fingerprint = fingerprints[entry.id] else { continue }
                guard fingerprint.matches(entry) else {
                    keptEntryIDs.insert(entry.id)
                    result.entriesKept += 1
                    continue
                }
                for attachment in entry.attachments {
                    JournalAttachmentStore.delete(id: attachment.id)
                }
                modelContext.delete(entry)
            }
        }
        // A kept entry's photo rows are part of what he kept.
        for id in identifiers.journalAttachments {
            guard let attachment: JournalAttachment = modelContext.registeredModel(for: id) else { continue }
            if let entryID = attachment.entry?.id, keptEntryIDs.contains(entryID) { continue }
            modelContext.delete(attachment)
        }
        delete(identifiers.quizAttempts, as: QuizAttempt.self)

        if !identifiers.journalKeeps.isEmpty {
            let restoredKeepIDs = Set(identifiers.journalKeeps)
            let liveKeeps = (try? modelContext.fetch(FetchDescriptor<JournalKeep>())) ?? []
            for keep in liveKeeps where restoredKeepIDs.contains(keep.id) {
                if keptEntryIDs.contains(keep.entryID) {
                    result.keepsKept += 1
                    continue
                }
                modelContext.delete(keep)
            }
        }

        // Restored people rows go unconditionally: they are decisions the
        // backup carried, not his writing, and the indexer's next pass
        // rebuilds every `person` row from the entries that remain.
        if !identifiers.journalPeople.isEmpty {
            let restoredPersonIDs = Set(identifiers.journalPeople)
            let livePeople = (try? modelContext.fetch(FetchDescriptor<JournalPerson>())) ?? []
            for person in livePeople where restoredPersonIDs.contains(person.id) {
                modelContext.delete(person)
            }
        }

        // Saved before the situation pass so the message count below already
        // excludes the restored messages removed above -- a count that still
        // saw pending deletions would keep every restored thread.
        try? modelContext.save()

        if !identifiers.situations.isEmpty {
            let restoredSituationIDs = Set(identifiers.situations)
            let liveSituations = (try? modelContext.fetch(FetchDescriptor<SituationThread>())) ?? []
            for situation in liveSituations where restoredSituationIDs.contains(situation.id) {
                let threadID = situation.id
                let remaining = (try? modelContext.fetchCount(
                    FetchDescriptor<ChatMessage>(predicate: #Predicate<ChatMessage> { $0.bookID == threadID })
                )) ?? 0
                if remaining > 0 {
                    result.situationsKept += 1
                    continue
                }
                modelContext.delete(situation)
            }
            try? modelContext.save()
        }
        return result
    }

    /// What Undo deliberately left in place, so the caller can say so rather
    /// than implying the restore was reverted wholesale.
    struct UndoResult {
        var entriesKept = 0
        var keepsKept = 0
        var situationsKept = 0

        var keptAnything: Bool { entriesKept > 0 || keepsKept > 0 || situationsKept > 0 }
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
