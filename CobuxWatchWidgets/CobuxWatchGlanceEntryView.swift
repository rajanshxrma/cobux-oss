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
        // Was entirely absent from every family in this target -- a tap fell
        // through to watchOS's default static "long look" of the complication's
        // own content instead of launching the app, which is why it looked
        // like it "does nothing." The app is deliberately one screen (per its
        // own design notes), so there's nowhere specific to route to beyond
        // just opening it -- no per-entry identity needed here, unlike the
        // iPhone widget.
        .widgetURL(URL(string: "cobux-watch://open"))
    }

    private var circularBody: some View {
        ZStack {
            AccessoryWidgetBackground()
            if !entry.hasSyncedData {
                Text("–")
                    .font(.headline)
                    .fontWeight(.bold)
            } else if entry.streakCount > 0 {
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
            if !entry.hasSyncedData {
                Text("Not synced")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("Open Cobux on iPhone")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
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
    }

    private var inlineBody: some View {
        Text(entry.hasSyncedData ? "\(entry.dueCount) due · streak \(entry.streakCount)" : "Open Cobux to sync")
    }

    private var cornerBody: some View {
        Group {
            if entry.hasSyncedData {
                Text("\(entry.dueCount)")
                    .font(.headline)
                    .widgetLabel {
                        Text("due")
                    }
            } else {
                Text("–")
                    .font(.headline)
                    .widgetLabel {
                        Text("sync")
                    }
            }
        }
    }
}
