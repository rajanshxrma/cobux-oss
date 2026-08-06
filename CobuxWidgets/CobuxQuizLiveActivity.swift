import ActivityKit
import WidgetKit
import SwiftUI

struct CobuxQuizLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CobuxQuizActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(context.attributes.scopeDescription)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Label {
                        Text(timerInterval: Date.now...context.state.endDate, countsDown: true)
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
                        Text(timerInterval: Date.now...context.state.endDate, countsDown: true)
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
                Text(timerInterval: Date.now...context.state.endDate, countsDown: true)
                    .font(.caption2.monospacedDigit())
                    .frame(width: 40)
            } minimal: {
                Image(systemName: "timer")
            }
        }
    }
}
