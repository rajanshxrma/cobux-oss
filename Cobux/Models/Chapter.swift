import SwiftData
import Foundation

@Model
final class Chapter {
    /// Added for `BatchGenerationService` to persist "which chapter was this
    /// batch item for" across app launches (a batch can take up to ~24h) --
    /// `Book`/`Highlight` already have their own `id: UUID` for the same
    /// reason. Additive with a default, so existing stores just get a fresh
    /// UUID per chapter on first open after upgrading, no migration needed.
    var id: UUID = UUID()
    var title: String
    var summary: String
    var keyLessons: [String]
    var chapterNumber: Int?
    var book: Book?
    /// Manual "I've studied this" mark — additive field, defaults false, no
    /// migration needed. Powers a simple reading-progress indicator, most
    /// useful for large reference books (81/29 chapters) where "where did I
    /// leave off" is a real question.
    var isCompleted: Bool = false
    /// A hash of this chapter's current highlight content, set after quiz
    /// questions are generated — lets `QuizGenerationService` skip the (paid)
    /// regeneration call whenever nothing has actually changed since the last
    /// generation, the same cache-gating pattern `WisdomGraphService` already
    /// uses for AI tag-merging. nil = never generated.
    var quizGenerationHash: String?

    @Relationship(deleteRule: .cascade, inverse: \QuizQuestion.chapter)
    var quizQuestions: [QuizQuestion] = []

    init(title: String, summary: String, keyLessons: [String] = [], chapterNumber: Int? = nil, isCompleted: Bool = false) {
        self.id = UUID()
        self.title = title
        self.summary = summary
        self.keyLessons = keyLessons
        self.chapterNumber = chapterNumber
        self.isCompleted = isCompleted
    }
}
