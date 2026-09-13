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
        contentHash(of: book.highlights(in: chapter))
    }

    /// The same hash, from highlights already in hand.
    ///
    /// Split out so a caller asking about many chapters does not pay for
    /// `book.highlights(in:)` -- a filter over the book's ENTIRE highlight
    /// array -- once per chapter, twice over (see
    /// `highlightsByChapterID(in:)`). Byte-for-byte identical output to the
    /// call above for the same chapter, which is load-bearing: this string is
    /// compared against `Chapter.quizGenerationHash`, so any drift would tell
    /// every chapter in the library it needs regenerating and put a paid API
    /// call behind it.
    static func contentHash(of highlights: [Highlight]) -> String {
        // Decorate-sort-undecorate. The comparator here used to be
        // `$0.id.uuidString < $1.id.uuidString`, which builds TWO fresh
        // 36-character Strings on every single comparison -- so sorting n
        // highlights allocated on the order of 2·n·log n throwaway strings
        // before the first character of the hash was written. Each id is
        // stringified exactly ONCE now, and that same string is reused as the
        // row's own leading field, so the sort only compares keys already in
        // hand.
        //
        // The output is byte-for-byte what it always was, which is
        // load-bearing rather than merely nice: the ordering key is the same
        // string, the row shape is the same "id|text|tags", the separator is
        // the same "||", and `UUID.description` IS `uuidString` (so `$0.key`
        // renders exactly what the `"\($0.id)"` interpolation it replaces
        // did). This string is compared against the stored
        // `Chapter.quizGenerationHash`; any drift at all would tell every
        // chapter in the library it needs regenerating and put a paid API
        // call behind each one.
        highlights
            .map { (key: $0.id.uuidString, highlight: $0) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)|\($0.highlight.text)|\($0.highlight.tags.joined(separator: ","))" }
            .joined(separator: "||")
    }

    static func needsGeneration(chapter: Chapter, in book: Book) -> Bool {
        needsGeneration(chapter: chapter, highlights: book.highlights(in: chapter))
    }

    /// The batched form, for a caller walking every chapter of a book.
    static func needsGeneration(chapter: Chapter, highlights: [Highlight]) -> Bool {
        guard !highlights.isEmpty else { return false }
        // A chapter that has never been generated has no stored hash, and
        // `nil != <any non-optional String>` is unconditionally true -- so the
        // old shape built the entire content hash (every highlight's full
        // text, concatenated) purely to throw the result away. That is most
        // chapters in most libraries. Same answer, none of the string.
        guard let stored = chapter.quizGenerationHash else { return true }
        return stored != contentHash(of: highlights)
    }

    /// Every chapter's highlights, in ONE pass over the book.
    ///
    /// `book.highlights(in: chapter)` filters the book's whole highlight array.
    /// Asking it per chapter is O(highlights x chapters), and
    /// `needsGeneration` used to ask it TWICE per chapter -- once for the
    /// emptiness guard and once inside `contentHash`. On the two medical
    /// textbooks (~1,300 highlights, ~116 chapters) that is roughly 300,000
    /// comparisons per book, and the Quiz shelf ran it for every book row on
    /// every body evaluation, so scrolling the shelf did it again and again.
    /// This does the same work once and hands out the buckets.
    ///
    /// Matching is deliberately identical to `Book.highlights(in:)`, including
    /// the parts that look redundant: a highlight with a `chapterRef` is
    /// matched ONLY by that relationship, and one without falls back to its
    /// free-text chapter name. The title map holds an ARRAY of chapter ids
    /// rather than one, because `highlights(in:)` would place a title-matched
    /// highlight in every chapter sharing that title, and a book with two
    /// same-named chapters must keep counting the way it counts today.
    ///
    /// Each bucket carries `highlights(in:)`'s `dateAdded` sort, so a bucket is
    /// substitutable for that call anywhere, not only in the hash (which
    /// re-sorts by id regardless).
    ///
    /// Main actor by inheritance -- these are `@Model` rows and they never
    /// leave it.
    static func highlightsByChapterID(in book: Book) -> [PersistentIdentifier: [Highlight]] {
        var idsByTitle: [String: [PersistentIdentifier]] = [:]
        for chapter in book.chapters {
            idsByTitle[chapter.title, default: []].append(chapter.persistentModelID)
        }

        var buckets: [PersistentIdentifier: [Highlight]] = [:]
        for highlight in book.highlights {
            if let chapterRef = highlight.chapterRef {
                buckets[chapterRef.persistentModelID, default: []].append(highlight)
            } else if let title = highlight.chapter, let ids = idsByTitle[title] {
                for id in ids { buckets[id, default: []].append(highlight) }
            }
        }
        for key in buckets.keys {
            buckets[key]?.sort { $0.dateAdded < $1.dateAdded }
        }
        return buckets
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
            // New cards are immediately due (reps == 0 keeps them in
            // DailyReviewService's "new" budget lane, not "review") --
            // matches FSRSService.migrateIfNeeded's exact convention.
            // Without this, dueQuestions() filters every freshly generated
            // question out of Daily Review forever, since it only surfaces
            // cards with a non-nil dueDate.
            question.dueDate = .now
            modelContext.insert(question)
            inserted += 1
        }

        chapter.quizGenerationHash = contentHash(for: chapter, in: book)
        // Was `try?` -- this function already wipes the chapter's existing
        // question bank (and their FSRS review history) a few lines above,
        // then silently swallowed a failure to save the replacement. Callers
        // already report `inserted` as a success count with no way to know
        // the save never actually landed; propagating lets them show a real
        // error instead of "Applied N question(s)" after quietly destroying
        // the old ones and keeping none of the new ones.
        try modelContext.save()
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

        // Settings' own footer promises this cap applies to "this month's estimated
        // generation spend" -- it was actually checking the combined chat+generation
        // total, so a normal month of chatting could exhaust the generation budget
        // before any generation happened, making the (usually cheap) thing that isn't
        // the real cost driver look like the expensive one.
        let decision = BudgetGuard(capDollars: budgetCapDollars).evaluate(
            alreadySpentDollars: UsageTracker.currentMonthEstimate(for: .generation),
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
