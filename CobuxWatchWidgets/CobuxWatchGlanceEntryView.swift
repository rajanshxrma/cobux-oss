import WidgetKit
import SwiftUI

struct CobuxWatchGlanceEntryView: View {
    var entry: WatchGlanceEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                circularBody
            case .accessoryRectangular:
                rectangularBody
            case .accessoryCorner:
                cornerBody
            default:
                inlineBody
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private var circularBody: some View {
        ZStack {
            AccessoryWidgetBackground()
            if entry.streakCount > 0 {
                VStack(spacing: 0) {
                    Image(systemName: "flame.fill")
                        .font(.caption2)
                    Text("\(entry.streakCount)")
                        .font(.headline)
                        .fontWeight(.bold)
                }
            } else {
                VStack(spacing: 0) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                    Text("\(entry.dueCount)")
                        .font(.headline)
                        .fontWeight(.bold)
                }
            }
        }
    }

    private var rectangularBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(entry.dueCount) due")
                .font(.caption)
                .fontWeight(.semibold)
            if let quote = entry.quoteText {
                Text(quote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var inlineBody: some View {
        Text("\(entry.dueCount) due · streak \(entry.streakCount)")
    }

    private var cornerBody: some View {
        Text("\(entry.dueCount)")
            .font(.headline)
            .widgetLabel {
                Text("due")
            }
    }
}
