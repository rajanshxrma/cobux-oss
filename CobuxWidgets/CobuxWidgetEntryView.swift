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

    /// Horizontal room to leave clear at the bottom-right corner when
    /// `historyChevrons` can render there.
    ///
    /// `historyChevrons` is a `.overlay`, so it never participates in layout —
    /// the book title / citation `Text` beside it lays out against the full
    /// width of its own container and only knows to truncate or wrap short of
    /// that corner if something tells it to. Two 24pt circles plus 2pt padding
    /// each plus 4pt spacing between them is 60pt; this is that reservation,
    /// applied only when the chevrons can actually appear (a fresh widget with
    /// no history yet renders neither, and should not lose the width for
    /// nothing). Same 60pt regardless of family: systemSmall is the tight
    /// case (roughly 110pt of usable width after system + local padding, so a
    /// long book title genuinely needs this), and reserving it on
    /// systemMedium/systemLarge too costs those wider layouts nothing visible
    /// while keeping one rule instead of three.
    private var chevronReserve: CGFloat {
        (entry.canGoBack || entry.canGoForward) ? 60 : 0
    }

    /// Same reservation shape as `chevronReserve`, mirrored to the leading
    /// side for `shuffleButton` now that it lives at `.bottomLeading` --
    /// moved there from the top-right corner (Rajan's direct feedback: a
    /// widget sits at the very top of the home screen, so a control up in
    /// its own top-right corner is the single hardest spot on it to reach
    /// one-handed). Always reserved, unlike `chevronReserve`: the shuffle
    /// button is always present, where the chevrons only sometimes are.
    private let shuffleReserve: CGFloat = 32

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
        .widgetURL(tapDestination)
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
                .lineLimit(5)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 0)

            Text(entry.bookTitle)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, shuffleReserve)
                .padding(.trailing, chevronReserve)
        }
        .padding(4)
        .overlay(alignment: .bottomLeading) { shuffleButton }
        .overlay(alignment: .bottomTrailing) { historyChevrons }
    }

    /// A small, deliberately corner-sized tap target for `CycleHighlightIntent` --
    /// swaps the shown highlight in place without leaving the home screen. Must stay
    /// small: the rest of each widget body's surface still needs to trigger the
    /// existing `.widgetURL(tapDestination)` open-to-book behavior, which a button
    /// covering more of the widget would silently break.
    private var shuffleButton: some View {
        Button(intent: CycleHighlightIntent(scopeKey: scopeKey)) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption2)
                .foregroundStyle(accent)
                .padding(6)
        }
        .buttonStyle(.plain)
    }

    /// Back/forward chevrons for `WidgetHighlightHistory` — return to the quote
    /// that was showing before a shuffle (or rotation) replaced it, then
    /// re-advance. Each renders only when its tap would do something, so the
    /// corner stays empty on a fresh widget and systemSmall never carries more
    /// chrome than it has to. Same placement discipline as `shuffleButton`:
    /// the body's surface must keep its `.widgetURL` tap. Rendered as filled
    /// circles rather than bare glyphs — Rajan's direct feedback: he loved
    /// the buttons but "slightly made visible" was TOO slight to spot.
    @ViewBuilder
    private var historyChevrons: some View {
        if entry.canGoBack || entry.canGoForward {
            HStack(spacing: 4) {
                if entry.canGoBack {
                    Button(intent: PreviousHighlightIntent(scopeKey: scopeKey)) {
                        chevronGlyph("chevron.backward")
                    }
                    .buttonStyle(.plain)
                }
                if entry.canGoForward {
                    Button(intent: NextHighlightIntent(scopeKey: scopeKey)) {
                        chevronGlyph("chevron.forward")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Shares the exact quote showing, as its `cobux://` deep link -- tapping
    /// it on the recipient's own phone (if they have Cobux) opens straight to
    /// this highlight, the same destination this widget's own tap already
    /// goes to. `systemMedium`/`systemLarge` only: `systemSmall`'s two
    /// corners are already spoken for (`shuffleButton`, `historyChevrons`),
    /// and it's the tightest layout of the three to begin with -- see
    /// `chevronReserve`'s own doc comment on why that family gets protected
    /// rather than crowded further.
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

    private func chevronGlyph(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.caption.weight(.bold))
            .foregroundStyle(accent)
            .frame(width: 24, height: 24)
            .background(accent.opacity(0.18), in: Circle())
            .padding(2)
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
                    .padding(.leading, shuffleReserve)
                    .padding(.trailing, chevronReserve)
            }
        }
        .padding(4)
        .overlay(alignment: .topLeading) { shareButton }
        .overlay(alignment: .bottomLeading) { shuffleButton }
        .overlay(alignment: .bottomTrailing) { historyChevrons }
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
                .lineLimit(2)
                .padding(.leading, shuffleReserve)
                .padding(.trailing, chevronReserve)
        }
        .padding(4)
        .overlay(alignment: .topLeading) { shareButton }
        .overlay(alignment: .bottomLeading) { shuffleButton }
        .overlay(alignment: .bottomTrailing) { historyChevrons }
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
