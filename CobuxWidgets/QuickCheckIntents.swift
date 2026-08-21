import AppIntents
import WidgetKit
import SwiftData
import Foundation

/// Flips the Quick Check widget's card face — pure defaults write, no
/// SwiftData, so the reveal feels instant.
struct RevealQuickCheckIntent: AppIntent {
    static var title: LocalizedStringResource = "Reveal Quick Check Answer"

    func perform() async throws -> some IntentResult {
        QuickCheckState.reveal()
        WidgetCenter.shared.reloadTimelines(ofKind: QuickCheckState.widgetKind)
        return .result()
    }
}

/// Grades the card showing on the Quick Check widget — a REAL review: the
/// same `FSRSService.recordReview` the app's quiz modes use, plus streak
/// credit, straight from the widget process (the container-open pattern
/// `CycleHighlightIntent` already proved safe here). Grades map gently, like
/// Flow's in-app quick checks: missed → .again, got it → .good.
struct GradeQuickCheckIntent: AppIntent {
    static var title: LocalizedStringResource = "Grade Quick Check"

    @Parameter(title: "Got It")
    var gotIt: Bool

    init() {}

    init(gotIt: Bool) {
        self.gotIt = gotIt
    }

    func perform() async throws -> some IntentResult {
        defer {
            WidgetCenter.shared.reloadTimelines(ofKind: QuickCheckState.widgetKind)
        }
        guard let questionID = QuickCheckState.currentQuestionID,
              let container = CobuxSchema.makeAppGroupContainer() else { return .result() }
        let context = ModelContext(container)

        // Single-row fetch by id — never a full table scan in the widget
        // process — and re-validated against the same gradeability rule the
        // provider's pool uses: a card deleted, suspended, or already
        // reviewed in-app since this timeline was built must NOT be graded
        // again (a second review seconds apart would skew its scheduling).
        var descriptor = FetchDescriptor<QuizQuestion>(predicate: #Predicate { $0.id == questionID })
        descriptor.fetchLimit = 1
        guard let question = (try? context.fetch(descriptor))?.first,
              QuickCheckState.isGradeable(question) else {
            // Stale pointer: just advance — the provider picks the next due
            // card on reload.
            QuickCheckState.setCurrent(nil)
            return .result()
        }

        FSRSService.recordReview(for: question, isCorrect: gotIt, confidence: nil)
        // Was `try? context.save()` -- a real save failure here used to advance
        // the card and credit the streak anyway, so the review was silently gone
        // with no signal at all (not even a stale-pointer case; the FSRS update
        // genuinely never landed). On failure, leave the card in place rather
        // than pretend the grade happened -- the next widget refresh just shows
        // the same card again, no different from never having tapped it.
        guard (try? context.save()) != nil else { return .result() }
        StreakTracker.recordActivityToday()

        // The running app's `@Query`-backed due counts have no other way to
        // learn about a write from this separate widget-extension process --
        // same cross-process gap `CaptureQuoteIntent`/`ShareQuoteView` already
        // solve for capturing a quote, just missing here until now.
        CrossProcessSync.markDirty()

        // Advance to the next card; the provider re-picks from the due pool.
        QuickCheckState.setCurrent(nil)
        return .result()
    }
}
