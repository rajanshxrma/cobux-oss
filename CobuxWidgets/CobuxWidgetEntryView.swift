import WidgetKit
import SwiftUI
import AppIntents

struct CobuxWidgetEntryView: View {
    var entry: HighlightProvider.Entry
    @Environment(\.widgetFamily) private var family

    private var accent: Color { Color(hex: entry.coverColorHex) }

    /// The configured book, in the form the interactive intents carry it.
    ///
    /// Every `Button(intent:)` below is constructed with this value, which is
    /// what makes a tap land on the right history lane and the right pool. It
    /// comes off the entry, and the entry came from this specific widget's own
    /// timeline build, so two widgets configured differently produce two
    /// differently-parameterized buttons even though they share one view type
    /// and one widget kind. See `CycleHighlightIntent` for the full reasoning.
    private var scopeKey: String? { entry.scopeBookID?.uuidString }


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
        // Tapping the widget CHANGES THE HIGHLIGHT. It used to open the app, with cycling
        // available only from a deliberately tiny corner button -- reported twice, the
        // second time as "still hasn't been fixed... important fix this in the last way
        // whatever build please". The old comment argued the body had to stay a
        // `.widgetURL` so open-to-book kept working; that ranked a secondary action above
        // the one he asked for. Open-to-book is not lost, it moves to the corner the
        // cycling button used to occupy, so both actions still exist -- just the right
        // way round. Lock-screen accessory families keep `.widgetURL`, since they are too
        // small for a second target and tapping one is unambiguously "take me there".
        .modifier(WidgetTapBehavior(family: family, destination: tapDestination, scopeKey: scopeKey))
    }

    /// Used to hardcode `cobux://chat` for every family -- the widget always
    /// shows a highlight from a specific book, but tapping it opened only the
    /// generic Chat tab, never routing to the book the quote actually came
    /// from. Falls back to the old generic destination for the placeholder
    /// entry (no real book behind it).
    ///
    /// The highlight ID rides along as a trailing `/highlight/<uuid>` path
    /// component so the app can also pre-fill the composer with this exact
    /// quote — tapping a quote you want to think about should land you ready
    /// to discuss it, not on an empty text box you have to retype it into.
    /// Appending rather than replacing keeps the URL backward-compatible:
    /// `ContentView` reads the book ID from the same position it always did,
    /// so a widget still showing a pre-update timeline entry keeps working.
    private var tapDestination: URL {
        guard let bookID = entry.bookID else { return URL(string: "cobux://chat")! }
        guard let highlightID = entry.highlightID else {
            return CobuxDeepLink.bookURL(bookID: bookID)
        }
        return CobuxDeepLink.highlightURL(bookID: bookID, highlightID: highlightID)
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
                // WidgetKit cannot scroll -- there is no interactive scroll
                // view in a widget, full stop -- so a long highlight can only
                // fit by shrinking. Rajan: "some of the highlights in the iOS
                // widget are not fully able to be read." The old caps (4-5
                // lines, and only 15%% of shrink allowed) truncated real
                // highlights well before the space ran out. More lines plus a
                // genuinely permissive floor lets a long quote shrink to fit
                // instead of being cut off; short quotes are unaffected, since
                // scaling only engages when the text would otherwise clip.
                .lineLimit(8)
                .minimumScaleFactor(0.6)

            Spacer(minLength: 0)

            footerRow(Text(entry.bookTitle).fontWeight(.medium))
        }
        .padding(4)
    }

    /// Citation on the left, controls on the right, in one row.
    ///
    /// The citation used to be a plain `Text` with a hand-computed trailing
    /// padding, dodging controls that lived in an `.overlay` and therefore took
    /// part in no layout at all. That is why it read as wedged awkwardly between
    /// the buttons -- "the title... is weirdly formatted placed bw the buttons
    /// at the both bottom ends". As siblings in an `HStack` the citation simply
    /// truncates where the controls begin, correctly, at any width and on every
    /// family, with no reserved-width constant to keep in sync.
    private func footerRow(_ citation: Text) -> some View {
        HStack(alignment: .center, spacing: 6) {
            citation
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            controlCluster
        }
    }


    /// Shares the exact quote showing, as its `cobux://` deep link -- tapping
    /// it on the recipient's own phone (if they have Cobux) opens straight to
    /// this highlight, the same destination this widget's own tap already
    /// goes to. `systemMedium`/`systemLarge` only: `systemSmall`'s two
    /// corners are already spoken for (`shuffleButton`, `historyChevrons`),
    /// and it's the tightest layout of the three to begin with -- see
    /// that family is the tightest layout and gets protected rather than crowded further.
    @ViewBuilder
    private var shareButton: some View {
        if let bookID = entry.bookID, let highlightID = entry.highlightID {
            ShareLink(item: CobuxDeepLink.highlightURL(bookID: bookID, highlightID: highlightID)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.caption2)
                    .foregroundStyle(accent)
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
    }

    /// Every control in the cluster is this exact glyph -- one size, one shape,
    /// one tint. They used to differ: the chevrons were 24pt tinted circles at
    /// bottom-LEADING while the open-in-app control was a larger rounded square
    /// at bottom-TRAILING. Three controls, two shapes, two sizes, opposite
    /// corners. That mismatch is what read as unfinished ("looks little weird
    /// and not simple and clean"), not any one button.
    private func controlGlyph(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.caption2.weight(.bold))
            .foregroundStyle(accent)
            .frame(width: 22, height: 22)
    }

    /// Back / forward / open, grouped into a single capsule at the bottom-right.
    ///
    /// One object instead of three floating ones, on the thumb side he asked
    /// for. The shared capsule does the visual work that three separate
    /// backgrounds were doing badly: the controls read as one related set, and
    /// the quote keeps the attention -- his standing note that he likes the
    /// controls visible but never competing with the highlight.
    ///
    /// Chevrons still render only when their tap would do something, so a fresh
    /// widget shows just the open control and the capsule shrinks to fit rather
    /// than reserving space for buttons that aren't there.
    @ViewBuilder
    private var controlCluster: some View {
        HStack(spacing: 2) {
            if entry.canGoBack {
                Button(intent: PreviousHighlightIntent(scopeKey: scopeKey)) {
                    controlGlyph("chevron.backward")
                }
                .buttonStyle(.plain)
            }
            if entry.canGoForward {
                Button(intent: NextHighlightIntent(scopeKey: scopeKey)) {
                    controlGlyph("chevron.forward")
                }
                .buttonStyle(.plain)
            }
            Link(destination: tapDestination) {
                controlGlyph("arrow.up.forward")
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(accent.opacity(0.14), in: Capsule())
        .fixedSize()
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
                    .lineLimit(7)
                    .minimumScaleFactor(0.6)

                footerRow(Text(citation))
            }
        }
        .padding(4)
        .overlay(alignment: .topTrailing) { shareButton }
    }

    private var largeBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "quote.opening")
                .font(.title3)
                .foregroundStyle(accent)

            Text(entry.quote)
                .font(.system(.body, design: .serif))
                .italic()
                .lineLimit(14)
                .minimumScaleFactor(0.6)

            Spacer(minLength: 0)

            Rectangle()
                .fill(accent.opacity(0.3))
                .frame(height: 1)

            footerRow(Text(citation))
        }
        .padding(4)
        .overlay(alignment: .topTrailing) { shareButton }
    }

    private var citation: String {
        var parts = [entry.bookTitle]
        if !entry.author.isEmpty { parts.append(entry.author) }
        if let chapter = entry.chapter { parts.append(chapter) }
        return parts.joined(separator: " · ")
    }
}

/// `AppIntentConfiguration`, not `StaticConfiguration`: that is the whole
/// difference between a widget that always shows the entire library and one the
/// user can point at a single book from the long-press "Edit Widget" sheet.
///
/// The `kind` string is deliberately unchanged. Keeping it is what lets an
/// already-installed widget carry over instead of disappearing and needing to be
/// re-added — WidgetKit hands a migrated static widget a default-initialized
/// `SelectBookIntent`, whose `book` is nil, which every layer below treats as
/// "the whole library" using the same storage keys it used before. Nothing to
/// migrate, nothing for the user to do.
///
/// No new UI was needed for the book-scoped case, and that was worth checking
/// rather than assuming: `systemMedium`/`systemLarge` already render `citation`
/// (title · author · chapter), `systemSmall` already renders `entry.bookTitle`,
/// and `accessoryRectangular` already renders it too — so a scoped widget names
/// its book on every family that shows text at all. `accessoryInline` shows the
/// bare quote and `accessoryCircular` shows the streak flame; neither has room
/// for a book name and neither gained a reason to find some.
struct CobuxHighlightWidget: Widget {
    let kind: String = "CobuxHighlightWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectBookIntent.self,
            provider: HighlightProvider()
        ) { entry in
            CobuxWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Book Wisdom")
        .description("A rotating highlight from your whole Cobux library — or pick one book and see only its highlights. Shows your daily streak on the Lock Screen. Tap to open Cobux AI.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryInline, .accessoryCircular
        ])
    }
}


/// Makes the widget body cycle the highlight on tap, except on the lock-screen accessory
/// families where a single small target should just open the app.
private struct WidgetTapBehavior: ViewModifier {
    let family: WidgetFamily
    let destination: URL
    let scopeKey: String?

    private var isAccessory: Bool {
        switch family {
        case .accessoryRectangular, .accessoryInline, .accessoryCircular: true
        default: false
        }
    }

    func body(content: Content) -> some View {
        if isAccessory {
            content.widgetURL(destination)
        } else {
            Button(intent: CycleHighlightIntent(scopeKey: scopeKey)) {
                content
            }
            .buttonStyle(.plain)
        }
    }
}
