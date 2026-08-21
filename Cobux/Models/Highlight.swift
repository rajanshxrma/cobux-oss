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
            // `loadUnaligned`, not `bindMemory` -- `bindMemory` requires the
            // buffer to already be 4-byte aligned for `Float`, which a `Data`
            // slice handed back from SwiftData's own storage isn't
            // guaranteed to be. `loadUnaligned` makes no such assumption.
            return embeddingData.withUnsafeBytes { rawBuffer in
                let count = rawBuffer.count / MemoryLayout<Float>.size
                return (0..<count).map { rawBuffer.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self) }
            }
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
