import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import SwiftData
import UIKit

struct MessageBubbleView: View {
    let content: String
    let isUser: Bool
    let timestamp: Date
    let referencedBooks: [String]
    var isError: Bool = false
    var isStreaming: Bool = false
    /// The book this thread is scoped to, per `Book.coverColorHex` -- falls back to the
    /// app-wide accent for the general thread. Threading a book's own living color into
    /// its chat thread was promised in Phase 2 ("the dynamic accent for that book's
    /// detail, chat thread, quiz session, and mastery ring") but only ever reached
    /// Library/BookDetail.
    var accentColor: Color = .cobuxAccent
    /// Set by `ChatView` once `SearchService.relevantFigure` (an independent,
    /// ADDITIVE lookup that runs AFTER a reply has already streamed back and
    /// been finalized) resolves a figure for this reply — nil most of the
    /// time. Default nil so this bubble compiles/renders unchanged at any
    /// call site that doesn't pass it.
    var referencedFigureID: UUID? = nil
    /// True only for the newest assistant message in the thread -- the one
    /// whose candidate replies are still live decisions. Only that message
    /// shows refinement chips; older quote cards get the same actions in
    /// their context menu, so nothing is ever unreachable, just quiet.
    var isNewestAssistantMessage: Bool = false
    /// Images attached to this message, rendered above the text -- the
    /// Claude/ChatGPT idiom.
    var imageIDs: [UUID] = []
    @State private var viewingImageID: UUID?
    /// Sends a refinement as a visible, ordinary user message. Declared as a
    /// labeled property (not a trailing closure) -- the documented binding
    /// trap.
    var onRefine: ((ReplyRefinement, String) -> Void)? = nil
    /// Resends the turn this error bubble is about, with the same words and
    /// photos. Set only on a transient error row (see `ChatView.completeReveal`);
    /// nil everywhere else, so the bubble renders unchanged at every other
    /// call site. Same labeled-property shape as `onRefine`, same reason.
    var onRetry: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    /// For `Color.cobuxOnTint`, which has to resolve an asset-catalogue tint
    /// against the live environment to measure what it actually paints.
    @Environment(\.self) private var environment
    /// Reduce Motion is a hard gate (CobuxMotion.swift): a bubble's entrance
    /// degrades to a plain fade -- no scale from a corner. This is the busiest
    /// animation in the app, one per message in a scrolling thread, and it was
    /// the un-migrated twin of the gate `VoiceTranscriptView` already had.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Which quote card most recently had its copy button tapped, so that one
    /// glyph can show a checkmark for a moment without a per-card state object.
    @State private var copiedQuote: String?
    /// Non-nil while the whole-reply Copy control is showing its checkmark. A
    /// token rather than a Bool so a second tap inside the window cannot have
    /// the FIRST tap's timer clear it early -- the same shape `copiedQuote`
    /// uses, which compares the stored text before clearing.
    @State private var copyFeedbackToken: UUID?
    /// Whether every declared source is showing, or just the first handful.
    @State private var showAllSources = false
    /// The citation label's size, scaled.
    ///
    /// A bare `Font.system(size: 10)` is a FIXED size: it ignores Dynamic Type
    /// entirely, so shrinking the citations to answer "you can also make them
    /// book bubles even tinier" quietly took them out of accessibility sizing
    /// as well. Ten points is already the smallest type in the app; leaving it
    /// unable to grow is the wrong way to be small. `@ScaledMetric` keeps the
    /// tiny default and lets it scale from `.caption2`.
    @ScaledMetric(relativeTo: .caption2) private var citationSize: CGFloat = 10
    @State private var resolvedFigure: Figure?
    @State private var figureImage: UIImage?

    /// How many source chips a reply shows before the rest collapse behind a
    /// "+N more" chip.
    ///
    /// He sent a screenshot of a reply followed by roughly thirty-five of
    /// them: *"look how the book tags mess with an old user prompt also the
    /// book tags here are too big they should be small big look ugly"*. These
    /// are genuine -- they come from the model's own `<sources>` declaration
    /// (`CitationResolver`), never from retrieval and never from "every book
    /// in the library" -- so they cannot be dropped. Four is what fits about
    /// two rows at chip size, which is an attribution; past that it stops
    /// being a citation and becomes the library pasted under a reply. Nothing
    /// is hidden permanently: the "+N more" chip opens the rest in place.
    private static let visibleSourceChipLimit = 4

    private var visibleSourceChips: [String] {
        showAllSources ? referencedBooks : Array(referencedBooks.prefix(Self.visibleSourceChipLimit))
    }

    private var hiddenSourceCount: Int {
        showAllSources ? 0 : max(0, referencedBooks.count - Self.visibleSourceChipLimit)
    }

    private struct ContentBlock: Identifiable {
        let id: Int
        let text: String
        let isQuote: Bool
    }

    /// Splits `content` into plain-text and block-quote (`>`-prefixed) runs so
    /// quotes can render with a Notes-style accent bar instead of a literal
    /// "> " prefix, which `.inlineOnlyPreservingWhitespace` markdown parsing
    /// leaves untouched.
    /// Delegates to `ChatTranscript.blocks` so what is rendered and what is
    /// copied can never diverge -- the copy path was added by extracting this
    /// rule, not by writing a second one.
    private var contentBlocks: [ContentBlock] {
        ChatTranscript.blocks(in: content).enumerated().map {
            ContentBlock(id: $0.offset, text: $0.element.text, isQuote: $0.element.isQuote)
        }
    }

    /// Puts BOTH representations on the pasteboard in one write.
    ///
    /// RTF so Notes and Pages keep the bold and the paragraph structure; plain
    /// text so iMessage and WhatsApp get clean prose with no `**` or `>`
    /// showing. The destination picks the richest form it understands, which is
    /// why "copy the whole response with formatting" and "paste something
    /// sendable to a person" stop being in conflict.
    private func copyWholeMessage() {
        copyToPasteboard(content)
    }

    /// One pasteboard writer for every copy control in this view -- the whole
    /// message and each quote card -- so the two can never drift apart again.
    private func copyToPasteboard(_ markdown: String) {
        let plain = ChatTranscript.plainText(markdown)
        var items: [String: Any] = [UTType.utf8PlainText.identifier: plain]
        // `rtfData`, not a direct serialization of the attributed string --
        // markdown emphasis lives in intent attributes that RTF export ignores,
        // so the direct route produced bold-free RTF. See ChatTranscript.
        if let rtf = ChatTranscript.rtfData(markdown) {
            items[UTType.rtf.identifier] = rtf
        }
        UIPasteboard.general.setItems([items])
    }

    /// The parse itself is memoised by source text (see
    /// `ChatTranscript.InlineMarkdown`); only the colour is applied per call,
    /// which is a single attribute write on a copy-on-write value.
    ///
    /// `memoise: !isStreaming` is the important argument. A finished message's
    /// text is fixed forever, so it is parsed once no matter how many times
    /// `body` runs; the one bubble currently streaming presents a different
    /// string every tick and is deliberately left uncached, so it cannot flood
    /// the cache with prefixes of itself.
    private func inlineAttributed(_ text: String, color: Color) -> AttributedString {
        var attributed = ChatTranscript.InlineMarkdown.parse(text, memoise: !isStreaming)
        // Set color on the AttributedString itself rather than relying solely on
        // a `.foregroundStyle` view modifier — markdown-parsed runs can carry
        // their own color attributes that a modifier won't reliably override.
        attributed.foregroundColor = color
        return attributed
    }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
            HStack {
                if isUser { Spacer(minLength: 64) }

                // 12/6 padding, spacing 4, lineSpacing 1 (was 14/8, 6, 2) — the
                // chat-density fix. Rajan asked for more conversation per screen;
                // density comes from trimming chrome, never from shrinking text,
                // so every font size in this bubble is deliberately unchanged.
                // The user speaks in a bubble; the library answers on the page.
                //
                // Assistant replies had a bubble filled `Color.cobuxSurface`,
                // which the asset catalogue defines as pure WHITE in light mode
                // -- drawn on a pure-white screen. The only thing making them
                // visible at all was a grey hairline, so every reply was a
                // white-on-white outlined slab. And the outline traced
                // `ChatBubbleShape`'s hand-plotted iMessage tail, giving each
                // one a thin grey cartoon tail. That is most of what Rajan
                // meant by "the cobux chat meesgages ui is kinda weird looking".
                //
                // Flow -- the surface he calls "super premium" -- earns that by
                // putting transparent content on a living gradient and spending
                // full saturation exactly once per screen. Chat now borrows the
                // architecture, at reading strength: the reply sits directly on
                // the thread's atmosphere with no box at all, which also gives
                // long answers real reading width and makes the streaming
                // reveal read as writing onto a page rather than a box
                // re-outlining itself on every character.
                VStack(alignment: .leading, spacing: CobuxSpacing.sm) {
                    attachedImagesRow
                    if isError {
                        Label(content, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.cobuxDanger)
                            .font(.subheadline)
                        // A real button, not advice to retype: his message is
                        // already persisted and the composer already cleared
                        // by the time this shows, and every comparable app
                        // offers exactly this. A quiet chip in the thread's
                        // accent, so the notice still reads as a notice.
                        if let onRetry {
                            Button(action: onRetry) {
                                Label("Try again", systemImage: "arrow.clockwise")
                                    .cobuxQuietChip(tint: accentColor)
                                    .foregroundStyle(accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    } else if isStreaming && content.isEmpty {
                        TypingIndicatorView()
                    } else {
                        ForEach(contentBlocks) { block in
                            if block.isQuote {
                                quoteBlockWithRefinements(block.text)
                            } else if !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(inlineAttributed(block.text, color: .primary))
                                    // The library answers in a book's voice.
                                    // Serif is a light-mode-only treatment per
                                    // `CobuxTypography`'s own doctrine, and the
                                    // two faces make speaker obvious with no box.
                                    .font(isUser ? .body
                                          : (colorScheme == .dark ? .body : .system(.body, design: .serif)))
                                    .lineSpacing(isUser ? 2 : 3)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if !referencedBooks.isEmpty && !isUser {
                        FlowLayout(spacing: 6) {
                            ForEach(visibleSourceChips, id: \.self) { title in
                                bookChip(title)
                            }
                            if hiddenSourceCount > 0 {
                                // A pull, not a truncation: every declared
                                // source stays reachable in one tap, in place,
                                // without leaving the thread.
                                Button {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        showAllSources = true
                                    }
                                } label: {
                                    bookChip("+\(hiddenSourceCount) more")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Show \(hiddenSourceCount) more source\(hiddenSourceCount == 1 ? "" : "s")")
                            }
                        }
                        // The same bound Flow's capsule rows already carry, for
                        // the same reason and with the same value: a row of
                        // small tinted capsules that grows without limit stops
                        // being an attribution line. A citation must not be
                        // able to out-weigh the reply it is citing.
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .padding(.top, CobuxSpacing.xs)
                    }

                    // The dedicated Copy control, asked for by name in the
                    // same breath as praising this screen: *"omg the new ui is
                    // soooo goood... ther eshould be decidtacted copy button
                    // mathcing current ui"*. Copy already existed twice --
                    // behind a long-press on the bubble, and as a glyph on
                    // each quote card -- but a long-press is not a button, and
                    // the glyph copies one quote rather than the reply.
                    //
                    // Same rule and reason as both of those: never while
                    // streaming (a half-revealed sentence is not something to
                    // hand a real person), never on an error bubble, never on
                    // his own message (the long-press menu still covers that).
                    if !isUser, !isError, !isStreaming, !content.isEmpty {
                        copyReplyButton
                    }
                }
                // 16/11, not 14/9.
                //
                // His read of the old numbers: *"the prompt purple bubles and
                // the user prompt in them ... is not palced perfectly inside
                // the bublle a little bit werid i noticed"*. At 14/9 the ratio
                // was 1.56:1 -- roomy at the sides, tight top and bottom --
                // and 9pt of headroom put the first line's ascenders inside
                // `CobuxRadius.bubble`'s 18pt arc, which is the same
                // don't-sit-in-the-curve rule that file now states for
                // corner-adjacent controls. 11pt clears the arc; 16 keeps the
                // sides slightly roomier than the ends the way a bubble wants,
                // at 1.45:1 rather than half again as much.
                .padding(.horizontal, isUser ? 16 : 0)
                .padding(.vertical, isUser ? 11 : 0)
                .background {
                    if isUser {
                        // A wash, never full saturation -- Flow's capsule
                        // language. The accent appeared at 100% dozens of times
                        // per thread, which is the opposite of what makes Flow
                        // feel expensive.
                        RoundedRectangle(cornerRadius: CobuxRadius.bubble, style: .continuous)
                            .fill(accentColor.opacity(colorScheme == .dark ? 0.20 : 0.14))
                    } else if isError {
                        RoundedRectangle(cornerRadius: CobuxRadius.bubble, style: .continuous)
                            .fill(Color.cobuxDanger.opacity(0.10))
                            .padding(.horizontal, -12)
                            .padding(.vertical, -8)
                    }
                }
                // Long-press the whole bubble to copy or share it -- his
                // messages as well as Cobux's, because "prompts too" was part
                // of the ask.
                //
                // This used to say "a context menu RATHER THAN a visible button
                // row", on density grounds. He reopened that: *"ther eshould be
                // decidtacted copy button mathcing current ui"*. Both now
                // exist, and neither is redundant -- the menu is the only
                // route to Share, and the only copy affordance his OWN
                // messages have; the visible chip (see `copyReplyButton`) is
                // for the reply, which is the thing anyone actually copies.
                // Long-press stays the house idiom for the rest, the way the
                // journal threshold cards use it.
                //
                // Hidden while streaming, same rule and same reason as the
                // per-quote copy button: never hand him half a sentence to send
                // to a real person.
                .contextMenu {
                    if !isStreaming && !isError && !content.isEmpty {
                        Button {
                            copyWholeMessage()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        // Rich AND plain, like Copy: a `Transferable` that
                        // exports RTF and proxies plain text, so Share into
                        // Notes keeps the bold the way Copy into Notes does,
                        // and Messages still gets clean prose.
                        ShareLink(item: ChatShareText(markdown: content),
                                  preview: SharePreview(ChatShareText.previewTitle(for: content))) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                if !isUser { Spacer(minLength: 0) }
            }

            // Additive, post-reply figure attachment (see `SearchService.relevantFigure`
            // and `ChatView.completeReveal`) — rendered below the bubble itself, never
            // blocking the message text, which is why resolution happens in `.task`
            // rather than synchronously in `body`. Keyed off `figureImage` (whether it
            // actually resolved), not `referencedFigureID` (whether one was assigned) --
            // an id that's still loading, or that never resolves to a real image, would
            // otherwise still insert this HStack as a present sibling, adding stray
            // vertical spacing for nothing.
            if !isUser, figureImage != nil {
                HStack {
                    figureCard
                    Spacer()
                }
            }

// No per-message timestamp. A caption row under every single
            // message is twenty rows of grey noise in a twenty-message thread,
            // and the density rule this file already follows is that density
            // comes from trimming chrome, never from shrinking text. The time
            // now appears once per real pause in the conversation, from
            // `ChatView` -- which is the only moment it tells you anything.
        }
        .transition(entrance)
        .task(id: referencedFigureID) {
            await loadFigure()
        }
    }

    /// Same shape as `VoiceTranscriptView.entrance`, deliberately -- one idiom
    /// for "a row arriving in a transcript", gated the same way.
    private var entrance: AnyTransition {
        if reduceMotion {
            return .opacity.animation(.easeOut(duration: 0.2))
        }
        return .asymmetric(
            insertion: .scale(scale: 0.85, anchor: isUser ? .bottomTrailing : .bottomLeading)
                .combined(with: .opacity)
                .animation(.spring(response: 0.38, dampingFraction: 0.78)),
            removal: .opacity.animation(.easeIn(duration: 0.12))
        )
    }

    /// A single-row-by-`id` fetch, mirroring the exact safe pattern in
    /// `BookCard.loadHighlightCount()` — cheap, not a full table scan — run
    /// from `.task` so it never blocks this bubble's text from rendering.
    @MainActor
    private func loadFigure() async {
        guard let referencedFigureID else {
            resolvedFigure = nil
            figureImage = nil
            return
        }
        let targetFigureID = referencedFigureID
        var descriptor = FetchDescriptor<Figure>(
            predicate: #Predicate<Figure> { $0.id == targetFigureID }
        )
        descriptor.fetchLimit = 1
        guard let figure = try? modelContext.fetch(descriptor).first else { return }
        resolvedFigure = figure
        // `fileName` is read HERE, on the main actor that owns this row, and
        // only the String crosses -- see `FigureImageLoader.image(fileName:)`.
        figureImage = await FigureImageLoader.image(fileName: figure.fileName)
    }

    @ViewBuilder
    private var figureCard: some View {
        if let figureImage {
            VStack(alignment: .leading, spacing: CobuxSpacing.xs) {
                Image(uiImage: figureImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220)
                    .clipShape(RoundedRectangle(cornerRadius: CobuxRadius.card))

                if let resolvedFigure, !resolvedFigure.caption.isEmpty {
                    Text(resolvedFigure.caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(CobuxSpacing.sm)
            .cobuxCard()
        }
    }

    /// A quote is the thing the user came to take away.
    ///
    /// It used to be italic at 75% opacity behind a faint bar -- the visual
    /// language of an aside. That was backwards even for book quotations, and
    /// it is plainly wrong now that a reply to "what do i say back" returns two
    /// or three candidate messages, each on its own `>` line, which the user is
    /// meant to read and send. Those are the payload, not a decorative margin
    /// note. With the assistant's own text bare on the atmosphere, a soft card
    /// here lifts off the page and reads as a thing you can pick up.
    /// A quote card plus, on the newest reply only, the three refinement
    /// chips -- one tap from "almost right" to "sendable".
    @ViewBuilder
    private var attachedImagesRow: some View {
        if !imageIDs.isEmpty {
            HStack(spacing: 6) {
                ForEach(imageIDs, id: \.self) { id in
                    if let image = ChatImageStore.image(for: id) {
                        Button { viewingImageID = id } label: {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(maxWidth: 140, maxHeight: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Attached image, tap to view")
                    }
                }
            }
            .padding(.bottom, 2)
            .sheet(isPresented: .init(get: { viewingImageID != nil },
                                      set: { if !$0 { viewingImageID = nil } })) {
                imageViewer
            }
        }
    }

    @ViewBuilder
    private var imageViewer: some View {
        if let id = viewingImageID, let image = ChatImageStore.image(for: id) {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Button { viewingImageID = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                        .padding(16)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func quoteBlockWithRefinements(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            quoteBlock(text)
            if isNewestAssistantMessage, !isStreaming, let onRefine {
                HStack(spacing: 8) {
                    ForEach(ReplyRefinement.allCases, id: \.rawValue) { refinement in
                        Button {
                            onRefine(refinement, text)
                        } label: {
                            Label(refinement.label, systemImage: refinement.icon)
                                .cobuxQuietChip(tint: accentColor)
                                .foregroundStyle(accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, CobuxSpacing.xs)
            }
        }
    }

    @ViewBuilder
    private func quoteBlock(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule()
                .fill(accentColor.opacity(0.8))
                .frame(width: 3)
            Text(inlineAttributed(text, color: .primary))
                .font(colorScheme == .dark ? .body : .system(.body, design: .serif))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                // Reserves the copy glyph's corner. The glyph lives in an
                // overlay, which takes part in no layout, so without this a
                // long first line would run underneath it -- the exact failure
                // the linter flags here, and the reason the annotation below
                // can honestly say overlap is impossible.
                .padding(.trailing, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CobuxSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: CobuxRadius.quote, style: .continuous)
                .fill(Color.cobuxSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CobuxRadius.quote, style: .continuous)
                .stroke(Color.cobuxLine, lineWidth: 1)
        )
        // The refinement actions, always reachable: on the newest reply they
        // are visible chips below the card; on every older card they live
        // here. The innermost menu wins over the bubble's whole-message menu,
        // so both coexist.
        .contextMenu {
            if !isStreaming, let onRefine {
                ForEach(ReplyRefinement.allCases, id: \.rawValue) { refinement in
                    Button {
                        onRefine(refinement, text)
                    } label: {
                        Label(refinement.label, systemImage: refinement.icon)
                    }
                }
            }
        }
        // The quote text above reserves 28pt of trailing padding for exactly
        // this glyph, so the overlap this rule exists to catch cannot happen.
        // lint-ok: floating-tap-overlay -- space is reserved by that padding
        .overlay(alignment: .topTrailing) {
            // Hidden mid-stream: copying a half-revealed candidate would hand
            // the user an unfinished sentence to send to a real person.
            if !isStreaming {
                Button {
                    // The same rich+plain pair the whole-message copy writes.
                    // This glyph is the MORE used copy control, and it pasted
                    // the raw markdown source -- literal asterisks in iMessage
                    // -- while the card beside it rendered that markdown: the
                    // exact class R-2026-09-chat-copy-pasted-markdown-source
                    // fixed for the long-press menu, left unfixed here.
                    copyToPasteboard(text)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    copiedQuote = text
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        if copiedQuote == text { copiedQuote = nil }
                    }
                } label: {
                    Image(systemName: copiedQuote == text ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(CobuxSpacing.sm)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copiedQuote == text ? "Copied" : "Copy message")
            }
        }
    }

    /// Copies the whole reply, in the same control grammar as the refinement
    /// chips that sit under this message's quote cards -- `cobuxQuietChip`,
    /// the thread's accent, `.buttonStyle(.plain)` -- so it reads as one more
    /// of the actions already there rather than a new idiom.
    ///
    /// The feedback is the app's existing one for a finished action, taken
    /// verbatim from the per-quote copy glyph a few lines below: a light
    /// impact, and the control's own glyph becoming a checkmark for a second
    /// and a half. No toast, nothing new.
    private var copyReplyButton: some View {
        let copied = copyFeedbackToken != nil
        return Button {
            // The one pasteboard writer, so the dedicated button and the
            // long-press menu can never disagree about fidelity: RTF plus
            // plain text, both from `ChatTranscript`.
            copyWholeMessage()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            let token = UUID()
            copyFeedbackToken = token
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if copyFeedbackToken == token { copyFeedbackToken = nil }
            }
        } label: {
            // A FILLED control, not a washed chip. It used to borrow
            // `cobuxQuietChip(tint:)` to match the refinement chips -- which
            // also made it identical to the citation labels sitting directly
            // above it, so the one tappable thing under a reply looked like
            // the twelve untappable ones. Solid accent, white ink, semibold:
            // the same filled-pill grammar the app already uses for its one
            // primary action on a surface, at chip scale.
            Label(copied ? "Copied" : "Copy",
                  systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.semibold))
                // `cobuxOnTint`, not `.white`. `accentColor` here is the
                // BOOK'S OWN COVER COLOUR, and the design system already
                // learned this lesson once -- `cobuxPrimaryPill`'s doc says
                // white unconditionally "on the dark-mode accent measured
                // 3.2:1 and on a pale book cover 2.2:1". Hardcoding white
                // again re-opened it on a control that only exists to be
                // distinguishable. This picks white or the dark ink,
                // whichever actually reads on this particular cover. The
                // modifier itself is not used because it sets a subheadline
                // font and pill padding; this control is deliberately chip
                // scale.
                .foregroundStyle(Color.cobuxOnTint(accentColor, in: environment))
                .padding(.horizontal, CobuxSpacing.md)
                .padding(.vertical, CobuxSpacing.sm)
                .background(accentColor, in: Capsule())
                // Only the FINGER's target grows to Apple's 44pt: the capsule
                // keeps its own size, centred in a taller hit area.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied" : "Copy this reply")
    }

    @ViewBuilder
    private func bookChip(_ title: String) -> some View {
        Text(title)
            // Plain `.caption2`, not `.caption2.weight(.medium)`. The wash and
            // the medium weight together are the app's CONTROL grammar (see
            // `WisdomGraphView`'s count pill, which is the same recipe); a
            // citation is a label, and thirty-five of them in control weight
            // is a field of colour under a reply rather than a footnote to it.
            // Smaller again, and quieter, on his instruction: "the copy button
            // here should be clearlly distinguishable from those book bubbles u
            // can also make them book bubles even tinier". Two things were wrong
            // at once -- a dozen citations at chip size are a field of colour
            // under a reply, and they wore the same tint, the same wash and the
            // same capsule as the Copy button, which is a CONTROL. His own rule
            // from the same evening: a thing that does something and a thing
            // that tells you something must not look alike. So the citation
            // keeps the thread's colour (it says "this came from your library")
            // but loses the weight, the size and most of the wash; the control
            // keeps all three. See `copyReplyButton`.
            .font(.system(size: citationSize))
            .lineLimit(1)
            .foregroundStyle(accentColor.opacity(0.85))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(accentColor.opacity(0.07))
            .clipShape(Capsule())
    }
}

/// What Share hands the system for a message: rich text first, plain second.
///
/// A bare `String` item shared only the rendered plain text, so Share into
/// Notes lost the bold that Copy into Notes kept. Exporting RTF as a
/// `DataRepresentation` and the plain text as a proxy lets each destination
/// take the richest form it understands -- the same two-representation rule
/// `copyToPasteboard` follows, expressed in `Transferable`.
private struct ChatShareText: Transferable {
    let markdown: String

    var plainText: String { ChatTranscript.plainText(markdown) }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .rtf) { item in
            // `rtfData` fails only if RTF serialization itself does, which is
            // not a case worth fabricating bytes for: a thrown error lets the
            // receiver fall through to the plain-text proxy below.
            guard let rtf = ChatTranscript.rtfData(item.markdown) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return rtf
        }
        ProxyRepresentation { item in item.plainText }
    }

    /// The share sheet's title line: the first line of the rendered text, so
    /// the preview shows his words rather than a type name.
    static func previewTitle(for markdown: String) -> String {
        let plain = ChatTranscript.plainText(markdown)
        let firstLine = plain.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? plain
        return firstLine.count > 80 ? String(firstLine.prefix(80)) + "…" : firstLine
    }
}

/// A simple left-to-right, top-to-bottom wrapping layout for chip-style
/// content whose count/width isn't known ahead of time.
///
/// **The two passes must break rows identically.** They did not, and that is
/// the literal half of *"look how the book tags mess with an old user
/// prompt"*: `sizeThatFits` accumulated `width + (rowWidth > 0 ? spacing : 0)`
/// -- no spacing before the first chip -- while `placeSubviews` accumulated
/// `width + spacing` after EVERY chip, first one included. So placement's
/// running x was one `spacing` ahead of measurement's on every row, wrapped
/// sooner, and produced rows the measured height never paid for. A `Layout`
/// that under-reports its height does not clip: the extra rows are simply
/// drawn past the bottom of the frame its parent reserved, straight into the
/// message below. With four chips it is a few points; with the thirty-five he
/// screenshotted it was several rows of overrun, which is exactly why the
/// chips looked tangled with the neighbouring bubble rather than attached to
/// their own reply.
///
/// Both passes now run the identical accumulator, so they cannot disagree.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        // `x` is the same running value `placeSubviews` keeps, measured from
        // the leading edge -- same increment, same wrap test, same result.
        var x: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                totalHeight += rowHeight + spacing
                widestRow = max(widestRow, x - spacing)
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        widestRow = max(widestRow, x - spacing)
        // `x` always carries one trailing `spacing`; the intrinsic width is
        // the widest row without it.
        return CGSize(width: maxWidth.isFinite ? maxWidth : max(0, widestRow), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
