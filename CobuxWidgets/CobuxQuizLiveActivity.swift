import ActivityKit
import WidgetKit
import SwiftUI

struct CobuxQuizLiveActivity: Widget {
    // `Text(timerInterval:)` takes a `ClosedRange<Date>`, and `...` traps at
    // runtime if the lower bound is after the upper bound. The app only calls
    // `endLiveActivity()` from its own in-process exam timer, which does not
    // run while the app is backgrounded or suspended -- exactly the state a
    // user locking their phone to watch the Lock Screen countdown puts it in,
    // which is the entire point of this Live Activity. Once `endDate` (the
    // last value the app pushed) elapses while the app is still suspended,
    // this view keeps re-rendering with `Date.now > context.state.endDate`,
    // and every one of the three `timerInterval` uses below would crash the
    // widget extension on the Lock Screen / Dynamic Island with no way for
    // the user to recover except force-quitting Cobux. Clamping the upper
    // bound to never precede `now` keeps the countdown honest (it reads
    // 00:00 instead of going negative) and keeps the range legal.
    private func countdownRange(to endDate: Date) -> ClosedRange<Date> {
        let now = Date.now
        return now...max(endDate, now)
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CobuxQuizActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(context.attributes.scopeDescription)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Label {
                        Text(timerInterval: countdownRange(to: context.state.endDate), countsDown: true)
                    } icon: {
                        Image(systemName: "timer")
                    }
                    .font(.subheadline.monospacedDigit())
                }
                ProgressView(value: Double(context.state.currentQuestionIndex), total: Double(max(context.attributes.totalQuestions, 1)))
                    .tint(Color.cobuxAccent)
                Text("Question \(context.state.currentQuestionIndex + 1) of \(context.attributes.totalQuestions) — \(context.state.correctCount) correct so far")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("Q\(context.state.currentQuestionIndex + 1)/\(context.attributes.totalQuestions)")
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Label {
                        Text(timerInterval: countdownRange(to: context.state.endDate), countsDown: true)
                    } icon: {
                        Image(systemName: "timer")
                    }
                    .font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.scopeDescription)
                        .font(.caption2)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: Double(context.state.currentQuestionIndex), total: Double(max(context.attributes.totalQuestions, 1)))
                        .tint(Color.cobuxAccent)
                }
            } compactLeading: {
                Text("Q\(context.state.currentQuestionIndex + 1)")
                    .font(.caption2)
            } compactTrailing: {
                Text(timerInterval: countdownRange(to: context.state.endDate), countsDown: true)
                    .font(.caption2.monospacedDigit())
                    .frame(width: 40)
            } minimal: {
                Image(systemName: "timer")
            }
        }
    }
}
