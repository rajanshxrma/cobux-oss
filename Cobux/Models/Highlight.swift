import SwiftData
import Foundation

@Model
final class Highlight {
    var id: UUID = UUID()
    var text: String
    var chapter: String?
    var page: Int?
    var personalNote: String?
    var tags: [String]
    /// Liked from Flow -- the lightweight "keep this one" gesture, surfaced as
    /// its own section under More. Distinct from `isReminder` (a legacy
    /// notification flag) and from `personalNote` (which requires actually
    /// writing something): liking is one tap while reading, which is the only
    /// interaction cheap enough to actually happen mid-scroll.
    ///
    /// Optional with a default so SwiftData's lightweight migration adds it to
    /// every existing row without a migration plan -- the same shape every
    /// other additive field in this schema uses.
    var isLiked: Bool = false
    var isReminder: Bool
    var dateAdded: Date
    var embeddingData: Data?
    var book: Book?

    /// `chapter` (the free-text string above) is matched against `Chapter.title` at
    /// every read site -- a single typo in either place silently orphans every
    /// highlight in a chapter with no error anywhere (`Book.highlights(in:)`). This
    /// relationship is the real, stable link; `chapter` stays as the fallback for
    /// highlights that predate this fix and haven't been backfilled yet (or, rarely,
    /// whose chapter name never matched anything to begin with).
    @Relationship var chapterRef: Chapter?

    @Relationship var themes: [Theme] = []
    @Relationship(inverse: \QuizQuestion.sourceHighlights) var quizQuestions: [QuizQuestion] = []
    @Relationship(deleteRule: .cascade, inverse: \HighlightMemory.highlight) var memory: HighlightMemory?

    init(text: String, chapter: String? = nil, page: Int? = nil, personalNote: String? = nil, tags: [String] = [], isReminder: Bool = true, dateAdded: Date = .now) {
        self.id = UUID()
        self.text = text
        self.chapter = chapter
        self.page = page
        self.personalNote = personalNote
        self.tags = tags
        self.isReminder = isReminder
        self.dateAdded = dateAdded
    }

    /// Packs/unpacks `embeddingData` as a `[Float]` sentence vector for semantic search.
    var embedding: [Float]? {
        get {
            guard let embeddingData else { return nil }
            // One decoder for all three embedding-bearing models. It is still
            // unaligned-safe -- a `Data` slice out of SwiftData's own storage
            // carries no 4-byte alignment guarantee -- but it copies the whole
            // buffer at once instead of one `loadUnaligned` per element, which
            // is ~9.5x faster and matters because ranking decodes every stored
            // vector in the library on the way to an answer.
            return EmbeddingCodec.decode(embeddingData)
        }
        set {
            guard let newValue else {
                embeddingData = nil
                return
            }
            embeddingData = newValue.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }
}
