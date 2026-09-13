import SwiftUI

/// How one Ebb card looks.
///
/// The voice rule is inherited whole from `JournalHighlightCard`, and it is the
/// part that must not bend: **the kicker states the mechanism that actually
/// ran, in dated words.** He always knows why he is being shown something. No
/// card interprets, advises, or characterizes — a footer says "Open in Chat",
/// never "Think it through", because a verb that states a mechanism quotes
/// while an imperative advises.
///
/// The composition is the second rebuild, and this time it is structural.
/// The first version was one leading VStack: kicker, passage, Spacer, footer —
/// which slammed his writing against the top, left a dead black middle, and
/// let the screen-level "EBB" wordmark collide with the card's kicker in the
/// same corner. Rajan, on build 51, with a screenshot: "this ebb ui is still
/// fucked... work on this deeply."
///
/// So it now stands on `EbbCardScaffold`, a mirror of Flow's three-layer
/// scaffold (deliberately a mirror, not an extraction — Flow's private type
/// stays untouched in the surface he loves): header layer top-anchored,
/// content at the optical center, footer bottom-anchored, each independent of
/// the others' heights. And the passage gets a real typographic stage: the
/// serif `CobuxTypography.passage` face in both themes — his writing is
/// content, not chrome — at a length-adaptive size, opened by the same
/// decorative quote glyph Flow gives book passages. His words finally get the
/// treatment the library's have had all along.
///
/// ## Build 54 — the identity: **Ebb is a page; Flow is air.**
///
/// Rajan, on 53: "ebb looks totally similar to flow somwhting shuld be a lil
/// different so that usre eys can subconsicly distinguish". Measured, he was
/// understating it — the two surfaces were the same screen. Same
/// `CobuxAtmosphere` at the same `.card` strength, same 68pt header clearance,
/// same 0.455 optical centre, same 28pt gutters, same −40/−12 two-plane
/// parallax, same 0.94/0.55 off-detent settle, same light-0.7 settle haptic,
/// same 64pt decorative quote glyph at the same 0.35 opacity, same centered
/// caption-bold wordmark. The only difference on the whole screen was the face
/// (serif here, `display` there — invisible in light mode, where both are
/// serif) and four teal letters at the top.
///
/// The difference is not a missing decoration, it is a missing FORM. Flow is
/// the library speaking: something new, carried toward him, arriving — words
/// held up in a lit room, touching nothing, edge to edge. Ebb is his own
/// writing coming back after time has passed: something that was already his,
/// and that was already WRITTEN DOWN. Writing that returns to you is not
/// projected at you, it is handed to you, and the thing it is handed to you on
/// is a page.
///
/// So: the room dims (`EbbView` drops the atmosphere to `.reading`) and the
/// passage moves onto a real sheet — `EbbLeaf` below, built from the app's own
/// paper tokens (`Color.cobuxSurface` at `CobuxRadius.card`) and edged in
/// `Color.cobuxEbb`, the surface's own name-colour. Every card gets it, so the
/// read never depends on which card he landed on: a quoted passage, an era's
/// chapter mark and the end card are all leaves of the same book.
///
/// Three things fall out of that one move, which is how you know it is the
/// right one rather than a decoration:
/// - The kicker and the actions stay OFF the page. The app's voice and his
///   hand are now on different substrates, which is exactly what they are.
/// - `CobuxTypography.passage` — serif in both themes, already here, previously
///   unexplained — becomes self-evident. Serif belongs on paper.
/// - The echo card can finally hold two voices honestly: his passage in the
///   book face on the page, the library's line in `display`, which is the face
///   `CobuxTypography` reserves for the library and which Ebb was wrongly
///   spending on it.
///
/// ## After the page — the room joins it
///
/// Rajan, on the shipped page: "the EBB UI actually kind of still looks a
/// little weird. I mean it's new, I know, and it looks good, better than what
/// we had before, but I think we can make it even more appealing." Right on
/// both halves — the page is the correct idea, and the screen had not finished
/// absorbing it.
///
/// The diagnosis, in one line: **the page arrived and the room around it did
/// not update.** Flow can compose loosely because it is air; nothing there has
/// an edge, so nothing has to line up with anything. The moment Ebb drew a real
/// sheet with a real trim, every other element on the screen acquired an
/// obligation to that edge, and none of them met it. Measured against it:
/// - The kicker was centred over a page whose every line is left-ragged, so the
///   card carried two vertical axes and resolved neither.
/// - The sheet shrink-wrapped its text. A two-line entry drew a chip of paper
///   adrift in a dim room and a long one drew a full sheet, so no two cards in
///   the deck read as the same object — which is the one thing paper does that
///   a box with text in it does not.
/// - The 64pt quote glyph set its ink a few points right of the margin the
///   passage under it establishes. Invisible in Flow, where there is no edge to
///   measure against; on a page it is a wobble in the one straight line.
/// - The two actions were a caption-sized chip beside a subheadline pill: two
///   type scales at two heights, which is the exact congestion Fable already
///   ruled on for Flow's own footer ("what was left was COMPOSITION").
///
/// Four moves, each a consequence of the page rather than a new idea:
/// - **A page has a size** (`EbbCardLayout`): the sheet takes at least a share
///   of the band that is free, whatever happens to be written on it.
/// - **Type registers with the page's margin** (`EbbPage.textInset`): the
///   kicker is the page's running head and now sits on the same vertical as the
///   first glyph of his writing, the quote mark included. The ACTIONS stay
///   centred — they are furniture in the room, not type on the page, and the
///   footer's own note has said so since the first rebuild.
/// - **The hue learns a second shape.** A horizontal rule SEPARATES two things
///   of his; a vertical thread ATTRIBUTES — it marks what came from another
///   time or another book. The era divider's spine and the echo card's block
///   quotation are the same gesture, which is why they now look alike.
/// - **The footer is one instrument**: one type scale, one height by layout,
///   one Dynamic Type cap across both controls.
struct EbbCardView: View {
    let card: EbbCard
    let hue: Color
    /// The echo card's third voice: a line on the same theme from a book of
    /// another tradition (`EbbCounterpoint`). Found after the deck is on
    /// screen and handed in by `EbbView`; `nil` means no line cleared the
    /// gate, and the card is exactly the two-voice card it always was.
    var counterpoint: EbbCounterpoint? = nil
    /// Declared before onOpenEntry -- the trailing-closure trap.
    var onWriteBack: ((UUID) -> Void)? = nil
    var onOpenEntry: (UUID) -> Void
    var onOpenChat: (String) -> Void
    var onSuppress: (UUID) -> Void
    var onWrite: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // The decorative opening quote, exactly as Flow sets it for book quotes.
    @ScaledMetric(relativeTo: .title) private var quoteMarkSize: CGFloat = 64
    @ScaledMetric(relativeTo: .title) private var quoteMarkHeight: CGFloat = 40

    // The length-adaptive passage ladder.
    @ScaledMetric(relativeTo: .largeTitle) private var passageLarge: CGFloat = 34
    @ScaledMetric(relativeTo: .title) private var passageMedium: CGFloat = 28
    @ScaledMetric(relativeTo: .title3) private var passageSmall: CGFloat = 22

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    var body: some View {
        EbbCardScaffold(reduceMotion: reduceMotion) {
            if let kicker = kickerText {
                // The page's running head. It was centred, inherited from Flow
                // where centring is free because nothing on that screen has an
                // edge -- but this kicker sits above a sheet whose every line
                // starts at one margin, so centred it gave the card a second
                // vertical axis and settled neither. It now begins exactly
                // where the first glyph of his writing begins
                // (`EbbPage.textInset`), which is the alignment the eye
                // actually reads: mechanism, then page, on one line down the
                // left. The wordmark above stays centred and untouched -- it is
                // chrome for the ROOM, and it has been reported twice already.
                Text(kicker)
                    .cobuxKicker(tint: hue, scale: .inline)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, EbbPage.textInset)
                    .padding(.trailing, CobuxSpacing.xl)
            }
        } content: {
            stage
        } footer: {
            footer
        }
    }

    // ------------------------------------------------------------ the stage

    /// The card's hero, placed at the optical center by the scaffold.
    @ViewBuilder
    private var stage: some View {
        switch card {
        case let .passage(_, _, passage, _), let .onThisDay(_, _, passage),
             let .kept(_, _, passage, _):
            quoted(passage)
        case let .echo(_, _, passage, highlight, bookTitle):
            // The deck's most interesting card: the only one holding two
            // voices. The 40pt seam it used to carry said "these are two
            // things" and nothing more, which left the library's line reading
            // as a second paragraph of his in a smaller size.
            //
            // It is now set as what it actually is -- a block quotation on his
            // page: indented from his margin, threaded down its leading edge in
            // the month's hue, and closed with an em-dash attribution, which is
            // the form every printed page uses to say "someone else wrote
            // this". Nothing new is invented for it; the thread is the era
            // divider's own spine, doing the same job one scale down.
            //
            // ## Another tradition -- the third voice
            //
            // When a line from a book of a DIFFERENT shelf clears the echo's
            // own gate (`EbbCounterpointFinder`), it is set directly under the
            // library line as a second block quotation: the same indent, the
            // same thread, the same face, the same citation form. That
            // sameness is the whole point. `BookTradition` exists so that
            // Greene and Aurelius stop arriving with identical authority; the
            // way an app shows that difference without grading it is to put
            // the two lines on one theme side by side and say nothing about
            // which is wiser. Rajan: "it's just not everything is just taken
            // at the same level of darkness… We can do something more than
            // just displaying the highlight as it is." The kicker over the
            // block names the mechanism in the shelf's own words -- ANOTHER
            // TRADITION · Stoic practice · Marcus Aurelius -- and nothing on
            // the card interprets the pair. No framing sentence, on purpose:
            // "the same thought" would be the app's reading of two lines, and
            // this surface quotes, it does not read.
            //
            // His passage gives up two of its eight lines to make room -- the
            // page has a band and three voices must share it -- and the two
            // library lines keep the same three-line budget, because a
            // tradition allowed one more line than another would already be
            // a grade.
            VStack(alignment: .leading, spacing: 18) {
                quoted(passage, lineLimit: counterpoint == nil ? 8 : 6)
                libraryBlock(highlight, citation: bookTitle)
                if let counterpoint {
                    VStack(alignment: .leading, spacing: 8) {
                        // The kicker grammar at its inline scale, in the
                        // month's hue like the running head above the page:
                        // the app naming the rule that fired, in dated-words
                        // discipline -- here the shelf's name and the author's.
                        Text("Another tradition · \(counterpoint.tradition.label) · \(counterpoint.author)")
                            .cobuxKicker(tint: hue, scale: .inline)
                            .lineLimit(2)
                            .padding(.leading, CobuxSpacing.md)
                        libraryBlock(counterpoint.text, citation: counterpoint.bookTitle)
                    }
                    // Arrives after the card is already on screen. A fade
                    // only -- `EbbView` animates the assignment, shorter under
                    // Reduce Motion -- never a move, so nothing on the page
                    // travels.
                    .transition(.opacity)
                }
            }
        case let .asked(_, _, question, passage, _):
            // His question first, in his words, then what he was looking at
            // when he wrote it. The app adds nothing to either.
            //
            // The seam here stays HORIZONTAL, deliberately, where the echo
            // card's went vertical: both halves of this card are his, and the
            // rule only has to say "these are two moments". A thread down the
            // side would claim the second block came from somewhere else, which
            // on this card would be a lie told in punctuation.
            VStack(alignment: .leading, spacing: 18) {
                Text(question)
                    .font(CobuxTypography.passage(size: 24, weight: .medium))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                hueRule
                Text(passage)
                    .font(CobuxTypography.passage(size: 16))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .lineLimit(6)
            }
        case let .reference(_, _, words, _):
            // Points rather than quoting. Never a worse quote — and no quote
            // glyph, because nothing here is being quoted.
            //
            // 20pt rather than 17: this one sentence is the whole card, and at
            // the caption-ish size it inherited it read as a footnote to a page
            // that was otherwise empty. It stays SECONDARY, because it is the
            // app talking and not him — presence, not promotion.
            Text("You wrote \(words) words here.")
                .font(CobuxTypography.display(colorScheme, size: 20, weight: .regular))
                .foregroundStyle(.secondary)
        case let .eraDivider(month, year):
            eraDivider(month: month, year: year)
        case let .endCard(total, earliest):
            endCard(total: total, earliest: earliest)
        }
    }

    /// A passage on its stage: the opening glyph in the month's hue, then his
    /// words in the book face, sized by how much he wrote.
    private func quoted(_ text: String, lineLimit: Int = 12) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\u{201C}")
                .font(CobuxTypography.display(colorScheme, size: quoteMarkSize, weight: .bold))
                .foregroundStyle(hue.opacity(0.35))
                .frame(height: quoteMarkHeight, alignment: .top)
                // Hung, the way a typesetter hangs opening punctuation. A quote
                // mark carries a left side bearing, so laid out flush its INK
                // starts a few points right of the passage's, and the page's
                // one straight line — margin, glyph, first word — arrives with
                // a wobble in it. Flow can ignore this because it has no edge
                // to measure against; a sheet with a trim does not.
                //
                // A fraction of the glyph's own size, so it tracks Dynamic Type
                // instead of drifting at large text, and `.offset` rather than
                // padding because an offset is layout-neutral: it moves ink and
                // can never widen the block or push the page.
                .offset(x: -quoteMarkSize * Self.quoteHang)
                // Decoration. Flow paid for this one already: VoiceOver read
                // "left double quotation mark" before every passage in the
                // feed, and Ebb inherited the glyph without the fix.
                .accessibilityHidden(true)
                .scrollTransition(.interactive) { view, phase in
                    // The glyph rides its own plane, slightly deeper than the
                    // text — the same two-plane parallax Flow's quotes get.
                    view.offset(y: reduceMotion ? 0 : phase.value * -12)
                }
            Text(text)
                .font(passageFont(for: text))
                .lineSpacing(6)
                .lineLimit(lineLimit)
                .minimumScaleFactor(0.7)
                .textSelection(.enabled)
        }
    }

    /// A library line as a block quotation on his page: indented from his
    /// margin, threaded down its leading edge in the month's hue, and closed
    /// with an em-dash citation -- the form every printed page uses to say
    /// "someone else wrote this". One helper for BOTH library voices on the
    /// echo card, so the echo line and the other-tradition line cannot be set
    /// differently by accident: the sameness is the design.
    ///
    /// `display`, NOT `passage` — a real semantic error, fixed once and now
    /// impossible to repeat here. `CobuxTypography.passage` is documented as
    /// HIS OWN writing, quoted, and closes with "Never used for Flow's
    /// library quotes -- those stay `display`". On the one card that holds
    /// his voice and the library's at once, they must not be set in the same
    /// type: his passage above in the book face, the library's lines below it
    /// in the library's.
    private func libraryBlock(_ line: String, citation: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\u{201C}\(line)\u{201D}")
                .font(CobuxTypography.display(colorScheme, size: 16, weight: .regular))
                .italic()
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .lineLimit(3)
            // An em dash, not a bare title: the dash is what turns a line of
            // text into a citation, and it costs one character.
            Text("\u{2014} \(citation)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, CobuxSpacing.md)
        .overlay(alignment: .leading) { attributionThread }
    }

    private func passageFont(for text: String) -> Font {
        if text.count < 90 { return CobuxTypography.passage(size: passageLarge, weight: .semibold) }
        if text.count < 200 { return CobuxTypography.passage(size: passageMedium, weight: .medium) }
        return CobuxTypography.passage(size: passageSmall)
    }

    /// The optical hang, as a fraction of the glyph's own point size. An
    /// estimate of the face's left side bearing rather than a measured metric —
    /// SwiftUI exposes no bearing, and the two faces this glyph is set in
    /// (`display` is system in dark, serif in light) do not share one anyway.
    /// Deliberately under-corrected: a hair short of flush reads as a wide
    /// letter, while over-corrected reads as a mistake.
    private static let quoteHang: CGFloat = 0.06

    /// A short rule in the month's hue. Replaces the full-width `Divider()`,
    /// which read as a table border on a page.
    ///
    /// Horizontal on purpose, and the two shapes the hue draws in Ebb mean
    /// different things: a rule ACROSS separates two things that are both his —
    /// the `.asked` card's question and the passage it came out of, the end
    /// card's closing line and the facts under it — while a thread DOWN
    /// attributes, marking what came from another time or another book. Which
    /// is why the echo card's library line gets the thread and neither of these
    /// does.
    ///
    /// A `Capsule`, not a rounded rectangle carrying a half-point radius. A
    /// capsule's radius is half its short side, so on a 1pt rule it draws the
    /// identical shape — and it says "fully round" the way `CobuxRadius.pill`
    /// names it rather than spelling a literal radius, which
    /// `no_magic_corner_radius` treats as an error app-wide. This file was
    /// carrying two of those; the three hairlines in it now carry none.
    private var hueRule: some View {
        Capsule()
            .fill(hue.opacity(0.3))
            .frame(width: 40, height: 1)
    }

    /// The vertical thread beside a block quotation — the echo card's library
    /// line. Sized by its `.overlay` host, so it is exactly as tall as the block
    /// it marks and cannot be a hand-computed height that goes stale.
    ///
    /// Lighter than the era divider's spine (0.45 against full), because a
    /// chapter opening is an event and a citation is an aside.
    private var attributionThread: some View {
        Capsule()
            .fill(hue.opacity(0.45))
            .frame(width: 2)
    }

    /// Every kicker names the rule that fired, and dates it.
    private var kickerText: String? {
        switch card {
        case let .onThisDay(_, date, _):
            return "On this day · \(Self.dateFormatter.string(from: date))"
        case let .passage(_, date, _, certain), let .reference(_, date, _, certain):
            // An import with no parsable date collapsed onto its import date.
            // Printing that as though it were the day he wrote is a claim the
            // app cannot support, so the kicker names the mechanism instead.
            return certain
                ? "From your archive · \(Self.dateFormatter.string(from: date))"
                : "From your archive · imported \(Self.dateFormatter.string(from: date))"
        case let .echo(_, date, _, _, _):
            return "Your words × your books · \(Self.dateFormatter.string(from: date))"
        case let .kept(_, _, _, date):
            return "You kept this · \(Self.dateFormatter.string(from: date))"
        case let .asked(_, _, _, _, date):
            return "You asked yourself · \(Self.dateFormatter.string(from: date))"
        case .eraDivider, .endCard:
            return nil
        }
    }

    // -------------------------------------------------------------- footer

    /// Centered under the stage, in the shared control grammar — part of the
    /// room, not furniture floating in the corner of it. It stays CENTRED while
    /// the kicker moves to the page's margin, and the split is the point: the
    /// kicker is type, and type on a page registers with the page; these are
    /// controls, and controls belong to the room the page is lying in.
    ///
    /// One instrument, not two buttons. It was a caption-sized quiet chip
    /// beside a subheadline pill — two type scales at two heights in one row,
    /// which is precisely what Fable ruled on at the seventh report of Flow's
    /// footer ("position had been fixed and count had been fixed; what was left
    /// was COMPOSITION"). Both controls now share the pill's type scale and the
    /// row's exact height, by LAYOUT rather than arithmetic (`maxHeight:
    /// .infinity` inside a `fixedSize` row — `FlowHandle`'s mechanism), and the
    /// one-saturation rule still holds because the difference between them was
    /// never the size: it is fill versus wash.
    @ViewBuilder
    private var footer: some View {
        if let entryID = card.entryID {
            HStack(spacing: CobuxSpacing.md) {
                Button { onOpenEntry(entryID) } label: {
                    EbbQuietAction(title: "Find in journal",
                                   systemImage: "chevron.up", tint: hue)
                }
                .buttonStyle(.plain)

                if let passage = passageText {
                    // "Open in Chat", never "Think it through". A verb that
                    // states the mechanism quotes; an imperative advises, and
                    // this surface does not advise.
                    Button { onOpenChat(passage) } label: {
                        Label("Open in Chat", systemImage: "message.fill")
                            .cobuxPrimaryPill(tint: hue)
                    }
                    .buttonStyle(.plain)
                }
            }
            // The cap sits on the ROW, not on one label inside it. It used to
            // sit on the pill alone, so at accessibility sizes the pill held
            // still while the chip beside it kept growing — the two controls
            // scaled at different rates in the same row. `fixedSize` lets a
            // label wrap rather than truncate if it still runs out of width,
            // and because the two capsules share a height by layout they wrap
            // to the same height together.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .fixedSize(horizontal: false, vertical: true)
            // Permanent, per-entry, no confirmation. This ships WITH the
            // surface rather than after it: entries can never be deleted, so a
            // bad surfacing has no fix at the source, and containment has to
            // exist before amplification does.
            .contextMenu {
                if let onWriteBack {
                    Button { onWriteBack(entryID) } label: {
                        Label("Write back", systemImage: "arrowshape.turn.up.left")
                    }
                }
                Button(role: .destructive) { onSuppress(entryID) } label: {
                    Label("Never show this again", systemImage: "eye.slash")
                }
            }
        } else if case .endCard = card, let onWrite {
            // The tide comes back in. Return's whole close is receding INTO
            // writing, and the action lives where every other card's actions
            // live — it used to float mid-card.
            Button(action: onWrite) {
                Label("Write", systemImage: "square.and.pencil")
                    .cobuxPrimaryPill(tint: hue)
            }
            .buttonStyle(.plain)
        }
    }

    private var passageText: String? {
        switch card {
        case let .passage(_, _, text, _), let .onThisDay(_, _, text),
             let .echo(_, _, text, _, _), let .kept(_, _, text, _): text
        case let .asked(_, _, question, passage, _): question + "\n\n" + passage
        case .reference, .eraDivider, .endCard: nil
        }
    }

    // ------------------------------------------------------ era + end cards

    private func eraDivider(month: Int, year: Int) -> some View {
        // Dates, never counts. A divider marks a chapter; a monument that
        // printed "6 entries" beside a thinner month would grade him by
        // choreography.
        //
        // The spine is now a spine. It was a 36x2 dash lying ABOVE the month
        // name — the right idea drawn as the wrong shape, since a spine is the
        // vertical thing a book is bound along, and a short horizontal dash
        // over a title is a kicker's underline with nothing above it. Standing
        // it up costs nothing and buys three things: the card finally reads as
        // a chapter OPENING rather than a stray label; the thread is sized by
        // the block it marks instead of by a constant that goes stale when the
        // type does; and it says the same thing the echo card's attribution
        // thread says, one scale up, so the hue has one vertical grammar
        // instead of two unrelated marks.
        //
        // Still a shape in the hue, which is exactly what the invariant permits
        // — "it draws rules, trims, glyphs and washes only".
        //
        // Tighter than the 10pt it used to carry: with the dash gone from above
        // the name, the name and its year are one lockup rather than three
        // stacked items, and a title sits close to its date the way a chapter
        // heading does. It also keeps the spine short and dense instead of
        // stretching it down a spread-out block.
        VStack(alignment: .leading, spacing: 6) {
            // The name is INK, not the hue — measured, not preferred. As the
            // hue it rendered at 2.73/2.34/2.58:1 for October, November and
            // December against the dark ground, where 34pt semibold is WCAG
            // large text and wants 3:1; the month name is the only text on
            // this card, so the three deepest months of the year were the
            // hardest to read. Moving the card onto the page took those to
            // 2.60/2.23/2.45, which is mine to fix rather than to ship. Ink on
            // the page measures 16.6:1 in both themes.
            //
            // The chapter still belongs to its month: the spine beside it is
            // the hue, the page's own trim is the hue, and the atmosphere
            // behind is the hue. Colour as the accent and ink for the type is
            // the ordinary discipline — it was the letters themselves carrying
            // it that could not hold.
            Text(Calendar.current.monthSymbols[max(0, min(11, month - 1))])
                .font(CobuxTypography.display(colorScheme, size: 34, weight: .semibold))
                .foregroundStyle(Color.cobuxInk)
            Text(String(year))
                .font(CobuxTypography.display(colorScheme, size: 20, weight: .regular))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        // The spine, and the chapter's indent from it. On the type scale
        // (`lg`) rather than a hand-picked number, and one step wider than the
        // echo card's citation indent (`md`) — the two threads carry the same
        // meaning at the two scales the cards are.
        .padding(.leading, CobuxSpacing.lg)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(hue)
                .frame(width: 3)
        }
    }

    private func endCard(total: Int, earliest: Date?) -> some View {
        // The last page of the day's chapter, set like one: the line, a rule,
        // and the facts under it. The rule is the same seam the `.asked` card
        // uses — a horizontal mark separating two things that are both his —
        // and it is doing an ordinary printer's job here, closing the page so
        // the deck ends on a mark instead of simply running out.
        VStack(alignment: .leading, spacing: 14) {
            Text("Today's return ends here")
                .font(CobuxTypography.display(colorScheme, size: 26, weight: .semibold))
            hueRule
            // Facts, offered. Not a score, not a streak, nothing owed.
            //
            // `.footnote` rather than `.caption`: this is the last thing he
            // reads before the deck closes, and 11pt secondary on a dim ground
            // was the smallest type on the surface for no reason — it is quiet
            // because of its colour and its position, not because it is hard to
            // read.
            Text(earliest.map { "\(total) entries · since \(Self.dateFormatter.string(from: $0))" }
                 ?? "\(total) entries")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// The page's geometry, in ONE place.
///
/// These numbers were literals in three files' worth of modifiers, and two of
/// them have to agree or the composition breaks: the kicker's leading inset is
/// only correct because it equals the sheet's inset PLUS the sheet's own
/// margin, which is where the first glyph of his writing lands. Written as two
/// unrelated constants, the day someone widens the page's margin the running
/// head silently stops lining up with the text under it and nothing says so.
/// Named, the relationship is arithmetic instead of memory.
private enum EbbPage {
    /// The sheet's inset from the screen edge.
    static let inset: CGFloat = CobuxSpacing.md
    /// The sheet's own margin, inside its trim.
    static let margin: CGFloat = CobuxSpacing.xl
    /// Where the first glyph of his writing actually sits, measured from the
    /// screen edge — the line the kicker registers with.
    static let textInset: CGFloat = inset + margin
    /// Head and foot margin. Deeper than the side margins, as a page's are:
    /// this is where the sheet's extra height goes when the floor gives it more
    /// than its text needs.
    static let verticalMargin: CGFloat = 26
}

/// **The page.** Ebb's whole identity, drawn as one object.
///
/// Flow's card has no substrate at all: the atmosphere is the only ground and
/// the words touch nothing, which is right for the library — a line read aloud
/// into the room. Ebb quotes writing he already committed to a page, so it
/// gives it one back.
///
/// Built entirely from tokens that already exist, deliberately: `cobuxSurface`
/// is the app's paper and `CobuxRadius.card` its one freestanding-card radius.
/// NO new design token was needed for any of this.
///
/// **The edge is the page — measured, not assumed.** The obvious reading is
/// that the fill does the work, and it does not: `cobuxSurface` on
/// `cobuxBackground` is 1.05:1 dark and 1.03:1 light, and `cobuxSurface2` is no
/// better (1.17 / 1.01). This app's tokens deliberately encode no elevation
/// step — `View+CobuxCard` records the mockup resolution that dropped
/// `.ultraThinMaterial` for "a flat solid surface" plus "real hairline
/// borders", so in this design system the BORDER is the card. Hence a
/// confident 0.70 trim rather than a whisper: 3.90:1 against the page in dark,
/// 2.34:1 in light, both far above the 1.3:1 the contrast gate demands of a
/// hairline before it counts as visible at all.
///
/// The fill still earns its place, and for a reason luminance arithmetic does
/// not show: the atmosphere washes the whole room with the month's hue, and
/// this fill is OPAQUE. So the page is the one chromatically NEUTRAL rectangle
/// in a tinted room — a difference the eye reads as paper even where the
/// brightness step is nearly nil.
///
/// **The trim is `Color.cobuxEbb`, not the month hue.** Two reasons, and the
/// second is the load-bearing one. It is the surface's own name-colour, sitting
/// directly under the teal EBB wordmark, so every card says "Ebb" in the same
/// voice no matter which month he has walked back into — where Flow takes its
/// colour from whatever it is serving, Ebb is always the same room. And it
/// costs Drift nothing: the month hue keeps every place it already had — the
/// atmosphere wash, the quote glyph, the hue rule, the era spine, the chips and
/// the pill — so the seasons still melt exactly as `docs/ebb.md` specifies.
/// This is also the first structural job the teal has ever had; it was carrying
/// a wordmark and a door card and nothing else.
private struct EbbLeaf<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            // The page's own margins — wider than the 16pt `cardPadding` a
            // list card uses, because this sheet holds a hero passage rather
            // than a row, and a margin is most of what makes paper read as
            // paper rather than as a box with text in it.
            .padding(.horizontal, EbbPage.margin)
            .padding(.vertical, EbbPage.verticalMargin)
            // `maxHeight: .infinity` is the half that makes this paper rather
            // than a box. Shrink-wrapped, the sheet was a different SIZE on
            // every card — a chip under a two-line entry, a full sheet under a
            // long one — and a deck of differently-sized rectangles does not
            // read as one book. The page now takes whatever height
            // `EbbCardLayout` proposes it (never more than the free band), and
            // the layout gives every card at least a share of that band.
            //
            // `Alignment.leading` is horizontal-leading, vertical-CENTRE, so a
            // short passage sits composed in the middle of its page instead of
            // clinging to the top margin of a sheet it does not fill.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CobuxRadius.card, style: .continuous)
                    .fill(Color.cobuxSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CobuxRadius.card, style: .continuous)
                    .stroke(Color.cobuxEbb.opacity(0.70), lineWidth: 1)
            )
    }
}

/// The card's quiet action, sized to stand beside the primary pill.
///
/// `cobuxQuietChip` is right everywhere it is used and wrong here for one
/// reason: it bakes its own vertical padding into the capsule, so a chip set
/// beside a pill is a shorter capsule with smaller type, and the row reads as
/// two unrelated buttons rather than one instrument. Flow's footer reached the
/// same wall at its seventh report and answered it with `FlowHandle` — a
/// private view in the feature file that wears the chip's WASH at the pill's
/// SCALE, with its height taken from the row by layout rather than by
/// arithmetic. This is that answer, keeping its label: two controls, one
/// saturation, one type scale, one height.
///
/// A local view rather than a new shared modifier, deliberately. Flow set the
/// precedent, and `View+CobuxControls` is a signed-off surface that three other
/// features read — widening it to serve one footer is how a grammar drifts.
private struct EbbQuietAction: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            // The pill's own horizontal padding, so the two capsules are cut
            // from the same block: same type, same inset, same height, and the
            // ONLY difference between them is fill versus wash — which is
            // exactly what the two-tier grammar says the difference is.
            .padding(.horizontal, CobuxSpacing.pillH)
            // Height by layout, never by a matching number. The row is
            // `fixedSize` vertically, so it takes the pill's natural height and
            // this stretches to meet it — at every Dynamic Type size, including
            // the ones where a hardcoded pair would silently drift apart.
            .frame(maxHeight: .infinity)
            .background(tint.opacity(0.15), in: Capsule())
            .contentShape(Capsule())
    }
}

/// Ebb's three-layer card scaffold — a deliberate MIRROR of Flow's, not an
/// extraction of it (Flow's private scaffold stays untouched in the surface
/// he loves; if the two ever need to converge, that is a decision for a calm
/// build, not a rider on a redesign).
///
/// Header top-anchored, content at the 0.455 optical center ("the human eye
/// reads a little over the middle"), footer bottom-anchored. Each layer is
/// independent of the others' heights, which is precisely what the old
/// VStack-plus-Spacer could never give: the passage now sits composed in the
/// middle of the room no matter how tall the kicker or the footer happen to
/// be. The header's 68pt top padding clears the centered EBB wordmark, the
/// same clearance Flow's cards give theirs.
///
/// The content layer is the `EbbLeaf` page. The kicker above it and the actions
/// below it stay OFF the page on purpose: the kicker is the app stating the
/// mechanism that fired and the footer is his way out of the card, while the
/// page holds only what he actually wrote. Two voices, two substrates.
///
/// Off the page is not the same as unrelated to it, and the two layers answer
/// that differently on purpose. The kicker is TYPE, so it registers with the
/// page's text margin (`EbbPage.textInset`) and reads as its running head. The
/// footer is CONTROLS, so it stays centred in the room — furniture stands where
/// the hand reaches it, not where the paragraph starts.
private struct EbbCardScaffold<Header: View, Content: View, Footer: View>: View {
    let reduceMotion: Bool
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        EbbCardLayout(gutter: CobuxSpacing.lg) {
            // Each slot wrapped so it enters the layout as exactly ONE
            // subview: a multi-statement slot is a `TupleView`, and Flow paid
            // for that in overlapping text before its own scaffold did this.
            VStack(spacing: 0) { header() }
                .padding(.top, 68)

            EbbLeaf { content() }
                // The page's inset from the screen edge. Narrower than the
                // 28pt Flow gives bare text, because the leaf then adds its
                // own margin inside — the total optical gutter to the first
                // glyph lands close to Flow's, but the difference is now a
                // real edge instead of empty space.
                .padding(.horizontal, EbbPage.inset)
                .scrollTransition(.interactive) { view, phase in
                    view.offset(y: reduceMotion ? 0 : phase.value * -40)
                }

            VStack(spacing: 0) { footer() }
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollTransition(.interactive) { view, phase in
            view
                .scaleEffect(phase.isIdentity || reduceMotion ? 1 : 0.94)
                .opacity(phase.isIdentity ? 1 : (reduceMotion ? 0.8 : 0.55))
        }
    }
}

/// The scaffold's three anchors as one `Layout` — header at the top, footer at
/// the bottom, content at the optical centre, with the content BOUNDED to the
/// band that is actually free between the other two.
///
/// A mirror of `FlowCardLayout`, for the same reason the scaffold above mirrors
/// Flow's rather than extracting it — and it is a fix, not a copy for symmetry.
/// Ebb was still on the `GeometryReader` + `.position(y: 0.455h)` pattern that
/// Flow's own notes describe as the bug it replaced: `.position` never bounds
/// the content to the free band, so `minimumScaleFactor` on the passage could
/// never engage and a long entry at a large Dynamic Type size grew straight up
/// through the kicker. Latent here already; putting the passage on a page,
/// which adds the leaf's own 52pt of margin to the same measurement, would have
/// made a latent overflow a shipped one. The industry answer to "text must fit
/// the space that is actually free" is to propose it that space, and this repo
/// already had that answer written down one directory over.
///
/// Placement, in priority order:
/// 1. The content's centre sits at 0.455 of the card — "the human eye reads a
///    little over the middle".
/// 2. The content may never enter the header or the footer: it is proposed the
///    band between them less a gutter each side, so the passage scales to fit,
///    and if it is still too tall to sit centred it slides by the least amount
///    that keeps it inside.
/// 3. **The page has a floor.** The sheet used to shrink-wrap its text, so a
///    two-line entry drew a chip of paper adrift in a dim room and a long one
///    drew a full sheet — the deck was a stack of differently-sized rectangles
///    rather than a book. It is now proposed at least `minimumPageShare` of the
///    band, whatever is written on it, and `EbbLeaf` centres its content in
///    whatever it is given. Expressed as a SHARE of the band rather than in
///    points so it holds on every screen and at every Dynamic Type size: at
///    accessibility sizes the header and footer grow, the band shrinks, and the
///    floor shrinks with it instead of squeezing the page out of the room.
///
/// The floor is the one thing here that moves a card he has already seen, and
/// it moves it in exactly one direction: a page that was too small for the room
/// grows, centred on the same spot. The optical centre still wins for every
/// ordinary card — a page at the floor is under half the band, so the clamp in
/// rule 2 has slack on both sides and never has to pull it back to the middle.
private struct EbbCardLayout: Layout {
    /// Breathing room between the page and the kicker above / actions below.
    let gutter: CGFloat

    private static let opticalCentre: CGFloat = 0.455
    /// The least of the free band a page may occupy. Under a half, so a short
    /// entry still reads as a sheet without a long one having to grow to match
    /// it — and low enough that the optical centre keeps winning for ordinary
    /// cards rather than being clamped away by a page too tall to sit there.
    private static let minimumPageShare: CGFloat = 0.45

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let header = subviews[0]
        let content = subviews[1]
        let footer = subviews[2]
        let width = bounds.width

        let headerHeight = header.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let footerHeight = footer.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        header.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
                     proposal: ProposedViewSize(width: width, height: headerHeight))
        footer.place(at: CGPoint(x: bounds.midX, y: bounds.maxY), anchor: .bottom,
                     proposal: ProposedViewSize(width: width, height: footerHeight))

        let bandTop = bounds.minY + headerHeight + gutter
        let bandBottom = bounds.maxY - footerHeight - gutter
        let band = bandBottom - bandTop
        // The page's NATURAL height, measured with no height proposed at all.
        // Measuring it against the band would hand back the band every time --
        // `EbbLeaf` is deliberately greedy now (`maxHeight: .infinity`), so it
        // fills whatever it is offered -- and the floor below could never mean
        // anything. Proposing no height asks for the ideal instead: the height
        // the writing on this card actually wants.
        let natural = content.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        // A card so small that header and footer meet has no band; the content
        // then falls back to the unbounded placement rather than collapsing.
        //
        // Otherwise the page is at least a share of the band and never more
        // than the band itself, which is what keeps the bounded-content
        // invariant intact: whatever the floor does, the leaf is proposed a
        // height that fits between the kicker and the actions, so
        // `minimumScaleFactor` on a long passage still engages inside it.
        let pageHeight = band > 0
            ? min(band, max(natural, band * Self.minimumPageShare))
            : natural
        let contentProposal = ProposedViewSize(width: width, height: band > 0 ? pageHeight : nil)
        let ideal = bounds.minY + bounds.height * Self.opticalCentre
        var centre = ideal
        if band > 0 {
            let half = pageHeight / 2
            centre = min(max(ideal, bandTop + half), bandBottom - half)
        }
        content.place(at: CGPoint(x: bounds.midX, y: centre), anchor: .center, proposal: contentProposal)
    }
}
