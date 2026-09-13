import SwiftUI
import SwiftData
import WidgetKit
#if canImport(UIKit)
import UIKit
#endif
import CobuxCore

/// Renders one Flow card, full-screen. Every card type shares the same bones
/// — a transparent surface over FlowView's shared atmosphere, generous type,
/// a small kicker naming the card type, scroll-linked settle physics — so
/// the feed reads as one surface with varied content.
struct FlowCardView: View {
    let card: FlowCard
    /// "Don't show this again", from a card's quiet menu, with the id of the
    /// highlight or quick check the card was built from. The feed owns the
    /// deck, so the feed does the removing (`FlowView.suppressCard`); the
    /// card only says which. Offered on the two card types that ARE one
    /// stored row -- a quote or a quick check -- and on nothing else: a key
    /// lesson is a chapter, the status cards are the session, and the
    /// resonance card is two rows, each hideable from its own quote card.
    var onSuppress: (UUID) -> Void = { _ in }

    var body: some View {
        switch card {
        case .highlight(let highlight):
            HighlightFlowCard(highlight: highlight, onSuppress: onSuppress)
        case .keyLesson(let chapter, let lessonIndex):
            KeyLessonFlowCard(chapter: chapter, lessonIndex: lessonIndex)
        case .clozeTeaser(let question):
            ClozeTeaserFlowCard(question: question, onSuppress: onSuppress)
        case .weakTopic(let topic, let lapseCount):
            WeakTopicFlowCard(topic: topic, lapseCount: lapseCount)
        case .dailyOpener(let streak, let dueCount):
            DailyOpenerFlowCard(streak: streak, dueCount: dueCount)
        case .sessionRecap(let setNumber, let ripeningTomorrow, let nextBook):
            SessionRecapFlowCard(setNumber: setNumber, ripeningTomorrow: ripeningTomorrow, nextBook: nextBook)
        case .resonance(let first, let second):
            ResonanceFlowCard(first: first, second: second)
        case .journalEcho(let entryID, let date, let passage):
            JournalEchoFlowCard(entryID: entryID, date: date, passage: passage)
        }
    }
}

/// Shared scaffold: kicker + centered content + bottom footer, with the
/// panel's "Detent Swipe" physics — the card scales/fades as it leaves the
/// paging detent and the inner content parallaxes slightly faster than the
/// frame, a two-layer depth illusion at zero extra draw cost. Background is
/// deliberately clear: the atmosphere lives in FlowView and cross-fades
/// between cards instead of hard-cutting at page boundaries.
private struct FlowCardScaffold<Header: View, Content: View, Footer: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let accentHex: String
    let kicker: String
    let kickerIcon: String
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    private var accent: Color { Color(hex: accentHex) }

    var body: some View {
        // Three independently anchored layers rather than one VStack.
        //
        // As a VStack the header's own 68pt top padding sat *inside* the same
        // stack the two Spacers were balancing, so "Spacer, content, Spacer"
        // never actually centered anything -- it put the quote a few percent
        // BELOW true center, which is exactly what he was seeing. Trying to
        // correct that by adding a fixed spacer underneath just trades one
        // magic number for another, and the right value would still depend on
        // how tall this particular card's header and footer happened to be.
        //
        // Anchoring each layer separately removes the coupling: the quote is
        // placed at a stated fraction of the card, and the header and footer
        // can be any height without moving it.
        //
        // `FlowCardLayout` (below) is those three anchors as one `Layout`. It
        // replaced a `GeometryReader` + `.position(y: 0.455h)` that never
        // bounded the content's height, so `minimumScaleFactor` on the quote
        // could never engage: a long passage at a large text size grew straight
        // up into the book title and then truncated. The layout measures the
        // header and footer in the same pass, proposes the content only the
        // band that actually exists between them, and slides an over-tall
        // content down just far enough to clear the header. A card whose
        // content fits -- nearly every card -- sits exactly where it always did.
        //
        // Each slot is wrapped in a `VStack` so it enters the layout as ONE
        // subview. A multi-statement slot (`Text; Text`) is a `TupleView`, and
        // in the old `ZStack` its members were each positioned at the same
        // centre and drew on top of each other -- the journal echo card's date
        // rendered over its passage, and its Share over its Open Cobux. Stacked
        // vertically is the failure mode now, never overlapped.
        FlowCardLayout(gutter: CobuxSpacing.lg) {
            VStack(spacing: 6) {
                Label(kicker, systemImage: kickerIcon)
                    .font(.caption.weight(.semibold))
                    .kerning(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(accent)
                header
            }
            .padding(.top, 68)

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 28)
            .scrollTransition(.interactive) { view, phase in
                view.offset(y: reduceMotion ? 0 : phase.value * -40)
            }

            VStack(spacing: 0) {
                footer
            }
            // The global "Open Cobux" safeAreaInset that used to sit
            // below this is gone (see FlowView), so this footer is now
            // the lowest thing on the screen and 4pt left it sitting on
            // the home indicator. This is the real gap to the bottom
            // edge, not a token one under another control.
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

/// The scaffold's three anchors -- header at the top, footer at the bottom,
/// content at the optical centre -- with the content bounded to the band that
/// is actually free between the other two.
///
/// Subviews, in order: header, content, footer. Fills whatever it is proposed
/// (FlowView gives every card a `containerRelativeFrame`).
///
/// Placement rules, in priority order:
/// 1. The content's centre is at 0.455 of the card. Not 0.5: the eye reads
///    the true midpoint as sitting slightly low, which is why macOS alerts
///    and well-set title pages are nudged up rather than centered. His words:
///    "the human eye reads a little over the middle."
/// 2. The content may never enter the header or the footer. It is proposed
///    the band between them (less a gutter each side), so a `Text` with
///    `minimumScaleFactor` shrinks to fit rather than overflowing, and if it
///    is still too tall to sit centred at 0.455 it slides down by the least
///    amount that keeps it inside the band.
///
/// Rule 2 only ever moves content that would otherwise collide, which is why
/// this could be introduced without changing a single card he has already
/// approved: content that fits is placed exactly where `position(y: 0.455h)`
/// put it before.
private struct FlowCardLayout: Layout {
    /// Breathing room between the content band and the header above /
    /// footer below it.
    let gutter: CGFloat

    private static let opticalCentre: CGFloat = 0.455

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
        // A card so small that header and footer meet has no band; the
        // content then falls back to the unbounded placement rather than
        // collapsing to nothing.
        let contentProposal = ProposedViewSize(width: width, height: band > 0 ? band : nil)
        let contentHeight = content.sizeThatFits(contentProposal).height
        let ideal = bounds.minY + bounds.height * Self.opticalCentre
        var centre = ideal
        if band > 0 {
            let half = min(contentHeight, band) / 2
            centre = min(max(ideal, bandTop + half), bandBottom - half)
        }
        content.place(at: CGPoint(x: bounds.midX, y: centre), anchor: .center, proposal: contentProposal)
    }
}

/// Convenience initializer for the card types with nothing to name at the top.
/// The quote, key-lesson and quick-check cards all carry a book (and sometimes a
/// chapter) in their header instead -- this used to say the quote card was the only
/// one, which is exactly why the other two kept printing it at the bottom long after
/// he asked for it to move up.
extension FlowCardScaffold where Header == EmptyView {
    init(
        accentHex: String,
        kicker: String,
        kickerIcon: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.init(accentHex: accentHex, kicker: kicker, kickerIcon: kickerIcon, header: { EmptyView() }, content: content, footer: footer)
    }
}

private struct HighlightFlowCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let highlight: Highlight
    /// See `FlowCardView.onSuppress`.
    let onSuppress: (UUID) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    /// Flow is presented as a `fullScreenCover` (ContentView.swift, WisdomGraphView.swift).
    /// Every in-card Chat button called `openURL` WITHOUT dismissing it, so the
    /// app really did switch tabs and prefill the composer -- underneath a cover
    /// that still filled the screen. To the user, tapping Chat did nothing.
    /// FlowView's own bottom button already had this right: dismiss, then open.
    @Environment(\.dismiss) private var dismiss
    @State private var showingContext = false
    /// Drives the double-tap heart burst. Instagram/TikTok's whole trick is
    /// that the gesture is invisible until you use it and then unmistakably
    /// confirms itself -- a burst that overshoots and fades, never a state the
    /// user has to dismiss.
    /// Incremented on each double-tap. `LikeBurst` restarts on any change, so a
    /// second tap re-fires the animation instead of being ignored mid-flight.
    @State private var burstTrigger = 0

    /// Double-tap anywhere on the card. Deliberately LIKE-only, never a
    /// toggle: on Instagram a double-tap can only ever like, because the
    /// gesture is imprecise and accidentally un-liking something you meant to
    /// keep is the one outcome that would make people distrust it. Unliking
    /// stays deliberate -- "Unlike" in the card's quiet menu (hold the card),
    /// or More > Liked.
    private func handleDoubleTap() {
        let alreadyLiked = highlight.isLiked
        highlight.isLiked = true
        // Burst even when it was already liked: the gesture should always
        // acknowledge itself, or a double-tap on something you liked
        // yesterday reads as broken.
        burstTrigger += 1
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: alreadyLiked ? .light : .medium).impactOccurred()
        #endif
    }

    // `CobuxTypography.display` takes a raw point size -- it's built for the
    // fixed-size COBUX wordmark (ChatView's nav title), the one place a size
    // that ignores the user's text-size setting is correct. Reused here for
    // the quote body itself, which is exactly the kind of user-variable-length
    // content that must NOT ignore Dynamic Type: the old code before this
    // card's length-adaptive treatment used stock `.title2`, which scaled
    // fine, so this is a real regression, not a pre-existing tradeoff.
    // `@ScaledMetric` grows each base size by the same multiplier the rest of
    // the app already respects, so bumping accessibility text size in
    // Settings actually makes Flow's quotes bigger instead of leaving them
    // exactly as small as the default.
    @ScaledMetric(relativeTo: .title) private var largeQuoteSize: CGFloat = 34
    @ScaledMetric(relativeTo: .title2) private var mediumQuoteSize: CGFloat = 28
    @ScaledMetric(relativeTo: .title3) private var smallQuoteSize: CGFloat = 22
    @ScaledMetric(relativeTo: .title) private var quoteMarkSize: CGFloat = 64
    /// The decorative opening-quote glyph's reserved height, scaled in step
    /// with `quoteMarkSize` -- left fixed at 40 while the glyph above it grows
    /// with Dynamic Type, the glyph would overflow its reserved space and
    /// visually collide with the quote text directly below it (zero VStack
    /// spacing between them).
    @ScaledMetric(relativeTo: .title) private var quoteMarkHeight: CGFloat = 40

    private var accentHex: String { highlight.book?.coverColorHex ?? "#6366F1" }

    /// "You saved this…" resurfacing: a quote older than ~3 months gets the
    /// memory-lane framing — meeting your past self is half the point of
    /// keeping a library.
    private var monthsAgo: Int {
        Calendar.current.dateComponents([.month], from: highlight.dateAdded, to: .now).month ?? 0
    }

    /// Length-adaptive display type: a short aphorism lands monumental, a
    /// long passage sets like a book page. The old fixed .title2 treated a
    /// six-word line and a six-line paragraph identically.
    private var quoteFont: Font {
        switch highlight.text.count {
        case ..<90: CobuxTypography.display(colorScheme, size: largeQuoteSize, weight: .semibold)
        case ..<200: CobuxTypography.display(colorScheme, size: mediumQuoteSize, weight: .medium)
        default: CobuxTypography.display(colorScheme, size: smallQuoteSize, weight: .regular)
        }
    }

    var body: some View {
        FlowCardScaffold(
            accentHex: accentHex,
            // The shelf the line came from, appended to the kicker. One word,
            // same type, no new chrome -- and it is what stops Greene and
            // Aurelius arriving with identical authority. Taxonomy, never
            // evaluation: the word is the tradition's own name for itself.
            kicker: {
                let base = monthsAgo >= 3 ? "From your past self" : "From your library"
                guard let shelf = highlight.book?.tradition else { return base }
                return "\(base) · \(shelf.label)"
            }(),
            kickerIcon: monthsAgo >= 3 ? "clock.arrow.circlepath" : "quote.opening"
        ) {
            // Literally at the top now, under the kicker -- not just above
            // the quote inside the centered content block, which is where
            // "moved up from the footer" actually landed it before. Still
            // the same reasoning as that first move: the book/chapter is
            // what orients a quote seen out of context.
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Text(highlight.book?.title ?? "Unknown")
                        .font(.subheadline.weight(.medium))
                    // Liked state still needs to be *visible* now that the button is gone,
                    // otherwise double-tap is a gesture with no feedback once the burst
                    // animation ends. Small and at the top, away from the footer he asked
                    // to keep clear.
                    if highlight.isLiked {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.cobuxWarning)
                            .accessibilityLabel("Liked")
                    }
                }
                if monthsAgo >= 3 {
                    Text("Saved \(monthsAgo) month\(monthsAgo == 1 ? "" : "s") ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let chapterName = highlight.chapterRef?.title ?? highlight.chapter {
                    Text(chapterName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                Text("\u{201C}")
                    .font(CobuxTypography.display(colorScheme, size: quoteMarkSize, weight: .bold))
                    .foregroundStyle(Color(hex: accentHex).opacity(0.35))
                    .frame(height: quoteMarkHeight, alignment: .top)
                    // The glyph rides a slightly deeper plane than the text
                    // (-52 vs the scaffold's -40): two planes moving at
                    // different rates is what reads as physical depth on a
                    // swipe. Same mechanism the card already pays for, zero
                    // extra draw cost.
                    .scrollTransition(.interactive) { view, phase in
                        view.offset(y: reduceMotion ? 0 : phase.value * -12)
                    }
                    // Decoration. VoiceOver read "left double quotation
                    // mark" before every single passage in the feed.
                    .accessibilityHidden(true)

                Text(highlight.text)
                    .font(quoteFont)
                    .multilineTextAlignment(.leading)
                    // Engages now: the scaffold bounds this content to the
                    // band between header and footer, so a long passage at a
                    // large text size scales down to fit instead of running
                    // up into the book title and truncating.
                    .minimumScaleFactor(0.6)
                    // A saved highlight is user/book content with no length
                    // cap (Highlight.text) -- an unusually long passage
                    // (a full paragraph from one of the dense-philosophy or
                    // medical-textbook seeds) could otherwise grow past this
                    // page's fixed `containerRelativeFrame` height and bleed
                    // into the next card, since nothing here clips. The
                    // resonance card's quotes already cap at 5 lines for the
                    // same reason; this is the far more common card type, so
                    // it gets a generous cap instead -- comfortably more than
                    // any normal quote needs, just bounded.
                    .lineLimit(14)
            }
        } footer: {
            // ONE row, three controls, one type scale -- Fable's ruling on the
            // seventh report of this area ("the open Cobux position is much
            // better but still congested"). Position had been fixed and count
            // had been fixed; what was left was COMPOSITION. The row carried
            // three controls at two type scales and two heights: a
            // caption-sized labelled "Go deeper" chip, a filled subheadline
            // "Open Cobux" pill, and a bare share glyph -- three different
            // weights competing for the eye in one line.
            //
            // Now: the primary in the middle, and two symmetric icon HANDLES
            // flanking it -- Go deeper leading, Share trailing, the order he
            // asked for. Every control is a `Label`; the handles render
            // icon-only. All three share the pill's type scale and the row's
            // exact height (`fixedSize` + the handles' `maxHeight: .infinity`
            // -- equal heights by layout, not arithmetic). The handles wear
            // the quiet chip's wash, the pill wears the book's accent, so the
            // one-saturation rule still holds and the row reads as a single
            // instrument with one primary instead of three unrelated buttons.
            //
            // Nothing he asked for is removed: Go deeper, Open Cobux and
            // Share are all here, and still the only row (the single-row
            // guard stays true). The Like button stays gone -- "i dont like
            // the like to down at bottom in the first place" -- liking is the
            // double-tap, and the deliberate unlike lives in the quiet menu
            // one hold away (`.contextMenu` below).
            //
            // Both handles survive a nil `highlight.book` (a Share-Extension
            // capture left Unsorted): `FlowContextSheet` degrades gracefully
            // without one, and `shareLink` falls back to the bare quote.
            HStack(spacing: CobuxSpacing.md) {
                // The reference affordance, exactly per Rajan's brief: dive
                // into this highlight's context, then one swipe down and
                // you're back in Flow — never a rabbit hole out of it.
                Button {
                    showingContext = true
                } label: {
                    FlowHandle(title: "Go deeper", systemImage: "chevron.up", tint: accent)
                }
                .buttonStyle(.plain)

                // Take THIS highlight into chat -- his ask verbatim:
                // "there still should be an option from flow so that a
                // highlight a user can go in the chat, taking that
                // highlight, the way we have the things set up in the iOS
                // widget where it essentially does the same thing." So it
                // literally IS the widget's mechanism: the same
                // `cobux://book/<id>/highlight/<id>` deep link, opened on
                // ourselves -- `ContentView.onOpenURL` routes it into the
                // book's chat thread with the quote pre-filled, identical
                // to a widget tap, with zero new plumbing to drift apart.
                // This IS "Open Cobux": the global pill that used to sit
                // under the card moved here, keeping its name, icon and
                // prominence and gaining the highlight as payload. Tinted to
                // the BOOK's accent, not the app's: a fixed indigo pill on an
                // orange book's card reads as foreign.
                Button(action: openCobux) {
                    Label("Open Cobux", systemImage: "message.fill")
                        .cobuxPrimaryPill(tint: accent)
                }
                .buttonStyle(.plain)

                // Backend-free by design: shares the same
                // `cobux://book/<id>/highlight/<id>` deep link the widget's
                // own tap already uses. If the recipient has Cobux, it opens
                // straight to this highlight; if not, the quote text
                // alongside the link still reads fine on its own.
                shareLink {
                    FlowHandle(title: "Share", systemImage: "square.and.arrow.up", tint: accent)
                }
                // `.plain`, like its siblings. Without it the ShareLink drew
                // its glyph in the system tint while Go deeper drew in the
                // label colour -- a fourth voice in a three-control row.
                .buttonStyle(.plain)
            }
            // The whole row scales together and caps together: three
            // capsules in one row truncate past accessibility1.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .fixedSize(horizontal: false, vertical: true)
        }
        // Double-tap to like, the gesture people already have muscle memory
        // for. Attached here (outside the scaffold) so the whole card is the
        // target, and `count: 2` before any single-tap handler so it can't be
        // swallowed. Paging still works: a vertical drag is never a tap.
        //
        // `contentShape` is what actually makes "anywhere on the screen" true.
        // SwiftUI only hit-tests where there is drawn content, and this card is
        // mostly empty space around a quote positioned at a fraction of the
        // height -- so without this the gesture worked ONLY on the text itself,
        // which is exactly what he reported. Declaring the shape makes the
        // whole frame a target, including the blank areas above and below.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { handleDoubleTap() }
        // VoiceOver's double-tap is "activate", so the like gesture was a
        // path it could never take -- this is the same action, named.
        .accessibilityAction(named: "Like") { handleDoubleTap() }
        .overlay { LikeBurst(trigger: burstTrigger) }
        // The quiet menu. Nothing is added to the card face -- his "don't
        // clutter the bottom" stance holds exactly -- yet every action is one
        // hold away, anywhere on the card. It is also the ONLY unlike path in
        // Flow, deliberately: a double-tap can only ever like (see
        // `handleDoubleTap`), so taking a like back is a held, read, chosen
        // menu item and never an accidental second tap.
        .contextMenu {
            Button(action: toggleLike) {
                Label(highlight.isLiked ? "Unlike" : "Like",
                      systemImage: highlight.isLiked ? "heart.slash" : "heart")
            }
            Button {
                showingContext = true
            } label: {
                Label("Go deeper", systemImage: "chevron.up")
            }
            Button(action: openCobux) {
                Label("Open Cobux", systemImage: "message.fill")
            }
            shareLink {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            // Per-card, permanent, and quiet -- the per-BOOK "Hide from Flow"
            // in the library's own menu, brought down to one line. Last in
            // the menu and in plain type, not `.destructive` red: nothing is
            // deleted, and a red row would make a preference read as a
            // warning. Tapping it hides the card and does nothing else -- no
            // toast, no undo prompt -- because Cobux never grades or nags.
            // The way back is "Show hidden highlights again" in Sources.
            Button {
                onSuppress(highlight.id)
            } label: {
                Label("Don't show this again", systemImage: "eye.slash")
            }
        } preview: {
            // A compact lift of the quote itself rather than the system's
            // snapshot of a full, mostly-transparent card on a platter.
            VStack(alignment: .leading, spacing: CobuxSpacing.sm) {
                Text(highlight.text)
                    .font(CobuxTypography.passage(size: 17))
                    .lineSpacing(4)
                if let title = highlight.book?.title {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                }
            }
            .padding(CobuxSpacing.screenMargin)
            .frame(maxWidth: 320, alignment: .leading)
            .cobuxGlassTranslucent(shape: RoundedRectangle(cornerRadius: CobuxRadius.card))
        }
        .sheet(isPresented: $showingContext) {
            FlowContextSheet(highlight: highlight)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var accent: Color { Color(hex: accentHex) }

    /// One route for the pill and the menu item, so they can never drift.
    /// An Unsorted highlight (no book) still gets to chat, just without the
    /// book scope -- the same degradation Share makes.
    private func openCobux() {
        let url = highlight.book.map {
            CobuxDeepLink.highlightURL(bookID: $0.id, highlightID: highlight.id)
        } ?? URL(string: "cobux://chat")!
        dismiss()
        openURL(url)
    }

    /// The menu's like item. Liking goes through `handleDoubleTap` so it
    /// bursts and confirms itself exactly like the gesture; unliking is quiet.
    private func toggleLike() {
        if highlight.isLiked {
            highlight.isLiked = false
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        } else {
            handleDoubleTap()
        }
    }

    /// One Share for the row handle and the menu item. With a book it
    /// carries the widget's own deep link; without one, the bare quote.
    @ViewBuilder
    private func shareLink<L: View>(@ViewBuilder label: () -> L) -> some View {
        if let book = highlight.book {
            ShareLink(
                item: CobuxDeepLink.highlightURL(bookID: book.id, highlightID: highlight.id),
                message: Text("\u{201C}\(highlight.text)\u{201D} — \(book.title), via Cobux"),
                label: label
            )
        } else {
            ShareLink(item: "\u{201C}\(highlight.text)\u{201D} — via Cobux", label: label)
        }
    }
}

/// One of the two symmetric grips that flank a Flow row's primary pill.
///
/// The quiet chip's wash (the accent at 0.15, `cobuxQuietChip`'s own value)
/// at the primary pill's type scale, rendered icon-only so two of them can sit
/// either side of a labelled pill without the row growing past a phone's
/// width at large text. `maxHeight: .infinity` is deliberate and is what makes
/// the handle exactly as tall as the pill beside it -- so it must only ever
/// live in a row that is `.fixedSize(horizontal: false, vertical: true)`,
/// which sizes the row to its tallest child and lets the handle fill it.
///
/// The `Label` keeps its title for VoiceOver even though it draws only the
/// glyph; `accessibilityLabel` restates it so the name cannot depend on a
/// label style.
private struct FlowHandle: View {
    let title: String
    let systemImage: String
    let tint: Color

    /// The glyph's box. Fixed (and scaled with the pill's own text style) so
    /// the two handles are the SAME width whatever their glyphs' natural
    /// widths are -- `chevron.up` is narrower than `square.and.arrow.up`, and
    /// "symmetric" has to be true in points, not roughly. With the pill's
    /// vertical padding (`pillV`) on each side, box + padding equals the
    /// pill's height at every text size: each handle is a circle whose
    /// diameter is the row.
    @ScaledMetric(relativeTo: .subheadline) private var glyphBox: CGFloat = 20

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(.subheadline.weight(.semibold))
            .frame(width: glyphBox, height: glyphBox)
            .padding(.horizontal, CobuxSpacing.pillV)
            .frame(maxHeight: .infinity)
            .background(tint.opacity(0.15), in: Capsule())
            .contentShape(Capsule())
            .accessibilityLabel(title)
    }
}

/// The "Go deeper" sheet: chapter summary, key lessons, and the sibling
/// highlights around this quote. Structurally guaranteed to return to Flow —
/// it's a sheet over the feed with zero outbound navigation.
private struct FlowContextSheet: View {
    let highlight: Highlight

    /// chapterRef first, free-text string as fallback — the repo's own
    /// convention (see Book.highlights(in:)): the relationship survives a
    /// chapter rename, the string doesn't.
    private func resolveChapter() -> Chapter? {
        if let chapterRef = highlight.chapterRef { return chapterRef }
        guard let chapterTitle = highlight.chapter else { return nil }
        return highlight.book?.chapters.first { $0.title == chapterTitle }
    }

    private func resolveSiblings(_ chapter: Chapter?) -> [Highlight] {
        guard let book = highlight.book, let chapter else { return [] }
        return book.highlights(in: chapter).filter { $0.id != highlight.id }
    }

    var body: some View {
        ScrollView {
            // Both resolved ONCE, at the top of the sheet's body.
            //
            // They were computed properties, and `body` touched `chapter` four
            // times and `siblings` twice -- and `siblings` recomputed `chapter`
            // itself. Each `chapter` resolution faults the book's whole
            // `chapters` relationship; each `siblings` resolution calls
            // `Book.highlights(in:)`, which faults the book's ENTIRE highlights
            // relationship, filters it and sorts it. On a reference text that
            // is thousands of rows, six times over, between the tap on "Go
            // deeper" and the sheet's first frame.
            let chapter = resolveChapter()
            let siblings = resolveSiblings(chapter)
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(highlight.book?.title ?? "")
                        .font(.headline)
                    if let chapter {
                        Text(chapter.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                // The card itself caps this quote at 14 lines so a long
                // passage can't bleed past its page into the next card while
                // scrolling -- this sheet is where "Go deeper" promises the
                // rest, so the full, untruncated text belongs here
                // unconditionally, not just the fields below that only show
                // up when a chapter/note/siblings happen to exist.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Full quote")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(highlight.text)
                        .font(.subheadline)
                }

                if let note = highlight.personalNote, !note.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your note")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(note)
                            .font(.subheadline)
                            .italic()
                    }
                }

                if let chapter, !chapter.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Chapter summary")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(chapter.summary)
                            .font(.subheadline)
                    }
                }

                if let chapter, !chapter.keyLessons.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Key lessons")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(chapter.keyLessons.indices, id: \.self) { index in
                            Label(chapter.keyLessons[index], systemImage: "lightbulb")
                                .font(.subheadline)
                        }
                    }
                }

                if !siblings.isEmpty {
                    // Lazy: a chapter of a reference text can carry hundreds of
                    // sibling lines, and a plain VStack builds every card
                    // before the sheet can show its first.
                    LazyVStack(alignment: .leading, spacing: 8) {
                        Text("Nearby highlights")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(siblings) { sibling in
                            Text("\u{201C}\(sibling.text)\u{201D}")
                                .font(.subheadline)
                                .italic()
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // The tokenized translucent variant this site's old comment
                                // asked for: real glass on iOS 26, the exact same
                                // .thinMaterial below it, still see-through either way so
                                // the atmosphere cross-fade survives.
                                .cobuxGlassTranslucent(shape: RoundedRectangle(cornerRadius: CobuxRadius.card))
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct KeyLessonFlowCard: View {
    let chapter: Chapter
    let lessonIndex: Int
    @Environment(\.openURL) private var openURL
    /// Flow is presented as a `fullScreenCover` (ContentView.swift, WisdomGraphView.swift).
    /// Every in-card Chat button called `openURL` WITHOUT dismissing it, so the
    /// app really did switch tabs and prefill the composer -- underneath a cover
    /// that still filled the screen. To the user, tapping Chat did nothing.
    /// FlowView's own bottom button already had this right: dismiss, then open.
    @Environment(\.dismiss) private var dismiss

    private var lesson: String {
        guard chapter.keyLessons.indices.contains(lessonIndex) else { return "" }
        return chapter.keyLessons[lessonIndex]
    }

    var body: some View {
        FlowCardScaffold(
            accentHex: chapter.book?.coverColorHex ?? "#6366F1",
            kicker: "Key lesson",
            kickerIcon: "lightbulb.fill"
        ) {
            // Same move the quote card already got: the book and chapter orient a
            // card seen out of context, so they belong at the top where the eye
            // starts, not under the content. The scaffold's own doc comment used to
            // claim the quote card was "the only one with a book/chapter to name up
            // there", which is why these two were left behind.
            VStack(spacing: 2) {
                Text(chapter.book?.title ?? "Unknown")
                    .font(.subheadline.weight(.medium))
                Text(chapter.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } content: {
            Text(lesson)
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
        } footer: {
            // This card type had NO actions at all -- its footer was literally
            // `EmptyView()`. So part of "go deeper and share disappear on some
            // highlights" was never the nil-book bug: a whole card type simply
            // never had them, and there was no way to act on a key lesson.
            //
            // Same row grammar as the highlight card (see its footer for the
            // ruling): the one filled pill and Share as an icon handle at the
            // pill's own type scale -- one row, one scale, so this card and
            // its neighbours read as the same instrument on a swipe.
            HStack(spacing: CobuxSpacing.md) {
                // Chat rather than Go deeper: `FlowContextSheet` is built around
                // a Highlight (its siblings, its chapter position) and a key
                // lesson has none of that. Taking the lesson into the book's own
                // thread is the useful move anyway -- a lesson is exactly the
                // kind of thing worth arguing with. Same rename as the
                // highlight card, and for the same reason: this already did
                // what the deleted global button did, only better, because it
                // carries the lesson.
                Button(action: openCobux) {
                    Label("Open Cobux", systemImage: "message.fill")
                        .cobuxPrimaryPill(tint: accent)
                }
                .buttonStyle(.plain)

                ShareLink(item: shareText) {
                    FlowHandle(title: "Share", systemImage: "square.and.arrow.up", tint: accent)
                }
                .buttonStyle(.plain)
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .fixedSize(horizontal: false, vertical: true)
        }
        // The quiet menu -- every action one hold away, nothing added to the
        // card face. See `HighlightFlowCard`.
        .contextMenu {
            Button(action: openCobux) {
                Label("Open Cobux", systemImage: "message.fill")
            }
            ShareLink(item: shareText) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        } preview: {
            FlowMenuPreview(text: lesson, caption: chapter.book?.title, tint: accent)
        }
    }

    private var accent: Color { Color(hex: chapter.book?.coverColorHex ?? "#6366F1") }

    private var shareText: String {
        "\(lesson)\n\n— \(chapter.book?.title ?? "Cobux"), \(chapter.title)"
    }

    /// Carries the lesson itself. A bare book URL opened an empty thread, so
    /// "take this lesson into chat" landed the user somewhere with no idea
    /// what they had tapped.
    private func openCobux() {
        let url = chapter.book.map {
            CobuxDeepLink.bookURL(bookID: $0.id, prefill: lesson)
        } ?? URL(string: "cobux://chat")!
        dismiss()
        openURL(url)
    }
}

/// The quiet menu's lift: the card's own text alone on glass, rather than the
/// system's snapshot of a full, mostly-transparent card on a platter.
private struct FlowMenuPreview: View {
    let text: String
    let caption: String?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: CobuxSpacing.sm) {
            Text(text)
                .font(CobuxTypography.passage(size: 17))
                .lineSpacing(4)
                .lineLimit(12)
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }
        }
        .padding(CobuxSpacing.screenMargin)
        .frame(maxWidth: 320, alignment: .leading)
        .cobuxGlassTranslucent(shape: RoundedRectangle(cornerRadius: CobuxRadius.card))
    }
}

/// The self-test card: prompt up front, unblur-to-reveal, then two gentle
/// grade buttons that feed REAL FSRS scheduling (`.again`/`.good` only) and
/// count as showing up for the streak. `FlowQueueBuilder`'s 12-hour guard
/// keeps a card from being re-graded twice in one sitting.
private struct ClozeTeaserFlowCard: View {
    let question: QuizQuestion
    /// See `FlowCardView.onSuppress`. Hides this check from FLOW only: its
    /// FSRS schedule is untouched and it still comes up in the Quiz tab.
    let onSuppress: (UUID) -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(FlowSessionStats.self) private var stats
    @Environment(\.openURL) private var openURL
    /// See the note on the other cards: Flow is a `fullScreenCover`, so any
    /// navigation out of a card has to dismiss it first or the destination
    /// opens invisibly underneath.
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var graded = false
    // No `sealedTheDay`. It rendered "Day N sealed" when a grade was the
    // day's first activity -- a completion state, which this app does not
    // issue (the same frame the opener's "Sealed" was removed for). It was
    // also unreachable: FlowView records today's activity in its own
    // `onAppear` before any card exists, so by the time a check could be
    // graded here `hasShownUpToday` was always already true.

    /// @State dies when the LazyVStack recycles a far-offscreen card, so the
    /// model itself is the source of truth for "already graded this sitting"
    /// — without this, scrolling far away and back re-arms the grade buttons
    /// and a second tap would double-write real FSRS state.
    private var alreadyGradedThisSitting: Bool {
        guard let lastReviewedAt = question.lastReviewedAt else { return false }
        return Date.now.timeIntervalSince(lastReviewedAt) < FlowQueueBuilder.clozeReReviewGuard
    }
    private var showsAsGraded: Bool { graded || alreadyGradedThisSitting }

    private var accentHex: String { question.book?.coverColorHex ?? "#6366F1" }

    private var answerText: String {
        guard let index = question.correctAnswerIndex,
              question.choices.indices.contains(index) else { return question.explanation }
        return question.choices[index]
    }

    private var shareText: String {
        var out = "\(question.prompt)\n\n\(answerText)"
        if let title = question.book?.title { out += "\n\n— \(title), via Cobux" }
        return out
    }

    /// Fading-memory framing: when FSRS predicts this card is genuinely
    /// slipping (retrievability under 0.6), the kicker says so — "rescue it"
    /// beats "quiz yourself" as a reason to tap. Suppressed at night for the
    /// same reason the queue drops weak-topic cards then: no failure-framing
    /// as a bedtime story.
    private var isSlipping: Bool {
        guard !FlowQueueBuilder.isNight(.now) else { return false }
        guard let lastReviewedAt = question.lastReviewedAt, question.fsrsStability > 0 else { return false }
        let elapsedDays = max(0, Date.now.timeIntervalSince(lastReviewedAt) / 86400)
        return FSRS.retrievability(elapsedDays: elapsedDays, stability: max(question.fsrsStability, 0.01)) < 0.6
    }

    private var lastSeenDays: Int? {
        guard let lastReviewedAt = question.lastReviewedAt else { return nil }
        return Calendar.current.dateComponents([.day], from: lastReviewedAt, to: .now).day
    }

    var body: some View {
        FlowCardScaffold(
            accentHex: accentHex,
            kicker: isSlipping ? "Slipping away" : "Quick check",
            kickerIcon: isSlipping ? "hourglass" : "brain.head.profile"
        ) {
            // Moved up from the footer, same as the quote and key-lesson cards.
            Text(question.book?.title ?? "Unknown")
                .font(.subheadline.weight(.medium))
        } content: {
            VStack(spacing: 20) {
                Text(question.prompt)
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)

                // The reveal ceremony: the answer is ALWAYS rendered, hidden
                // behind blur — tapping wipes the fog off glass rather than
                // sliding new content in.
                ZStack {
                    Text(answerText)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(14)
                        .frame(maxWidth: .infinity)
                        // Tokenized translucent glass: real glass on iOS 26, the same
                        // .thinMaterial below, see-through either way so the atmosphere
                        // cross-fade survives.
                        .cobuxGlassTranslucent(shape: RoundedRectangle(cornerRadius: CobuxRadius.card))
                        .blur(radius: revealed ? 0 : 14)
                        .opacity(revealed ? 1 : 0.55)

                    if !revealed {
                        Label("Tap to reveal", systemImage: "eye")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: CobuxRadius.card))
                .onTapGesture {
                    guard !revealed else { return }
                    // Reduce Motion is a gate: the fog still lifts, without
                    // the spring's bounce.
                    withAnimation(reduceMotion ? .easeOut(duration: 0.3) : .spring(duration: 0.5, bounce: 0.2)) {
                        revealed = true
                    }
                }
                .sensoryFeedback(.impact(flexibility: .rigid), trigger: revealed)
            }
        } footer: {
            VStack(spacing: 10) {
                if revealed && !showsAsGraded {
                    HStack(spacing: 12) {
                        gradeButton(title: "Didn't know", isCorrect: false, tint: .cobuxWarning)
                        gradeButton(title: "Got it", isCorrect: true, tint: .cobuxGood)
                    }
                } else if showsAsGraded {
                    // A scheduling fact under a calendar -- not a tick. The
                    // tick is to-do vocabulary: it asserts a task existed and
                    // was completed, which is a grade. Where the card went
                    // next is information; whether he "got it" is not the
                    // app's to announce.
                    Label(nextReviewText, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let lastSeenDays, isSlipping, !showsAsGraded {
                    Text("Last seen \(lastSeenDays) day\(lastSeenDays == 1 ? "" : "s") ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Grading is the primary action, so these sit under it rather
                // than competing with it -- but a card carrying real book text
                // should never be a dead end.
                HStack(spacing: 10) {
                    Button(action: openCobux) {
                        // Renamed for consistency with the other cards, but
                        // deliberately left TINTED rather than filled: this
                        // card's primary is its grade buttons above, and two
                        // filled pills on one card would rebuild the competing-
                        // hierarchy problem this whole change exists to remove.
                        Label("Open Cobux", systemImage: "message.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color(hex: accentHex).opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Chat about this question")

                    ShareLink(item: shareText) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color(hex: accentHex).opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share this question")
                }
                // Same cap FlowView's own button uses: three capsules in one
                // row truncate at large accessibility sizes, which is a
                // plausible mechanism for "the share button disappears".
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
            .sensoryFeedback(.success, trigger: graded)
        }
        // The quiet menu. The footer's two actions and the one dismissal --
        // and nothing that could reveal the answer.
        .contextMenu {
            Button(action: openCobux) {
                Label("Open Cobux", systemImage: "message.fill")
            }
            ShareLink(item: shareText) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            // Same item, same words, same place as the quote card's, so the
            // hold-menu means one thing across Flow. Hides the check from the
            // feed; grading in the Quiz tab is unaffected.
            Button {
                onSuppress(question.id)
            } label: {
                Label("Don't show this again", systemImage: "eye.slash")
            }
        } preview: {
            FlowMenuPreview(text: question.prompt, caption: question.book?.title, tint: Color(hex: accentHex))
        }
    }

    /// Where the card went, never a verdict on the answer: the next review's
    /// day when FSRS has set one, or simply that it is scheduled.
    private var nextReviewText: String {
        guard let due = question.dueDate, due > .now else { return "Scheduled for review" }
        let calendar = Calendar.current
        if calendar.isDateInToday(due) { return "Back later today" }
        if calendar.isDateInTomorrow(due) { return "Back tomorrow" }
        return "Back \(due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))"
    }

    private func openCobux() {
        let url = question.book.map {
            CobuxDeepLink.bookURL(bookID: $0.id,
                                  prefill: "\(question.prompt)\n\n\(answerText)")
        } ?? URL(string: "cobux://chat")!
        dismiss()
        openURL(url)
    }

    private func gradeButton(title: String, isCorrect: Bool, tint: Color) -> some View {
        Button {
            guard !alreadyGradedThisSitting else { return }
            FSRSService.recordReview(for: question, isCorrect: isCorrect, confidence: nil)
            try? modelContext.save()
            StreakTracker.recordActivityToday()
            StreakCelebrationCenter.shared.checkForPendingMilestone()
            stats.recordGrade(correct: isCorrect)
            // Flow just graded a card the Quick Check widget may be showing.
            WidgetCenter.shared.reloadTimelines(ofKind: "CobuxQuickCheckWidget")
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy) {
                graded = true
            }
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
    }
}

private struct WeakTopicFlowCard: View {
    let topic: String
    let lapseCount: Int
    @Environment(\.openURL) private var openURL
    /// Flow is a fullScreenCover; navigating out of a card without dismissing
    /// opens the destination underneath it.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        FlowCardScaffold(
            accentHex: "#F97316",
            kicker: "Worth revisiting",
            kickerIcon: "exclamationmark.triangle.fill"
        ) {
            VStack(spacing: 12) {
                Text(topic.capitalized)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                // "has tripped you up" was the app grading him -- user-fault
                // language on an ambient card, exactly what the no-grading
                // principle exists to keep out. Describe the material's
                // difficulty, never his performance against it.
                Text("This topic has put up more of a fight than most. A Weak Spots session in the Quiz tab would meet it directly.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } footer: {
            VStack(spacing: 10) {
                Text("came back \(lapseCount) time\(lapseCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // The card's own text says a Weak Spots session would hit this
                // topic directly. It should not then make the user go find it.
                Button {
                    dismiss()
                    openURL(CobuxDeepLink.quizURL())
                } label: {
                    // A door into the Quiz tab, in Flow's own check glyph --
                    // not a tick. A tick on a card about a topic he has lapsed
                    // on reads as a box he has failed to check.
                    Label("Open Quiz", systemImage: "brain.head.profile")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color(hex: "#F97316").opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open the Quiz tab to practise this topic")
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
    }
}

// The book-progress card (an instrument-grade "you're 34% through Sapiens"
// gauge) used to live here. Removed deliberately, in Rajan's own framing: a
// card whose whole job is to show how INCOMPLETE a book is "can make a user
// disappointed and go away". Flow is the browsing surface — progress belongs
// on the book's own screen, where you go looking for it, not dealt to you
// unasked between two quotes you were enjoying.

/// First card of the session: where today stands. Status report, not stakes —
/// the panel's critic killed the "keep day 47 alive" greeting and was right.
private struct DailyOpenerFlowCard: View {
    let streak: Int
    let dueCount: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the flame's entrance animation (see the `.onAppear` below).
    @State private var flameScale: CGFloat = 0.4
    @State private var flameGlow: Double = 0

    var body: some View {
        FlowCardScaffold(
            accentHex: "#F59E0B",
            kicker: "Today",
            kickerIcon: "sunrise.fill"
        ) {
            VStack(spacing: 16) {
                if streak > 0 {
                    Label {
                        Text("\(streak)-day streak")
                    } icon: {
                        // Duolingo-style: the flame should feel alive the
                        // moment the card lands, not sit as static chrome.
                        // `.symbolEffect(.pulse)` alone was far too subtle to
                        // read as an animation at all (Rajan: "I don't see an
                        // animation"). This is a real entrance -- the flame
                        // scales up and settles on a spring, with a warm glow
                        // behind it, then keeps a slow ambient pulse.
                        Image(systemName: "flame.fill")
                            .scaleEffect(flameScale)
                            .shadow(color: Color.cobuxWarning.opacity(flameGlow), radius: 14)
                            // The one-shot entrance below was gated; this
                            // ambient pulse was not, so with Reduce Motion on
                            // the flame stopped rising and then breathed
                            // forever -- a repeating animation is the kind the
                            // setting exists for most.
                            .symbolEffect(.pulse, isActive: !reduceMotion)
                    }
                    .font(.title.bold())
                    .foregroundStyle(Color.cobuxWarning)
                    .onAppear {
                        flameGlow = 0
                        // Reduce Motion is a gate: no scale-in, the flame
                        // simply arrives at size and only the glow fades up.
                        if reduceMotion {
                            flameScale = 1.0
                        } else {
                            flameScale = 0.4
                            withAnimation(.spring(response: 0.55, dampingFraction: 0.5)) {
                                flameScale = 1.0
                            }
                        }
                        withAnimation(.easeOut(duration: 0.8)) {
                            flameGlow = 0.85
                        }
                    }
                } else {
                    Text("A fresh start")
                        .font(.title.bold())
                }

                // No "you've already been here today" line. It was the ONLY
                // line this card ever rendered: ContentView records today's
                // activity on every `.active`, and FlowView records it again
                // before the batch that deals this card is built, so
                // `hasShownUpToday` was always true by the time the opener
                // existed -- the due count and "Nothing due" below were
                // unreachable, and the first open of the day told him he had
                // already been here. The opener is dealt at most once a day
                // anyway, so "already been here" could never be a meaningful
                // thing for it to say. Facts only, honestly reached.
                if dueCount > 0 {
                    Text("\(dueCount) card\(dueCount == 1 ? " is" : "s are") ripe for review, whenever you feel like one.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Nothing due. Just flow.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Label("Swipe up to begin", systemImage: "chevron.up.2")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The set-complete beat: honest session tallies from `FlowSessionStats`,
/// plus the tomorrow line that plants the return hook without guilt.
private struct SessionRecapFlowCard: View {
    let setNumber: Int
    let ripeningTomorrow: Int
    let nextBook: String?
    @Environment(FlowSessionStats.self) private var stats

    var body: some View {
        FlowCardScaffold(
            accentHex: "#10B981",
            // "Set N", not "Set N done", and Flow's own waves rather than a
            // sealed checkmark. A recap is a breath between sets -- a place
            // the feed pauses to say what passed -- not a completion state
            // this app awards. Every number below stays: numbers are facts;
            // ticks and "done" are grades, the exact vocabulary his registry
            // records removed from the widget and the rest of the app.
            kicker: "Set \(setNumber)",
            kickerIcon: "water.waves"
        ) {
            VStack(spacing: 14) {
                statLine("quote.opening", "\(stats.quotesSeen) quotes revisited")
                if stats.lessonsSeen > 0 {
                    statLine("lightbulb.fill", "\(stats.lessonsSeen) lessons refreshed")
                }
                if stats.checksGraded > 0 {
                    // "N of M recalled": what happened, without a verdict on
                    // it. "Checks right" scored him.
                    statLine("brain.head.profile", "\(stats.checksCorrect) of \(stats.checksGraded) recalled — all scheduled")
                }
                statLine("books.vertical.fill", "\(stats.booksTouched.count) book\(stats.booksTouched.count == 1 ? "" : "s") touched")
            }
        } footer: {
            VStack(spacing: 4) {
                if ripeningTomorrow > 0 {
                    Text("Tomorrow: \(ripeningTomorrow) card\(ripeningTomorrow == 1 ? "" : "s") ripen overnight")
                        .font(.caption.weight(.medium))
                }
                if let nextBook {
                    Text("\(nextBook) has territory left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // A finished set is the one thing in Flow a person actually
                // wants to show someone, and it was the only card with no way
                // to do it.
                ShareLink(item: recapText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color(hex: "#10B981").opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share this session recap")
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
    }

    private var recapText: String {
        var lines = ["Cobux — set \(setNumber)",
                     "\(stats.quotesSeen) quotes revisited"]
        if stats.lessonsSeen > 0 { lines.append("\(stats.lessonsSeen) lessons refreshed") }
        if stats.checksGraded > 0 {
            lines.append("\(stats.checksCorrect) of \(stats.checksGraded) recalled")
        }
        lines.append("\(stats.booksTouched.count) book\(stats.booksTouched.count == 1 ? "" : "s") touched")
        return lines.joined(separator: "\n")
    }

    private func statLine(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
    }
}

/// The gold card: two highlights from two different books, matched by the
/// embeddings the library already stores. Rare on purpose.
private struct ResonanceFlowCard: View {
    let first: Highlight
    let second: Highlight
    @Environment(\.openURL) private var openURL
    /// Flow is presented as a `fullScreenCover` (ContentView.swift, WisdomGraphView.swift).
    /// Every in-card Chat button called `openURL` WITHOUT dismissing it, so the
    /// app really did switch tabs and prefill the composer -- underneath a cover
    /// that still filled the screen. To the user, tapping Chat did nothing.
    /// FlowView's own bottom button already had this right: dismiss, then open.
    @Environment(\.dismiss) private var dismiss

    private let accentHex = "#EAB308"

    // Real bug, reported live: this card shows two genuine highlights but,
    // unlike `HighlightFlowCard`, never gave either one a "Go deeper" or
    // Share affordance at all -- a resonance card read as a dead end
    // compared to every other highlight-bearing card in the feed.
    // `contextHighlight` drives one shared sheet for whichever of the two
    // quotes was tapped, rather than two separate `@State` bools.
    @State private var contextHighlight: Highlight?

    var body: some View {
        FlowCardScaffold(
            accentHex: accentHex,
            kicker: "Two books, one idea",
            kickerIcon: "sparkles"
        ) {
            VStack(spacing: 18) {
                resonanceQuote(first)
                Image(systemName: "arrow.triangle.merge")
                    .font(.title3)
                    .foregroundStyle(Color(hex: accentHex))
                    // Decoration between the two quotes; the kicker already
                    // says "Two books, one idea".
                    .accessibilityHidden(true)
                resonanceQuote(second)
            }
        } footer: {
            Text("Your library found this connection on its own")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(item: $contextHighlight) { highlight in
            FlowContextSheet(highlight: highlight)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func resonanceQuote(_ highlight: Highlight) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\u{201C}\(highlight.text)\u{201D}")
                .font(.system(.subheadline, design: .serif))
                .italic()
                .lineLimit(5)
                .minimumScaleFactor(0.7)
            HStack(spacing: 5) {
                Text(highlight.book?.title ?? "")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(hex: highlight.book?.coverColorHex ?? "#6366F1"))
                // The same liked mark the quote card wears in its header, so
                // a like taken from this quote's quiet menu is visible here.
                if highlight.isLiked {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.cobuxWarning)
                        .accessibilityLabel("Liked")
                }
            }

            // Compact icon-only pair, not the labeled capsule buttons
            // `HighlightFlowCard`'s footer uses -- this card already carries
            // two full quotes plus a merge glyph, so each quote's own action
            // row stays minimal rather than competing for vertical space.
            // Icon-only to the eye, never to VoiceOver: each carries its name.
            //
            // Unconditional now, same fix as `HighlightFlowCard`'s footer:
            // an Unsorted (never-filed) highlight has `book == nil`, which
            // used to make both icons vanish together for that quote.
            HStack(spacing: 16) {
                Button {
                    contextHighlight = highlight
                } label: {
                    Image(systemName: "chevron.up.circle")
                }
                .accessibilityLabel("Go deeper")
                // Same chat route `HighlightFlowCard`'s footer capsule takes
                // (the widget's own deep link), in this card's compact
                // icon-only voice.
                Button {
                    openCobux(highlight)
                } label: {
                    Image(systemName: "bubble.left.circle")
                }
                .accessibilityLabel("Open Cobux")
                shareLink(for: highlight) {
                    Image(systemName: "square.and.arrow.up.circle")
                }
                .accessibilityLabel("Share")
            }
            .font(.callout)
            .foregroundStyle(Color(hex: accentHex))
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Tokenized translucent glass: real glass on iOS 26, the same
        // .thinMaterial below, see-through either way so the atmosphere
        // cross-fade survives.
        .cobuxGlassTranslucent(shape: RoundedRectangle(cornerRadius: CobuxRadius.card))
        // The quiet menu, per quote: this card carries two highlights, so the
        // hold lands on the one under the finger. The glass block is its own
        // preview.
        .contextMenu {
            Button {
                toggleLike(highlight)
            } label: {
                Label(highlight.isLiked ? "Unlike" : "Like",
                      systemImage: highlight.isLiked ? "heart.slash" : "heart")
            }
            Button {
                contextHighlight = highlight
            } label: {
                Label("Go deeper", systemImage: "chevron.up")
            }
            Button {
                openCobux(highlight)
            } label: {
                Label("Open Cobux", systemImage: "message.fill")
            }
            shareLink(for: highlight) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func openCobux(_ highlight: Highlight) {
        let url = highlight.book.map {
            CobuxDeepLink.highlightURL(bookID: $0.id, highlightID: highlight.id)
        } ?? URL(string: "cobux://chat")!
        dismiss()
        openURL(url)
    }

    /// A toggle here, unlike the quote card's double-tap: there is no
    /// imprecise gesture on this card to protect from an accidental un-like,
    /// and a held, read, chosen menu item is deliberate by construction.
    private func toggleLike(_ highlight: Highlight) {
        highlight.isLiked.toggle()
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: highlight.isLiked ? .medium : .light).impactOccurred()
        #endif
    }

    /// One Share for the icon and the menu item. With a book it carries the
    /// widget's own deep link; without one, the bare quote.
    @ViewBuilder
    private func shareLink<L: View>(for highlight: Highlight, @ViewBuilder label: () -> L) -> some View {
        if let book = highlight.book {
            ShareLink(
                item: CobuxDeepLink.highlightURL(bookID: book.id, highlightID: highlight.id),
                message: Text("\u{201C}\(highlight.text)\u{201D} — \(book.title), via Cobux"),
                label: label
            )
        } else {
            ShareLink(item: "\u{201C}\(highlight.text)\u{201D} — via Cobux", label: label)
        }
    }
}

/// Something he wrote on this date in an earlier year, dealt into Flow.
///
/// The one card in Flow that is not from the library. Its rules are the
/// journal's, not Flow's: it quotes and dates and never characterizes, it only
/// appears when an echo genuinely exists on this calendar date, and its absence
/// is never mentioned — so it can never become a thing he failed to have.
///
/// It exists because Cobux is the only app on his phone holding both what he
/// has read and what he has lived, and handing a piece of the second back on
/// the one day it belongs to is the reason to open it unprompted.
private struct JournalEchoFlowCard: View {
    let entryID: UUID
    let date: Date
    let passage: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    private let accentHex = "#0EA5E9"
    private var accent: Color { Color(hex: accentHex) }

    private var yearsAgo: Int {
        // From startOfDay on both sides. Component arithmetic is time-of-day
        // sensitive, so an entry written at 22:00 two years ago today, read at
        // 09:00, counted as one year and the card said the wrong thing on the
        // one day it exists to be right about.
        let calendar = Calendar.current
        let from = calendar.startOfDay(for: date)
        let to = calendar.startOfDay(for: .now)
        return max(1, calendar.dateComponents([.year], from: from, to: to).year ?? 1)
    }

    var body: some View {
        // Behind the journal's own gate, at RENDER time -- not only at deal
        // time. `FlowView` refuses to deal this card while the journal is
        // locked, but a card already dealt used to stay readable full-screen
        // after the lock re-engaged: background the app (ContentView relocks
        // on `.background`), hand the phone over, foreground it, and his
        // passage was on screen with Face ID never asked. The check lived
        // in the deal, which is a decision made once; the lock is a state
        // that changes underneath it.
        //
        // So the card inherits the rule instead of remembering it: the same
        // `JournalLocked` every Journal screen and Ebb self-wrap with, around
        // the WHOLE card -- content, footer and kicker alike, because a locked
        // journal reveals nothing, not even that an entry exists on this
        // date. `autoPromptsWhenTopmost: false` because this is one card in a
        // paging feed of forty: a Face ID dialog ambushing a swipe past it
        // would be the wrong kind of surprise. He taps Unlock if he wants it.
        JournalLocked(autoPromptsWhenTopmost: false) {
            FlowCardScaffold(
                accentHex: accentHex,
                kicker: yearsAgo == 1 ? "A year ago today" : "\(yearsAgo) years ago today",
                kickerIcon: "book.closed.fill"
            ) {
                EmptyView()
            } content: {
                // ONE root view. This slot used to hold two bare `Text`s,
                // which SwiftUI hands the scaffold as two subviews -- and back
                // when the scaffold was a `ZStack`, each was positioned at the
                // same centre, so the date line rendered on top of the
                // passage. Same defect in the footer below, where Share sat on
                // top of Open Cobux. The scaffold is a `FlowCardLayout` now and
                // would stack them instead of overlapping them, but one root
                // view per slot is still the contract: it is what makes what
                // this card draws its own decision rather than the layout's.
                VStack(alignment: .leading, spacing: 0) {
                    Text(passage)
                        // The passage face -- his own writing is content, not
                        // chrome (the 3.0 typography ruling's one Flow-adjacent
                        // change; the library's quotes stay in display).
                        .font(CobuxTypography.passage(size: 22))
                        .lineSpacing(6)
                        .multilineTextAlignment(.leading)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(date.formatted(date: .long, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } footer: {
                // Same row grammar as the highlight card (see
                // `HighlightFlowCard`'s footer for the ruling): the one filled
                // pill, and Share as an icon handle at the pill's own type
                // scale, in one row.
                HStack(spacing: CobuxSpacing.md) {
                    Button(action: openCobux) {
                        Label("Open Cobux", systemImage: "message.fill")
                            .cobuxPrimaryPill(tint: accent)
                    }
                    .buttonStyle(.plain)

                    // The reminder's exact words: "the share button still doesn't
                    // appear for every highlight in flow." This was the last
                    // content-bearing card without one. His words leave bare -- no
                    // "via Cobux" suffix: the book-quote attribution style would
                    // stamp the app's name onto HIS writing, and shared text must
                    // read as his.
                    ShareLink(item: passage) {
                        FlowHandle(title: "Share", systemImage: "square.and.arrow.up", tint: accent)
                    }
                    .buttonStyle(.plain)
                }
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .fixedSize(horizontal: false, vertical: true)
            }
            // The quiet menu -- inside the gate, so a locked card offers
            // neither his passage to share nor a way to carry it into chat.
            .contextMenu {
                Button(action: openCobux) {
                    Label("Open Cobux", systemImage: "message.fill")
                }
                ShareLink(item: passage) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private func openCobux() {
        dismiss()
        openURL(CobuxDeepLink.journalChatURL(prefill: passage))
    }
}
