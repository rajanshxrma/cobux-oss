import Foundation
import SwiftData
import CobuxCore

/// Bridges `CobuxCore.ClozeGenerator` (pure logic, already tested against
/// real-shaped Robbins-style highlights) to real `Highlight`/`Chapter` data,
/// producing real `QuizQuestion` records at zero API cost. This is the free
/// tier that makes Quiz usable at real scale on Utkarsh's capped key and
/// works on his iPhone 13 (no Apple Intelligence needed — just
/// `NaturalLanguage`, already a dependency via `EmbeddingService`).
///
/// Runs automatically the first time a chapter is quizzed (see
/// `QuizScopeBuilderView.startWithoutGenerating`) — no separate button, no
/// cost-confirmation dialog, since there's nothing to confirm the cost of.
enum ClozeService {

    /// Generates cloze cards for every highlight in a chapter that doesn't
    /// already have one, gated by `BookContentProfile.suppliesClozeCards` —
    /// the structured `headword — body` + curated-tags shape this mines
    /// exists on any book authored with Tier A concept-highlights
    /// (propositional/academicReference/doctrine profiles); narrative and
    /// densePhilosophy books have no such structure and must never emit
    /// cloze cards from what are verbatim-only quotes. Safe to call every
    /// time a chapter is opened: already-covered highlights are skipped via
    /// the same `sourceHighlights` check `QuizGenerationService` uses for
    /// its own cache.
    static func generateIfNeeded(for chapter: Chapter, in book: Book, modelContext: ModelContext) {
        guard book.contentProfile.suppliesClozeCards else { return }

        let chapterHighlights = book.highlights(in: chapter)
        guard !chapterHighlights.isEmpty else { return }

        let alreadyCoveredHighlightIDs = Set(
            chapter.quizQuestions
                .filter { $0.generationSourceRaw == "cloze" }
                .flatMap { $0.sourceHighlights.map(\.id) }
        )
        let uncovered = chapterHighlights.filter { !alreadyCoveredHighlightIDs.contains($0.id) }
        guard !uncovered.isEmpty else { return }

        let siblingSources = chapterHighlights.map(clozeSource(from:))

        for highlight in uncovered {
            let source = clozeSource(from: highlight)
            let cards = ClozeGenerator.generate(
                from: source,
                siblingHighlights: siblingSources,
                similarity: { a, b in
                    guard let vecA = EmbeddingService.embed(a), let vecB = EmbeddingService.embed(b) else { return 0 }
                    return EmbeddingService.cosineSimilarity(vecA, vecB)
                }
            )

            for card in cards {
                let question = QuizQuestion(
                    book: book,
                    chapter: chapter,
                    questionType: card.isFreeRecall ? .application : .recallMCQ,
                    prompt: card.stem,
                    choices: card.isFreeRecall ? [] : shuffledChoices(answer: card.answer, distractors: card.distractors).choices,
                    correctAnswerIndex: card.isFreeRecall ? nil : shuffledChoices(answer: card.answer, distractors: card.distractors).answerIndex,
                    explanation: "Answer: \(card.answer)",
                    difficulty: 2,
                    topicTags: highlight.tags
                )
                question.generationSourceRaw = "cloze"
                question.sourceHighlights = [highlight]
                // See the matching comment in QuizGenerationService.applyGeneratedQuestions --
                // without this, DailyReviewService.dueQuestions never surfaces a freshly
                // generated card, since it filters on a non-nil dueDate.
                question.dueDate = .now
                modelContext.insert(question)
                chapter.quizQuestions.append(question)
            }
        }
    }

    private static func clozeSource(from highlight: Highlight) -> ClozeSourceHighlight {
        ClozeSourceHighlight(id: highlight.id.uuidString, text: highlight.text, tags: highlight.tags)
    }

    /// Shuffles the answer among its distractors once and returns both the
    /// final choice list and where the answer landed — computed once per
    /// card at generation time (not per-presentation, unlike the paid
    /// question pool) since a freshly on-device-generated card doesn't need
    /// the same anti-memorization shuffle QuizSessionView already applies
    /// to every presentation regardless of source.
    private static func shuffledChoices(answer: String, distractors: [String]) -> (choices: [String], answerIndex: Int) {
        var options = distractors
        let insertAt = Int.random(in: 0...options.count)
        options.insert(answer, at: insertAt)
        return (options, insertAt)
    }
}
