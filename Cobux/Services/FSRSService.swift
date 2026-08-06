import Foundation
import CobuxCore

/// Bridges `QuizQuestion` (a SwiftData `@Model`, which `CobuxCore` can't
/// depend on) to the pure `CobuxCore.FSRS` scheduler. This is the one place
/// that reads/writes a question's FSRS fields — the actual math lives in
/// CobuxCore, already covered by golden-vector tests against the published
/// reference implementation.
enum FSRSService {

    static func cardState(for question: QuizQuestion) -> FSRSCardState {
        FSRSCardState(
            stability: question.fsrsStability,
            difficulty: question.fsrsDifficulty,
            reps: question.fsrsReps,
            lapses: question.fsrsLapses
        )
    }

    /// One-time seed from the old per-highlight Leitner boxes, for a question
    /// that's never been scheduled under FSRS yet. Safe to call unconditionally
    /// — a no-op for a question that already has real FSRS history.
    static func migrateIfNeeded(_ question: QuizQuestion) {
        guard question.fsrsReps == 0, question.dueDate == nil else { return }
        let boxes = question.sourceHighlights.compactMap { $0.memory?.box }
        guard !boxes.isEmpty else { return }

        let seeded = FSRSMigration.seedState(fromSourceHighlightBoxes: boxes)
        question.fsrsStability = seeded.stability
        question.fsrsDifficulty = seeded.difficulty
        question.fsrsReps = seeded.reps
        question.fsrsLapses = seeded.lapses
        // Due immediately -- migrated cards join the front of the queue
        // rather than silently vanishing until manually re-quizzed.
        question.dueDate = .now
    }

    /// Maps this app's existing grading signal (MCQ/true-false correctness,
    /// plus the confidence chip already collected for the self-graded
    /// `.application` type) onto FSRS's four-grade model. Wrong is always
    /// "Again" with no taps needed; the three confidence levels map to
    /// Hard/Good/Easy only on a correct answer, matching the confidence
    /// chips' existing 1(guessed)/2(unsure)/3(confident) values.
    static func grade(isCorrect: Bool, confidence: Int?) -> FSRSGrade {
        guard isCorrect else { return .again }
        switch confidence {
        case 1: return .hard
        case 3: return .easy
        default: return .good
        }
    }

    /// Schedules the next review for a question and writes the result back.
    /// - Parameters:
    ///   - maxIntervalDays: caps how far out the next review can land — Exam
    ///     Countdown mode (Phase 4) sets this to days-until-exam so nothing is
    ///     ever scheduled past it; defaults to effectively unbounded.
    @discardableResult
    static func recordReview(
        for question: QuizQuestion,
        isCorrect: Bool,
        confidence: Int?,
        desiredRetention: Double = 0.9,
        maxIntervalDays: Int = 36500,
        now: Date = .now
    ) -> FSRSReviewResult {
        migrateIfNeeded(question)

        let elapsedDays: Double
        if let lastReviewedAt = question.lastReviewedAt {
            elapsedDays = max(0, now.timeIntervalSince(lastReviewedAt) / 86400)
        } else {
            elapsedDays = 0
        }

        let grade = grade(isCorrect: isCorrect, confidence: confidence)
        let result = FSRS.schedule(
            state: cardState(for: question),
            grade: grade,
            elapsedDays: elapsedDays,
            desiredRetention: desiredRetention,
            maxIntervalDays: maxIntervalDays,
            now: now,
            cardSeed: question.id.hashValue.magnitude64
        )

        question.fsrsStability = result.state.stability
        question.fsrsDifficulty = result.state.difficulty
        question.fsrsReps = result.state.reps
        question.fsrsLapses = result.state.lapses
        question.lastReviewedAt = now
        question.dueDate = result.dueDate

        return result
    }
}

private extension Int {
    /// `FSRS.schedule`'s `cardSeed` wants a `UInt64` for its deterministic
    /// fuzz — `hashValue` is an `Int` and can be negative, so this maps it
    /// into the full unsigned range instead of crashing on a bad bit pattern.
    var magnitude64: UInt64 { UInt64(bitPattern: Int64(self)) }
}
