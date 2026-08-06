import WidgetKit
import SwiftUI

struct CobuxWidgetEntryView: View {
    var entry: HighlightProvider.Entry
    @Environment(\.widgetFamily) private var family

    private var accent: Color { Color(hex: entry.coverColorHex) }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Text(entry.quote)
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    if StreakTracker.currentStreak > 0 {
                        VStack(spacing: 0) {
                            Image(systemName: "flame.fill")
                                .font(.caption2)
                            Text("\(StreakTracker.currentStreak)")
                                .font(.headline)
                                .fontWeight(.bold)
                        }
                    } else {
                        Image(systemName: "book.pages")
                    }
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.quote)
                        .font(.caption2)
                        .lineLimit(3)
                    Text(entry.bookTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            case .systemLarge:
                largeBody
            case .systemMedium:
                mediumBody
            default:
                smallBody
            }
        }
        .containerBackground(for: .widget) {
            backgroundView
        }
        .widgetURL(URL(string: "cobux://chat"))
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch family {
        case .accessoryInline, .accessoryCircular, .accessoryRectangular:
            Color.clear
        default:
            LinearGradient(
                colors: [accent.opacity(0.16), Color(.systemBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "quote.opening")
                .font(.caption)
                .foregroundStyle(accent)

            Text(entry.quote)
                .font(.system(.footnote, design: .serif))
                .italic()
                .lineLimit(5)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 0)

            Text(entry.bookTitle)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(4)
    }

    private var mediumBody: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(accent.opacity(0.7))
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.quote)
                    .font(.system(.subheadline, design: .serif))
                    .italic()
                    .lineLimit(4)
                    .minimumScaleFactor(0.85)

                Text(citation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(4)
    }

    private var largeBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "quote.opening")
                .font(.title3)
                .foregroundStyle(accent)

            Text(entry.quote)
                .font(.system(.body, design: .serif))
                .italic()
                .lineLimit(9)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 0)

            Rectangle()
                .fill(accent.opacity(0.3))
                .frame(height: 1)

            Text(citation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(4)
    }

    private var citation: String {
        var parts = [entry.bookTitle]
        if !entry.author.isEmpty { parts.append(entry.author) }
        if let chapter = entry.chapter { parts.append(chapter) }
        return parts.joined(separator: " · ")
    }
}

struct CobuxHighlightWidget: Widget {
    let kind: String = "CobuxHighlightWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HighlightProvider()) { entry in
            CobuxWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Book Wisdom")
        .description("A rotating highlight from your Cobux library, or your daily streak on the Lock Screen. Tap to open Cobux AI.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryInline, .accessoryCircular
        ])
    }
}
