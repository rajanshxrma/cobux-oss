import WidgetKit
import SwiftUI
import AppIntents

struct CobuxWidgetEntryView: View {
    var entry: HighlightProvider.Entry
    @Environment(\.widgetFamily) private var family

    /// The insets the system WOULD have applied, which is exactly what this
    /// environment value keeps reporting after `.contentMarginsDisabled()` --
    /// disabling the margins is what makes the value worth reading, since it
    /// lets a widget put them back only where it wants them. The home families
    /// deliberately do not: they inset themselves, INSIDE their own cycle
    /// buttons, which is the whole dead-space fix. The three accessory families
    /// do, because `.contentMarginsDisabled()` is configuration-wide and the
    /// lock screen was never part of the defect.
    @Environment(\.widgetContentMargins) private var contentMargins

    /// The home families' own margin, standing in for the system content
    /// margin that `.contentMarginsDisabled()` gives back to the widget.
    ///
    /// Named constants rather than literals because every one of them is now
    /// applied INSIDE a cycle button rather than around the family's content,
    /// and the arithmetic has to be checkable by reading: each gap between two
    /// stacked regions is split in half so both halves land inside a button,
    /// and the halves must add back up to the spacing they replaced.
    private static let hInset: CGFloat = 20
    private static let vInset: CGFloat = 16

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
            // Each accessory family takes back the system margin that
            // `.contentMarginsDisabled()` removed configuration-wide, so the
            // lock screen renders exactly as it did before that modifier
            // existed. See `contentMargins`.
            case .accessoryInline:
                Text(entry.quote)
                    .padding(contentMargins)
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
                // Around the whole ZStack, background included: the system
                // margin was applied outside all of the widget's content, so
                // `AccessoryWidgetBackground` was inset by it too. Padding
                // only the foreground would grow the circle -- a change, not a
                // restoration.
                .padding(contentMargins)
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
                .padding(contentMargins)
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
        // HOW THE WHOLE SURFACE CYCLES -- and why it is TILED rather than
        // layered, after two layered attempts failed on his phone.
        //
        // Builds 52 and 53 put one full-frame `Button(intent:)` whose label was
        // `Color.clear` BEHIND each family's content, via `.background`. He
        // reported the tap dead on both. That construct has no support anywhere:
        // Apple documents neither a Button in a `.background` nor an invisible
        // one, and the only WidgetKit behaviour anybody states out loud is that
        // TAP REGIONS ARE DERIVED FROM RENDERED CONTENT -- which is why changing
        // only an image's `.widgetAccentedRenderingMode` to `.desaturated` stops
        // a widget Button's intent firing at all (FB15152620). A Button whose
        // label draws nothing, covering the entire widget, is that hazard at
        // full size, and it sat over the quote and the citation -- the two
        // regions that DID cycle on build 51.
        //
        // So the layered catch-all is gone and every pixel that can belong to a
        // real button now does, as adjacent, non-overlapping siblings:
        //
        //   * `tapToCycle` -- the quote, the citation, the accent bar, the
        //     opening-quote glyph and the divider are each their own cycle
        //     button, and each one carries the padding and half of each gap
        //     that used to sit OUTSIDE every button. The insets moved inside
        //     the buttons; the layout is unchanged (`hInset`/`vInset`).
        //   * Share and the chevrons -- real controls, siblings, never nested
        //     inside a cycle button, because a Button inside a Button's label
        //     is dead in WidgetKit -- that nesting is what killed the Share
        //     button once already: "the share button is not clicking and rather
        //     than the iOS widget gets clicked which refreshes the highlight".
        //
        // This is the shape build 51 proved on his device, completed rather
        // than replaced. "Clicking anywhere on the widget should shuffle the
        // highlight and not open the app ever unless the specific button for
        // opening a highlight in the app is clicked." What is left over is the
        // 3pt ring of capsule around the control cluster, and a tap there still
        // reaches WidgetKit's launch-the-app fallback -- the one region no
        // arrangement of non-overlapping siblings can cover, and the one that
        // fails LOUDLY rather than silently.
        .modifier(AccessoryTapBehavior(family: family, destination: tapDestination))
    }

    /// Wraps a region in the cycle action, leaving the footer's own controls as
    /// real, tappable siblings outside it.
    ///
    /// `.contentShape(Rectangle())` is the load-bearing line. SwiftUI hit-tests
    /// against DRAWN CONTENT, not the layout frame, so a `Text` stretched with
    /// `.frame(maxWidth: .infinity)` still only accepted taps on the glyphs
    /// themselves -- every bit of surrounding space was dead. And dead space in
    /// a widget is not inert: WidgetKit's fallback for a tap that lands on no
    /// button is to LAUNCH THE CONTAINING APP. That combination is the whole
    /// defect Rajan reported twice on build 48 -- "clicking on the iOS widget
    /// doesn't change the highlisght anymore but opens the app", then precisely
    /// diagnosed himself: "when i click in the text it does shuffle onto the
    /// next but if there's empty space after the text and one clicks there it
    /// opens the app. Clicking anywhere on the widget should shuffle the
    /// highlight and not open the app ever unless the specific button for
    /// opening a highlight in the app is clicked."
    ///
    /// Same root cause as the Flow like-target defect fixed this cycle, in a
    /// second place. Callers stretch the region; this makes the region real.
    ///
    /// **Callers pad INSIDE this closure, never outside it.** `.contentShape`
    /// is applied to whatever the closure returns, so padding placed inside
    /// becomes part of the tap region while padding placed around the returned
    /// Button belongs to nothing. `.buttonStyle(.plain)` adds no chrome of its
    /// own, so the two spellings lay out identically -- only one of them is
    /// tappable, which is the whole reason every inset in this file moved in.
    @ViewBuilder
    private func tapToCycle<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        switch family {
        case .accessoryRectangular, .accessoryInline, .accessoryCircular:
            content()
        default:
            Button(intent: CycleHighlightIntent(scopeKey: scopeKey)) {
                content().contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
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
        // `spacing: 0` on purpose. The 8pt that used to separate these two is
        // now 4pt of bottom padding inside the quote's button and 4pt of top
        // padding inside the footer's, so the gap itself cycles instead of
        // launching the app. Same 8pt on screen.
        VStack(alignment: .leading, spacing: 0) {
            tapToCycle {
            VStack(alignment: .leading, spacing: 8) {
            // Decorative, and inside this button rather than beside it, so a
            // tap on the glyph cycles like the quote under it.
            Image(systemName: "quote.opening")
                .font(.caption)
                .foregroundStyle(accent)

            // THE BOOK FACE, RESTORED. One of three -- small, medium and large
            // must always carry the same face, and they have now been changed
            // together twice, so treat them as one edit or the widget ships
            // half-restored.
            //
            // 2.6 and 2.7 set every home family's quote in `.system(<style>,
            // design: .serif).italic()`, and that is the look he is asking for
            // back, verbatim: *"in our 2.7 or 2.6 builds the way the iOS widget
            // was it was good actually, it was perfect. Can we just go back to
            // that fonts and everything because now it's just too simple."*
            //
            // This DELIBERATELY reverses R-2026-09-widget-quote-face-too-flashy
            // (build 52, one day earlier: *"the italic fon tin the ios highlight
            // is too falshy"*), and the registry record says so rather than
            // carrying a green tick over a decision that has been withdrawn. The
            // two reports are reconcilable, and the reconciliation is the reason
            // the margins below are NOT reverted with the face: build 52 changed
            // the face and the inset in the same breath, and he complained about
            // both at once ("side margins alright but a tiny bit too thin"). The
            // italic serif he called flashy was the italic serif crammed to a
            // 16pt margin; the italic serif he calls perfect is this one, at the
            // 20pt margin 2.6/2.7 effectively had. Face restored, margin kept.
            Text(entry.quote)
                .font(.system(.footnote, design: .serif))
                .italic()
                // Tap acknowledgement (58): WidgetKit dims invalidatable
                // content the moment a Button(intent:) fires and holds it until
                // the new timeline lands -- the first visible proof a tap was
                // received, which four dead-tap reports never had.
                .invalidatableContent()
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The family's whole margin, INSIDE the button. It used to be
            // `.padding(.horizontal, 20).padding(.vertical, 16)` around this
            // VStack, which is the same pixels belonging to nothing -- and
            // `.contentMarginsDisabled()` had already handed this family the
            // system's own ring on top of that. Same inset on screen, now part
            // of the tap region.
            .padding(.horizontal, Self.hInset)
            .padding(.top, Self.vInset)
            .padding(.bottom, 4)
            }

            footerRow(Text(entry.bookTitle).fontWeight(.medium),
                      leadingInset: Self.hInset,
                      topGap: 4)
        }
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
    ///
    /// `leadingInset` and `topGap` are the two numbers that differ per family,
    /// and they are parameters rather than an outer `.padding` for the reason
    /// the whole file now follows: an inset applied around this row belongs to
    /// no button. `leadingInset` is 0 on `systemMedium` alone, where the accent
    /// bar's own button already supplies the left margin.
    private func footerRow(_ citation: Text,
                           leadingInset: CGFloat,
                           topGap: CGFloat) -> some View {
        // `spacing: 0`: the 6pt that separated the citation from the controls
        // is now trailing padding inside the citation's button, so that gap
        // cycles too. It was the single largest patch of app-launching dead
        // space left on every family -- exactly the "empty space after the
        // text" he pointed at.
        HStack(alignment: .center, spacing: 0) {
            // `controlCluster` stays a SIBLING: a Button nested inside another
            // Button's label is dead in WidgetKit, which is what killed the
            // chevrons and the share button once already.
            tapToCycle {
                HStack(spacing: 0) {
                    citation
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, 6)
                .padding(.top, topGap)
                .padding(.bottom, Self.vInset)
            }
            // The same top/bottom padding as the citation beside it, so the
            // `.center` alignment still centres exactly what it centred before
            // -- and so the bottom margin under the controls is theirs rather
            // than nobody's.
            controlCluster
                .padding(.trailing, Self.hInset)
                .padding(.top, topGap)
                .padding(.bottom, Self.vInset)
        }
    }


    /// Shares the exact quote showing, as its `cobux://` deep link -- tapping
    /// it on the recipient's own phone (if they have Cobux) opens straight to
    /// this highlight, the same destination this widget's own tap already
    /// goes to. `systemMedium`/`systemLarge` only: `systemSmall` is the
    /// tightest layout of the three, its footer already carries the citation
    /// and the whole `controlCluster`, and it gets protected rather than
    /// crowded with a fourth control.
    @ViewBuilder
    private var shareButton: some View {
        if let bookID = entry.bookID, let highlightID = entry.highlightID {
            // `Link`, NOT `ShareLink`. A widget extension cannot present a
            // share sheet -- it has no window to present into -- so a
            // `ShareLink` here renders exactly right and is completely inert.
            // That is why this button has never worked since the commit that
            // added it, despite a separate fix for the nested-Button problem
            // that was also killing this corner. Hand it to the app instead.
            Link(destination: CobuxDeepLink.shareHighlightURL(bookID: bookID,
                                                              highlightID: highlightID)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.caption2)
                    .foregroundStyle(accent)
                    .padding(6)
            }
            // The family's margin, which used to reach this overlay because an
            // outer `.padding` wrapped it along with the content. Every inset
            // moved inside the buttons, so this one has to be stated here or
            // Share slides into the widget's corner. Outside the Link, so it
            // positions without adding an inert region over the quote button.
            //
            // This Link now sits IN FRONT of a cycle button rather than in
            // front of inert padding, on `systemLarge` as it already did on
            // `systemMedium`. That direction is the one with evidence behind
            // it: putting the interactive element in front in a ZStack is the
            // accepted WidgetKit workaround when a region underneath refuses
            // taps (FB15152620), which is the exact opposite of the `.background`
            // placement that killed builds 52 and 53. If it is wrong anyway,
            // Share cycles the highlight instead of sharing -- the wrong action,
            // visible and recoverable, never silence.
            .padding(.top, Self.vInset)
            .padding(.trailing, Self.hInset)
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
    ///
    /// The arrow is unconditional: it renders on every home-family entry,
    /// placeholder included. The chevrons follow `entry.canGoBack` /
    /// `canGoForward`, which every real entry now carries from the lane's
    /// live history whichever path built it (see `HighlightEntry.canGoBack`).
    /// His report on 60 -- "sometimes when it refreshes it loses the bottom
    /// icons" -- was a build that fell back to the placeholder (no history,
    /// no book, so no chevrons and no Share); `HighlightProvider.timeline`
    /// now falls back to the last shown card instead, and nothing here needed
    /// to change for the cluster to stay.
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
        // Written the long way for one reason: `.allowsHitTesting(false)`.
        // `.background(accent.opacity(0.14), in: Capsule())` draws exactly
        // these pixels, but a filled shape is a real view and takes taps, and
        // this one belongs to no Button -- so a tap on the 3pt/1pt ring around
        // the glyphs would be SWALLOWED and do nothing at all. Inert is the
        // deliberate choice over swallowed: this ring is the one region left on
        // a home family that no arrangement of non-overlapping siblings can
        // cover, so a tap here reaches WidgetKit's launch-the-app fallback --
        // the wrong action, which is recoverable and visible, rather than
        // silence, which reads exactly like the defect he has reported four
        // times. The chevrons and the Share link sit above it and stay real
        // controls.
        .background { Capsule().fill(accent.opacity(0.14)).allowsHitTesting(false) }
        .fixedSize()
    }

    private var mediumBody: some View {
        HStack(alignment: .top, spacing: 0) {
            // The accent bar is a full-height column and was the largest single
            // patch on this family that used to launch the app. It is its own
            // cycle button now, carrying the 20pt left margin and the 12pt gap
            // to the quote -- the two insets that used to sit outside every
            // button. Decorative pixels that cycle, instead of decorative
            // pixels that open the app.
            tapToCycle {
                Rectangle()
                    .fill(accent.opacity(0.7))
                    .frame(width: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .frame(maxHeight: .infinity)
                    .padding(.leading, Self.hInset)
                    .padding(.trailing, 12)
                    .padding(.vertical, Self.vInset)
            }

            // `spacing: 0`: the 6pt gap is split 3/3 between the quote's button
            // and the footer's, so it cycles. Same 6pt on screen.
            VStack(alignment: .leading, spacing: 0) {
                tapToCycle {
                    // Two of three. See `smallBody` for why this face is back.
                    Text(entry.quote)
                        .font(.system(.subheadline, design: .serif))
                        .italic()
                        // Tap acknowledgement (58): WidgetKit dims invalidatable
                        // content the moment a Button(intent:) fires and holds it until
                        // the new timeline lands -- the first visible proof a tap was
                        // received, which four dead-tap reports never had.
                        .invalidatableContent()
                        .lineLimit(7)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .topLeading)
                        .padding(.trailing, Self.hInset)
                        .padding(.top, Self.vInset)
                        .padding(.bottom, 3)
                }

                // No leading inset: the accent bar's button supplies this
                // family's left margin, and doubling it would move the
                // citation.
                footerRow(Text(citation), leadingInset: 0, topGap: 3)
            }
        }
        // `shareButton` carries its own inset from the widget's edge now that
        // the family's margin lives inside the buttons rather than around
        // them -- same position on screen as when an outer `.padding` put it
        // there. An overlay takes part in no layout, and this one draws
        // nothing outside the Link's own glyph, so the quote button underneath
        // keeps every pixel Share is not actually sitting on.
        .overlay(alignment: .topTrailing) { shareButton }
    }

    private var largeBody: some View {
        // Four stacked regions, `spacing: 0`, each 14pt gap split 7/7 so both
        // halves land inside a button. Same four gaps on screen as the
        // `spacing: 14` this replaces; none of them belongs to nothing now.
        VStack(alignment: .leading, spacing: 0) {
            // Decorative, and its own cycle button rather than a bare glyph
            // sitting between two of them. `.frame(maxWidth: .infinity,
            // alignment: .leading)` stretches the REGION while leaving the
            // glyph exactly where it was drawn.
            tapToCycle {
                Image(systemName: "quote.opening")
                    .font(.title3)
                    .foregroundStyle(accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Self.hInset)
                    .padding(.top, Self.vInset)
                    .padding(.bottom, 7)
            }

            // The Spacer lives INSIDE the cycle region, not after it. Left
            // outside, the empty gap below a short quote was dead space on the
            // largest family -- the widget with the most of it.
            tapToCycle {
                VStack(spacing: 0) {
                    // Three of three. See `smallBody` for why this face is back.
                    Text(entry.quote)
                        .font(.system(.body, design: .serif))
                        .italic()
                        // Tap acknowledgement (58): WidgetKit dims invalidatable
                        // content the moment a Button(intent:) fires and holds it until
                        // the new timeline lands -- the first visible proof a tap was
                        // received, which four dead-tap reports never had.
                        .invalidatableContent()
                        .lineLimit(14)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topLeading)
                .padding(.horizontal, Self.hInset)
                .padding(.vertical, 7)
            }

            // Decorative: a full-width hairline, and the 14pt of air on either
            // side of it. That band ran the full width of the largest family
            // and used to open the app.
            tapToCycle {
                Rectangle()
                    .fill(accent.opacity(0.3))
                    .frame(height: 1)
                    .padding(.horizontal, Self.hInset)
                    .padding(.vertical, 7)
            }

            footerRow(Text(citation), leadingInset: Self.hInset, topGap: 7)
        }
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
        .description("A line you loved, living on your Home Screen. Tap anywhere for another; tap the arrow to talk about it.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryInline, .accessoryCircular
        ])
        // The system's default content margin is a ring of widget the widget
        // does not own -- and a tap on a region no Button covers launches the
        // app. Every home family now supplies that inset itself, INSIDE its own
        // cycle buttons (`hInset`/`vInset`), so the ring cycles like the rest
        // instead of being a permanent frame of app-launching dead space that
        // no amount of layout inside it could reach.
        //
        // This is configuration-wide -- there is no per-family form of it -- so
        // it takes the accessory families' margin away as well, and the lock
        // screen has no dead space to reclaim: nothing there was ever the
        // defect. So they take it straight back. Each accessory body applies
        // `.padding(contentMargins)`, reading `widgetContentMargins`, which
        // goes on reporting the exact insets the system would have used even
        // while they are disabled -- that is what the value is for. The three
        // accessory shapes therefore render as they did before this modifier
        // existed BY CONSTRUCTION, not by expectation, which is the difference
        // between something a device has to check and something it doesn't.
        .contentMarginsDisabled()
    }
}


/// Gives the lock-screen accessory families -- and ONLY them -- a `.widgetURL`,
/// so a tap there opens the app.
///
/// That asymmetry is deliberate and is a product ruling, not an oversight: an
/// accessory family is far too small to hold two targets, so a tap on one is
/// unambiguously "take me there". The home families set no `widgetURL` at all,
/// precisely because WidgetKit would then treat every uncovered pixel as
/// "launch the app"; they tile themselves with cycle buttons instead, and reach
/// the app only through the arrow in `controlCluster` or the Share link.
private struct AccessoryTapBehavior: ViewModifier {
    let family: WidgetFamily
    let destination: URL

    private var isAccessory: Bool {
        switch family {
        case .accessoryRectangular, .accessoryInline, .accessoryCircular: true
        default: false
        }
    }

    func body(content: Content) -> some View {
        if isAccessory { content.widgetURL(destination) } else { content }
    }
}
