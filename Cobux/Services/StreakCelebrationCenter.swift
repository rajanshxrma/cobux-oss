import Foundation
import Observation

/// Bridges `StreakTracker.pendingMilestone` (a plain App-Group UserDefaults
/// value — `StreakTracker` stays Foundation-only for the widget/Watch targets)
/// into something SwiftUI can observe. `ContentView` overlays the milestone
/// celebration whenever `milestone` is non-nil; the activity call sites that
/// dismiss straight back to a tab (highlight save, spoken quiz) poke
/// `checkForPendingMilestone()` after recording, and quiz sessions that end on
/// `QuizResultsView` instead fold the milestone into that screen's own
/// celebration — one moment, never two stacked overlays.
@Observable
final class StreakCelebrationCenter {
    static let shared = StreakCelebrationCenter()
    private init() {}

    var milestone: Int?

    func checkForPendingMilestone() {
        let pending = StreakTracker.pendingMilestone
        if pending > 0 {
            milestone = pending
        }
    }

    func dismiss() {
        StreakTracker.clearPendingMilestone()
        milestone = nil
    }
}
