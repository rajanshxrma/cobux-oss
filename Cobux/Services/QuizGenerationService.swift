import SwiftData
import Foundation
import CobuxCore

enum QuizGenerationError: LocalizedError {
    case invalidResponse
    case budgetExceeded(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Couldn't parse quiz questions from Claude's response. Try again."
        case .budgetExceeded(let reason):
            return reason
        }
    }
}

private struct GeneratedQuestionDTO: Codable {
    let questionType: String
    let prompt: String
    let choices: [String]
    let correctAnswerIndex: Int?
    let explanation: String
    let difficulty: Int
    let topicTags: [String]
    let sourceHighlightIndexes: [Int]
}

/// The structured-output wrapper — Anthropic's `json_schema` format requires
/// an object at the root, so the questions array is nested under a single
/// `questions` key rather than being the top-level response shape.
private struct GeneratedQuestionBatch: Codable {
    let questions: [GeneratedQuestionDTO]
}

/// Turns a chapter's own highlights into a cached bank of quiz questions --
/// one Claude call per chapter, ever, re-run only when that chapter's
/// highlight content actually changes. Same cache-gating discipline as
/// `WisdomGraphService.mergeSimilarTags`: hash the source content, skip the
/// paid call if the hash matches what's already stored.
///
/// Two callers use this: `QuizScopeBuilderView`'s on-demand flow, which
/// calls `generateQuestions` directly for an answer in seconds; and
/// `BatchGenerationService`, which submits the same prompt shape (via
/// `requestPieces`) through the Batch API for whole-book background runs,
/// then applies results back through `applyGeneratedQuestions` -- the exact
/// decode/insert step this file already does for the live path, so both
/// paths stay identical in how a response becomes `QuizQuestion` rows.
enum QuizGenerationService {
    /// Backing keys for the two Settings-exposed generation controls. Kept
    /// here (not just in `SettingsView`) since this is the sole reader.
    private static let qualityDefaultsKey = "questionQualityRaw"
    private static let budgetCapDefaultsKey = "generationBudgetCapDollars"

    static var currentQuality: QuestionQuality {
        QuestionQuality(rawValue: UserDefaults.standard.string(forKey: qualityDefaultsKey) ?? "") ?? .balanced
    }

    static var budgetCapDollars: Double {
        let stored = UserDefaults.standard.double(forKey: budgetCapDefaultsKey)
        return stored > 0 ? stored : BudgetGuard.defaultCapDollars
    }

    static func contentHash(for chapter: Chapter, in book: Book) -> String {
        book.highlights(in: chapter)
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { "\($0.id)|\($0.text)|\($0.tags.joined(separator: ","))" }
            .joined(separator: "||")
    }

    static func needsGeneration(chapter: Chapter, in book: Book) -> Bool {
        let highlights = book.highlights(in: chapter)
        guard !highlights.isEmpty else { return false }
        return chapter.quizGenerationHash != contentHash(for: chapter, in: book)
    }

    /// Rough one-time cost estimate shown before spending money -- same
    /// spirit as `WisdomGraphView`'s merge-confirmation alert. This is a
    /// fast, offline, synchronous heuristic for the UI's cost preview;
    /// `generateQuestions` separately gets a precise `count_tokens` figure
    /// right before actually spending, since that's the number the budget
    /// guard should act on.
    static func estimatedCost(for chapter: Chapter, in book: Book) -> Double {
        let count = book.highlights(in: chapter).count
        guard count > 0 else { return 0 }
        let questionCount = Double(min(15, max(5, count / 3)))
        // ~120 input tokens/highlight + ~600 fixed overhead, ~180 output tokens/question.
        let inputTokens = Int(Double(count) * 120 + 600)
        let outputTokens = Int(questionCount * 180)
        let model = currentQuality.model(isExamStyle: book.contentProfile.isExamStyleQuiz)
        return UsageTracker.estimatedCost(inputTokens: inputTokens, outputTokens: outputTokens, cacheCreationTokens: 0, cacheReadTokens: 0, model: model.rateTableModel)
    }

    static let questionsJSONSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "questions": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "questionType": ["type": "string"],
                        "prompt": ["type": "string"],
                        "choices": ["type": "array", "items": ["type": "string"]],
                        "correctAnswerIndex": ["type": ["integer", "null"]],
                        "explanation": ["type": "string"],
                        "difficulty": ["type": "integer"],
                        "topicTags": ["type": "array", "items": ["type": "string"]],
                        "sourceHighlightIndexes": ["type": "array", "items": ["type": "integer"]]
                    ],
                    "required": ["questionType", "prompt", "choices", "explanation", "difficulty", "topicTags", "sourceHighlightIndexes"],
                    "additionalProperties": false
                ]
            ]
        ],
        "required": ["questions"],
        "additionalProperties": false
    ]

    struct RequestPieces {
        let prompt: String
        let systemPrompt: String
        let model: CobuxModelID
        let questionCount: Int
    }

    /// Builds the identical prompt/system-prompt/model/question-count a
    /// live or batched generation call needs for this chapter -- the single
    /// source of truth both `generateQuestions` and `BatchGenerationService`
    /// build their request from, so the two paths can never drift apart in
    /// what they actually ask Claude for.
    static func requestPieces(for chapter: Chapter, in book: Book) -> RequestPieces? {
        let highlights = book.highlights(in: chapter)
        guard !highlights.isEmpty else { return nil }

        let isExamStyle = book.contentProfile.isExamStyleQuiz
        let questionCount = min(15, max(5, highlights.count / 3))
        let model = currentQuality.model(isExamStyle: isExamStyle)

        let highlightList = highlights.enumerated()
            .map { index, h in "\(index). \(h.text)" + (h.tags.isEmpty ? "" : " [tags: \(h.tags.joined(separator: ", "))]") }
            .joined(separator: "\n")

        let template = isExamStyle ? PromptTemplates.quizGenerationExam : PromptTemplates.quizGenerationReflective
        let prompt = String(format: template, book.title, chapter.title, highlightList, questionCount)
        let systemPrompt = "You are a precise quiz-question generator for a study app."

        return RequestPieces(prompt: prompt, systemPrompt: systemPrompt, model: model, questionCount: questionCount)
    }

    /// Decodes a structured-output response and rebuilds this chapter's
    /// cached question bank from it -- the same wipe-then-repopulate
    /// approach `WisdomGraphService` uses for Themes. Shared by the live
    /// path below and `BatchGenerationService`'s result-application step.
    @discardableResult
    static func applyGeneratedQuestions(from responseText: String, to chapter: Chapter, in book: Book, modelContext: ModelContext) throws -> Int {
        let highlights = book.highlights(in: chapter)
        guard let data = responseText.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(GeneratedQuestionBatch.self, from: data) else {
            throw QuizGenerationError.invalidResponse
        }

        for old in chapter.quizQuestions { modelContext.delete(old) }

        var inserted = 0
        for dto in decoded.questions {
            let sources = dto.sourceHighlightIndexes.compactMap { highlights.indices.contains($0) ? highlights[$0] : nil }
            let question = QuizQuestion(
                book: book, chapter: chapter,
                questionType: QuizQuestionType(rawValue: dto.questionType) ?? .recallMCQ,
                prompt: dto.prompt, choices: dto.choices,
                correctAnswerIndex: dto.correctAnswerIndex,
                explanation: dto.explanation, difficulty: dto.difficulty,
                topicTags: dto.topicTags
            )
            question.sourceHighlights = sources
            modelContext.insert(question)
            inserted += 1
        }

        chapter.quizGenerationHash = contentHash(for: chapter, in: book)
        try? modelContext.save()
        return inserted
    }

    @discardableResult
    static func generateQuestions(for chapter: Chapter, in book: Book, claudeService: ClaudeService, modelContext: ModelContext) async throws -> Int {
        guard let pieces = requestPieces(for: chapter, in: book) else { return 0 }

        // count_tokens gives the real input-token figure for this exact
        // prompt; output tokens still can't be known before generation
        // happens, so that half stays the same per-question heuristic as
        // the UI preview above. Falls back to the heuristic input estimate
        // if the count_tokens call itself fails (offline, bad key, etc.) --
        // an estimate failing shouldn't block generation on its own; the
        // live generation call below will surface the real error if the key
        // is actually bad.
        let highlightCount = book.highlights(in: chapter).count
        let heuristicInputTokens = Int(Double(highlightCount) * 120 + 600)
        let inputTokens = (try? await claudeService.countGenerationTokens(userMessage: pieces.prompt, systemPrompt: pieces.systemPrompt, model: pieces.model)) ?? heuristicInputTokens
        let outputTokens = Int(Double(pieces.questionCount) * 180)
        let proposedCost = UsageTracker.estimatedCost(
            inputTokens: inputTokens, outputTokens: outputTokens,
            cacheCreationTokens: 0, cacheReadTokens: 0, model: pieces.model.rateTableModel
        )

        let decision = BudgetGuard(capDollars: budgetCapDollars).evaluate(
            alreadySpentDollars: UsageTracker.currentMonthEstimate(),
            proposedCostDollars: proposedCost
        )
        guard decision.allowed else {
            throw QuizGenerationError.budgetExceeded(decision.blockReason ?? "This generation call would exceed your monthly budget.")
        }

        let response = try await claudeService.generateStructured(
            userMessage: pieces.prompt, systemPrompt: pieces.systemPrompt, model: pieces.model, jsonSchema: questionsJSONSchema
        )

        return try applyGeneratedQuestions(from: response, to: chapter, in: book, modelContext: modelContext)
    }
}
