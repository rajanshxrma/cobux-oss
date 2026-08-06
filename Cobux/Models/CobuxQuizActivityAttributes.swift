import ActivityKit
import Foundation

/// Shared between the main app (starts/updates/ends the activity from
/// `QuizSessionView`) and the widget extension (renders it) -- lives under
/// Models since both targets already include this folder as source.
struct CobuxQuizActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var currentQuestionIndex: Int
        var correctCount: Int
        /// Countdown end -- rendered with `Text(timerInterval:countsDown:)` in
        /// the widget for a smooth system-driven countdown, rather than
        /// pushing per-second `Activity.update` calls (which ActivityKit
        /// rate-limits well below once-per-second anyway).
        var endDate: Date
    }

    var scopeDescription: String
    var totalQuestions: Int
}
