import SwiftData
import Foundation

/// Whole-book, background quiz-question generation via Anthropic's Batch
/// API — roughly half the per-token cost of `QuizGenerationService`'s live
/// calls, in exchange for turnaround measured in minutes-to-hours rather
/// than seconds. This is the path for "generate everything Robbins still
/// needs, cheaply, overnight," not the on-demand "generate this one chapter
/// right before starting a quiz right now" flow in `QuizScopeBuilderView`,
/// which needs an answer immediately and stays on the live call.
///
/// Only one batch runs at a time — simpler to reason about, cancel, and
/// surface in the UI than a queue of concurrent batches, and there's no
/// real need for more than one in flight on a single-key, single-device app.
/// The in-flight job's bookkeeping (which chapters, which batch ID) is
/// persisted to `UserDefaults` rather than SwiftData, since it's ephemeral
/// process state, not user content — it needs to survive the app being
/// closed while Anthropic processes the batch (up to ~24h), not live
/// forever the way a book or highlight does.
enum BatchGenerationService {
    private static let pendingKey = "cobux.pendingBatchGeneration"

    struct PendingBatch: Codable {
        let batchID: String
        let bookTitle: String
        let chapterIDs: [UUID]
        let submittedAt: Date
        /// Chapter UUID string (matches each item's customID) -> the model it was actually
        /// submitted with. A batch mixes Haiku (bulk) and Sonnet (clinical vignettes) items
        /// per `QuestionQuality`, so this is what lets usage recording price each result
        /// correctly instead of assuming one model for the whole batch.
        var modelsByChapterID: [String: CobuxModelID] = [:]
    }

    enum BatchGenerationError: LocalizedError {
        case alreadyInProgress
        case noneNeeded
        var errorDescription: String? {
            switch self {
            case .alreadyInProgress: return "A background generation batch is already running. Wait for it to finish, or cancel it, before starting another."
            case .noneNeeded: return "Nothing in this scope needs generation."
            }
        }
    }

    struct Progress {
        let processing: Int
        let succeeded: Int
        let errored: Int
        let isDone: Bool
    }

    struct ApplyResult {
        let bookTitle: String
        let chaptersUpdated: Int
        let questionsInserted: Int
        let chaptersFailed: Int
    }

    static var pendingBatch: PendingBatch? {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return nil }
        return try? JSONDecoder().decode(PendingBatch.self, from: data)
    }

    private static func savePending(_ batch: PendingBatch?) {
        guard let batch else {
            UserDefaults.standard.removeObject(forKey: pendingKey)
            return
        }
        if let data = try? JSONEncoder().encode(batch) {
            UserDefaults.standard.set(data, forKey: pendingKey)
        }
    }

    /// Submits every chapter in `chapters` that actually needs generation as
    /// one Batch API call. Throws if a batch is already in flight (call
    /// `cancel` first) or if nothing in scope needs it.
    static func submit(chapters: [Chapter], in book: Book, claudeService: ClaudeService) async throws {
        guard pendingBatch == nil else { throw BatchGenerationError.alreadyInProgress }

        let needing = chapters.filter { QuizGenerationService.needsGeneration(chapter: $0, in: book) }
        guard !needing.isEmpty else { throw BatchGenerationError.noneNeeded }

        var items: [ClaudeService.BatchItem] = []
        var chapterIDs: [UUID] = []
        var modelsByChapterID: [String: CobuxModelID] = [:]
        for chapter in needing {
            guard let pieces = QuizGenerationService.requestPieces(for: chapter, in: book) else { continue }
            items.append(ClaudeService.BatchItem(
                customID: chapter.id.uuidString,
                userMessage: pieces.prompt,
                systemPrompt: pieces.systemPrompt,
                model: pieces.model,
                jsonSchema: QuizGenerationService.questionsJSONSchema
            ))
            chapterIDs.append(chapter.id)
            modelsByChapterID[chapter.id.uuidString] = pieces.model
        }
        guard !items.isEmpty else { throw BatchGenerationError.noneNeeded }

        let handle = try await claudeService.submitBatch(items)
        savePending(PendingBatch(batchID: handle.id, bookTitle: book.title, chapterIDs: chapterIDs, submittedAt: .now, modelsByChapterID: modelsByChapterID))
    }

    /// Polls the in-flight batch's current state without applying anything.
    /// Returns `nil` if nothing is pending.
    static func checkProgress(claudeService: ClaudeService) async throws -> Progress? {
        guard let pending = pendingBatch else { return nil }
        let status = try await claudeService.batchStatus(ClaudeService.BatchHandle(id: pending.batchID))
        return Progress(processing: status.processing, succeeded: status.succeeded, errored: status.errored, isDone: status.isDone)
    }

    /// If the pending batch has finished, fetches its results, applies each
    /// one to the matching chapter's cached question bank (same decode/insert
    /// path the live call uses, via `QuizGenerationService.applyGeneratedQuestions`),
    /// and clears the pending record. Returns `nil` if there's no pending
    /// batch or it isn't done yet — safe to call speculatively, e.g. on
    /// every app launch or Settings appearance, to pick up a batch that
    /// finished while the app was closed.
    @discardableResult
    static func applyResultsIfDone(claudeService: ClaudeService, modelContext: ModelContext) async throws -> ApplyResult? {
        guard let pending = pendingBatch else { return nil }
        let handle = ClaudeService.BatchHandle(id: pending.batchID)
        let status = try await claudeService.batchStatus(handle)
        guard status.isDone else { return nil }

        defer { savePending(nil) }

        guard let resultsURL = status.resultsURL else {
            // Ended with no results URL (e.g. every item expired/canceled) --
            // nothing to apply, but the job is over either way.
            return ApplyResult(bookTitle: pending.bookTitle, chaptersUpdated: 0, questionsInserted: 0, chaptersFailed: status.errored + status.processing)
        }
        let results = try await claudeService.batchResults(handle, resultsURL: resultsURL, modelByCustomID: pending.modelsByChapterID)

        var chaptersUpdated = 0
        var questionsInserted = 0
        var chaptersFailed = 0

        for result in results {
            guard let chapterID = UUID(uuidString: result.customID) else { chaptersFailed += 1; continue }
            var descriptor = FetchDescriptor<Chapter>(predicate: #Predicate { $0.id == chapterID })
            descriptor.fetchLimit = 1
            guard let chapter = try? modelContext.fetch(descriptor).first, let book = chapter.book else {
                chaptersFailed += 1
                continue
            }

            guard result.succeeded, let text = result.text else {
                chaptersFailed += 1
                continue
            }
            guard let inserted = try? QuizGenerationService.applyGeneratedQuestions(from: text, to: chapter, in: book, modelContext: modelContext) else {
                chaptersFailed += 1
                continue
            }
            chaptersUpdated += 1
            questionsInserted += inserted
        }

        return ApplyResult(bookTitle: pending.bookTitle, chaptersUpdated: chaptersUpdated, questionsInserted: questionsInserted, chaptersFailed: chaptersFailed)
    }

    /// Cancels the in-flight batch. Items already completed before the
    /// cancel still finish and bill (Anthropic's own semantics); only
    /// unstarted/in-progress items stop. Clears the pending record either way.
    static func cancel(claudeService: ClaudeService) async throws {
        guard let pending = pendingBatch else { return }
        try await claudeService.cancelBatch(ClaudeService.BatchHandle(id: pending.batchID))
        savePending(nil)
    }
}
