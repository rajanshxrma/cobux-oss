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

    var body: some View {
        switch card {
        case .highlight(let highlight):
            HighlightFlowCard(highlight: highlight)
        case .keyLesson(let chapter, let lessonIndex):
            KeyLessonFlowCard(chapter: chapter, lessonIndex: lessonIndex)
        case .clozeTeaser(let question):
            ClozeTeaserFlowCard(question: question)
        case .weakTopic(let topic, let lapseCount):
            WeakTopicFlowCard(topic: topic, lapseCount: lapseCount)
        case .dailyOpener(let streak, let dueCount):
            DailyOpenerFlowCard(streak: streak, dueCount: dueCount)
        case .sessionRecap(let setNumber, let ripeningTomorrow, let nextBook):
            SessionRecapFlowCard(setNumber: setNumber, ripeningTomorrow: ripeningTomorrow, nextBook: nextBook)
        case .resonance(let first, let second):
            ResonanceFlowCard(first: first, second: second)
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
        GeometryReader { geo in
            ZStack(alignment: .top) {
                VStack(spacing: 6) {
                    Label(kicker, systemImage: kickerIcon)
                        .font(.caption.weight(.semibold))
                        .kerning(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(accent)
                    header
                }
                .padding(.top, 68)
                .frame(maxWidth: .infinity, alignment: .top)

                // 0.455, not 0.5: the eye reads the true midpoint as sitting
                // slightly low, which is why macOS alerts and well-set title
                // pages are nudged up rather than centered. His words: "the
                // human eye reads a little over the middle."
                content
                    .padding(.horizontal, 28)
                    .scrollTransition(.interactive) { view, phase in
                        view.offset(y: phase.value * -40)
                    }
                    .frame(maxWidth: .infinity)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.455)

                footer
                    // Clearance is no longer this view's problem: "Open Cobux"
                    // is a safeAreaInset on FlowView now, so the space it needs
                    // is already reserved before this lays out at all.
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollTransition(.interactive) { view, phase in
            view
                .scaleEffect(phase.isIdentity ? 1 : 0.94)
                .opacity(phase.isIdentity ? 1 : 0.55)
        }
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
    let highlight: Highlight
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var showingContext = false
    /// Drives the double-tap heart burst. Instagram/TikTok's whole trick is
    /// that the gesture is invisible until you use it and then unmistakably
    /// confirms itself -- a burst that overshoots and fades, never a state the
    /// user has to dismiss.
    @State private var burstScale: CGFloat = 0.2
    @State private var burstOpacity: Double = 0

    /// Double-tap anywhere on the card. Deliberately LIKE-only, never a
    /// toggle: on Instagram a double-tap can only ever like, because the
    /// gesture is imprecise and accidentally un-liking something you meant to
    /// keep is the one outcome that would make people distrust it. Unliking
    /// stays deliberate -- the heart button, or swipe in More > Saved > Liked.
    private func handleDoubleTap() {
        let alreadyLiked = highlight.isLiked
        highlight.isLiked = true
        // Burst even when it was already liked: the gesture should always
        // acknowledge itself, or a double-tap on something you liked
        // yesterday reads as broken.
        burstScale = 0.2
        burstOpacity = 0
        withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) {
            burstScale = 1.0
            burstOpacity = 1
        }
        withAnimation(.easeOut(duration: 0.45).delay(0.28)) {
            burstOpacity = 0
            burstScale = 1.35
        }
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
            kicker: monthsAgo >= 3 ? "From your past self" : "From your library",
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

                Text(highlight.text)
                    .font(quoteFont)
                    .multilineTextAlignment(.leading)
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
            VStack(spacing: 8) {
                // The reference affordance, exactly per Rajan's brief: dive
                // into this highlight's context, then one swipe down and
                // you're back in Flow — never a rabbit hole out of it.
                //
                // Both buttons used to disappear together whenever
                // `highlight.book` was nil -- a real, reachable state for any
                // highlight captured via the Share Extension and left
                // "Unsorted" (never filed to a book), not just a theoretical
                // edge case. `FlowContextSheet` already degrades gracefully
                // with no book (empty chapter/siblings, confirmed by reading
                // its own computed properties), so Go Deeper never actually
                // needed one. Share now falls back to the bare quote text
                // with no deep link when there's no book to point at,
                // instead of vanishing outright.
                HStack(spacing: 10) {
                    Button {
                        showingContext = true
                    } label: {
                        Label("Go deeper", systemImage: "chevron.up")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color(hex: accentHex).opacity(0.15), in: Capsule())
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
                    // An Unsorted highlight (no book) still gets to chat, just
                    // without the book scope, same degradation Share makes.
                    Button {
                        if let book = highlight.book {
                            openURL(CobuxDeepLink.highlightURL(bookID: book.id, highlightID: highlight.id))
                        } else {
                            openURL(URL(string: "cobux://chat")!)
                        }
                    } label: {
                        Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color(hex: accentHex).opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Group {
                        if let book = highlight.book {
                            // Backend-free by design: shares the same
                            // `cobux://book/<id>/highlight/<id>` deep link
                            // the widget's own tap already uses. If the
                            // recipient has Cobux, it opens straight to this
                            // highlight; if not, the quote text alongside
                            // the link still reads fine on its own.
                            // One tap to keep a highlight while scrolling --
                            // the only interaction light enough to actually
                            // happen mid-feed. Collected under More > Liked.
                            ShareLink(
                                item: CobuxDeepLink.highlightURL(bookID: book.id, highlightID: highlight.id),
                                message: Text("\u{201C}\(highlight.text)\u{201D} — \(book.title), via Cobux")
                            ) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }

                            // No Like button here. Reordering it rightmost was a workaround
                            // for a control he never wanted at the bottom: "i dont like the
                            // like to down at bottom in the first place." That statement is
                            // unconditional, where the ordering request was conditional on
                            // the button existing at all. Liking survives as double-tap
                            // (with the heart burst) -- Instagram's gesture without
                            // Instagram's right-hand rail, which he ruled out for a reading
                            // app. Footer is now two quiet capsules under one prominent pill.
                        } else {
                            ShareLink(item: "\u{201C}\(highlight.text)\u{201D} — via Cobux") {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color(hex: accentHex).opacity(0.15), in: Capsule())
                }
            }
        }
        // Double-tap to like, the gesture people already have muscle memory
        // for. Attached here (outside the scaffold) so the whole card is the
        // target, and `count: 2` before any single-tap handler so it can't be
        // swallowed. Paging still works: a vertical drag is never a tap.
        .onTapGesture(count: 2) { handleDoubleTap() }
        .overlay {
            // The burst itself -- non-interactive so it can never eat a tap or
            // block a swipe mid-animation.
            Image(systemName: "heart.fill")
                .font(.system(size: 96))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 12)
                .scaleEffect(burstScale)
                .opacity(burstOpacity)
                .allowsHitTesting(false)
        }
        .sheet(isPresented: $showingContext) {
            FlowContextSheet(highlight: highlight)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
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
    private var chapter: Chapter? {
        if let chapterRef = highlight.chapterRef { return chapterRef }
        guard let chapterTitle = highlight.chapter else { return nil }
        return highlight.book?.chapters.first { $0.title == chapterTitle }
    }

    private var siblings: [Highlight] {
        guard let book = highlight.book, let chapter else { return [] }
        return book.highlights(in: chapter).filter { $0.id != highlight.id }
    }

    var body: some View {
        ScrollView {
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nearby highlights")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(siblings) { sibling in
                            Text("\u{201C}\(sibling.text)\u{201D}")
                                .font(.subheadline)
                                .italic()
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // Deliberately raw .thinMaterial, not .cobuxGlassCard() -- Flow's cards are
                                // architecturally transparent so the shared atmosphere cross-fades between them
                                // (see this file's top doc comment); cobuxGlassCard()'s iOS 17-25 fallback is an
                                // OPAQUE Color.cobuxSurface card, which would break that cross-fade. Flagged in
                                // docs/ui-enhancement-plan.md as "worth tokenizing" -- needs a real design pass
                                // (a translucent glass fallback variant), not a mechanical swap.
                                // swiftlint:disable:next no_inline_glass_or_material
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: CobuxRadius.card))
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
            HStack(spacing: 10) {
                // Chat rather than Go deeper: `FlowContextSheet` is built around
                // a Highlight (its siblings, its chapter position) and a key
                // lesson has none of that. Taking the lesson into the book's own
                // thread is the useful move anyway -- a lesson is exactly the
                // kind of thing worth arguing with.
                Button {
                    if let book = chapter.book {
                        openURL(CobuxDeepLink.bookURL(bookID: book.id))
                    } else {
                        openURL(URL(string: "cobux://chat")!)
                    }
                } label: {
                    Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color(hex: chapter.book?.coverColorHex ?? "#6366F1").opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)

                ShareLink(item: "\(lesson)\n\n— \(chapter.book?.title ?? "Cobux"), \(chapter.title)") {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color(hex: chapter.book?.coverColorHex ?? "#6366F1").opacity(0.15), in: Capsule())
                }
            }
        }
    }
}

/// The self-test card: prompt up front, unblur-to-reveal, then two gentle
/// grade buttons that feed REAL FSRS scheduling (`.again`/`.good` only) and
/// count as showing up for the streak. `FlowQueueBuilder`'s 12-hour guard
/// keeps a card from being re-graded twice in one sitting.
private struct ClozeTeaserFlowCard: View {
    let question: QuizQuestion
    @Environment(\.modelContext) private var modelContext
    @Environment(FlowSessionStats.self) private var stats
    @State private var revealed = false
    @State private var graded = false
    /// True when THIS grade was the day's first activity — the "seal the
    /// day" moment gets celebrated inline instead of passing silently.
    @State private var sealedTheDay = false

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
                        // Deliberately raw .thinMaterial, not .cobuxGlassCard() -- Flow's cards are
                        // architecturally transparent so the shared atmosphere cross-fades between them
                        // (see this file's top doc comment); cobuxGlassCard()'s iOS 17-25 fallback is an
                        // OPAQUE Color.cobuxSurface card, which would break that cross-fade. Flagged in
                        // docs/ui-enhancement-plan.md as "worth tokenizing" -- needs a real design pass
                        // (a translucent glass fallback variant), not a mechanical swap.
                        // swiftlint:disable:next no_inline_glass_or_material
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: CobuxRadius.card))
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
                    withAnimation(.spring(duration: 0.5, bounce: 0.2)) { revealed = true }
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
                    VStack(spacing: 4) {
                        if sealedTheDay {
                            Label("Day \(StreakTracker.currentStreak) sealed", systemImage: "flame.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.cobuxWarning)
                                .symbolEffect(.bounce, value: sealedTheDay)
                        }
                        Label("Scheduled for review", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                if let lastSeenDays, isSlipping, !showsAsGraded {
                    Text("Last seen \(lastSeenDays) day\(lastSeenDays == 1 ? "" : "s") ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .sensoryFeedback(.success, trigger: graded)
        }
    }

    private func gradeButton(title: String, isCorrect: Bool, tint: Color) -> some View {
        Button {
            guard !alreadyGradedThisSitting else { return }
            let wasFirstActivityToday = !StreakTracker.hasShownUpToday
            FSRSService.recordReview(for: question, isCorrect: isCorrect, confidence: nil)
            try? modelContext.save()
            StreakTracker.recordActivityToday()
            StreakCelebrationCenter.shared.checkForPendingMilestone()
            stats.recordGrade(correct: isCorrect)
            // Flow just graded a card the Quick Check widget may be showing.
            WidgetCenter.shared.reloadTimelines(ofKind: "CobuxQuickCheckWidget")
            withAnimation(.snappy) {
                graded = true
                sealedTheDay = wasFirstActivityToday
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
                Text("This topic has tripped you up more than most. A Weak Spots session in the Quiz tab would hit it directly.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } footer: {
            Text("\(lapseCount) missed reviews")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                            .symbolEffect(.pulse)
                    }
                    .font(.title.bold())
                    .foregroundStyle(Color.cobuxWarning)
                    .onAppear {
                        flameScale = 0.4
                        flameGlow = 0
                        withAnimation(.spring(response: 0.55, dampingFraction: 0.5)) {
                            flameScale = 1.0
                        }
                        withAnimation(.easeOut(duration: 0.8)) {
                            flameGlow = 0.85
                        }
                    }
                } else {
                    Text("A fresh start")
                        .font(.title.bold())
                }

                if StreakTracker.hasShownUpToday {
                    Text("Today is already sealed. Everything from here is a bonus.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if dueCount > 0 {
                    Text("\(dueCount) card\(dueCount == 1 ? " is" : "s are") ripe for review — a quick check along the way seals today.")
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
            kicker: "Set \(setNumber) done",
            kickerIcon: "checkmark.seal.fill"
        ) {
            VStack(spacing: 14) {
                statLine("quote.opening", "\(stats.quotesSeen) quotes revisited")
                if stats.lessonsSeen > 0 {
                    statLine("lightbulb.fill", "\(stats.lessonsSeen) lessons refreshed")
                }
                if stats.checksGraded > 0 {
                    statLine("brain.head.profile", "\(stats.checksCorrect)/\(stats.checksGraded) checks right — all scheduled")
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
            }
        }
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
            Text(highlight.book?.title ?? "")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(hex: highlight.book?.coverColorHex ?? "#6366F1"))

            // Compact icon-only pair, not the labeled capsule buttons
            // `HighlightFlowCard`'s footer uses -- this card already carries
            // two full quotes plus a merge glyph, so each quote's own action
            // row stays minimal rather than competing for vertical space.
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
                // Same chat route `HighlightFlowCard`'s footer capsule takes
                // (the widget's own deep link), in this card's compact
                // icon-only voice.
                Button {
                    if let book = highlight.book {
                        openURL(CobuxDeepLink.highlightURL(bookID: book.id, highlightID: highlight.id))
                    } else {
                        openURL(URL(string: "cobux://chat")!)
                    }
                } label: {
                    Image(systemName: "bubble.left.circle")
                }
                if let book = highlight.book {
                    ShareLink(
                        item: CobuxDeepLink.highlightURL(bookID: book.id, highlightID: highlight.id),
                        message: Text("\u{201C}\(highlight.text)\u{201D} — \(book.title), via Cobux")
                    ) {
                        Image(systemName: "square.and.arrow.up.circle")
                    }
                } else {
                    ShareLink(item: "\u{201C}\(highlight.text)\u{201D} — via Cobux") {
                        Image(systemName: "square.and.arrow.up.circle")
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(Color(hex: accentHex))
            .buttonStyle(.plain)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Deliberately raw .thinMaterial, not .cobuxGlassCard() -- Flow's cards are
        // architecturally transparent so the shared atmosphere cross-fades between them
        // (see this file's top doc comment); cobuxGlassCard()'s iOS 17-25 fallback is an
        // OPAQUE Color.cobuxSurface card, which would break that cross-fade. Flagged in
        // docs/ui-enhancement-plan.md as "worth tokenizing" -- needs a real design pass
        // (a translucent glass fallback variant), not a mechanical swap.
        // swiftlint:disable:next no_inline_glass_or_material
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: CobuxRadius.card))
    }
}
