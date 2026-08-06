import SwiftData
import Foundation

enum QuizQuestionType: String, Codable {
    case recallMCQ
    case exceptMCQ
    case trueFalse
    case application
}

@Model
final class QuizQuestion {
    var id: UUID = UUID()
    var book: Book?
    var chapter: Chapter?
    var questionTypeRaw: String
    var prompt: String
    var choices: [String]
    /// nil for `.application` — those are self-graded against `explanation`,
    /// there's no single fixed correct choice.
    var correctAnswerIndex: Int?
    var explanation: String
    var difficulty: Int
    var topicTags: [String]
    var dateGenerated: Date
    /// "claude" (the original paid path) | "cloze" (free, on-device,
    /// `ClozeService`) | "onDevice" (reserved for a future Apple
    /// Intelligence path) | "assembled" (reserved for discrimination
    /// drills assembled from data, no generation call at all). Lets
    /// Diagnostics/analytics distinguish cost-free questions from paid
    /// ones without needing a new `QuizQuestionType` case — a cloze card
    /// renders through the exact same `.recallMCQ`/`.application` UI paths.
    var generationSourceRaw: String = "claude"

    // MARK: FSRS scheduling state — per-card, not per-highlight.
    // A highlight can hold 4-6 independently testable facts (the old
    // `HighlightMemory` scheduled at highlight granularity, which meant
    // missing one fact reset the whole highlight's memory, dragging down
    // other facts the user already knew). Migrated from the old 5-box
    // Leitner system via `CobuxCore.FSRSMigration` — see `FSRSService`.

    /// Days; 0 means never scheduled (a brand-new card).
    var fsrsStability: Double = 0
    /// 1...10.
    var fsrsDifficulty: Double = 0
    var fsrsReps: Int = 0
    var fsrsLapses: Int = 0
    var lastReviewedAt: Date?
    /// nil = not yet introduced into the review queue.
    var dueDate: Date?
    var isSuspended: Bool = false

    @Relationship var sourceHighlights: [Highlight] = []

    var questionType: QuizQuestionType {
        get { QuizQuestionType(rawValue: questionTypeRaw) ?? .recallMCQ }
        set { questionTypeRaw = newValue.rawValue }
    }

    init(book: Book?, chapter: Chapter?, questionType: QuizQuestionType, prompt: String,
         choices: [String] = [], correctAnswerIndex: Int? = nil, explanation: String,
         difficulty: Int = 1, topicTags: [String] = [], dateGenerated: Date = .now) {
        self.id = UUID()
        self.book = book
        self.chapter = chapter
        self.questionTypeRaw = questionType.rawValue
        self.prompt = prompt
        self.choices = choices
        self.correctAnswerIndex = correctAnswerIndex
        self.explanation = explanation
        self.difficulty = difficulty
        self.topicTags = topicTags
        self.dateGenerated = dateGenerated
    }
}
