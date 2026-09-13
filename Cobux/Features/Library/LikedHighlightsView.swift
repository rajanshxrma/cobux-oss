import SwiftUI
import SwiftData

/// Everything liked from Flow, in one place.
///
/// Rajan's ask: *"there should be a like option on flow and the likes should
/// saved in a section in more."* Flow is a fast, scrolling feed — the only
/// interaction light enough to survive mid-scroll is a single tap, and without
/// somewhere for those taps to land, liking would be a gesture that quietly
/// went nowhere. This is the somewhere.
///
/// Deliberately distinct from the existing surfaces it might look like:
/// `personalNote` requires stopping to write something, and `isReminder` is a
/// legacy notification flag. Liking claims nothing except "I want to find this
/// again," which is exactly why it's cheap enough to actually use.
///
/// ## Build 57 — why this screen was rebuilt
///
/// His report: *"the liked section. It looks really dull. You know it has no
/// formatting and it just shows the liked everything but still it's a little
/// bit. You know the UI is really simple. Can we make it better?"*
///
/// He was describing something specific, not asking for decoration. The screen
/// was a stock `List` of `Text(highlight.text).font(.body)` with the book's
/// title underneath in grey `.caption`. Three things were wrong with that, and
/// each fix below is one of them:
///
/// 1. **The book was an afterthought.** A line's book is not a footnote on the
///    line, it is what the line MEANS — Aurelius and Greene saying similar
///    words are not saying the same thing (`BookTradition` exists for exactly
///    that reason). So the book became the STRUCTURE: one section per book,
///    its title set in the book's own cover colour, and that colour carried
///    down the leading edge of every line under it. Ebb's own doc comment
///    names this gesture and what it is for — *"a vertical thread ATTRIBUTES
///    — it marks what came from another time or another book"*. Nothing in a
///    row repeats the title any more, because the row is already under it.
/// 2. **The quote was set at list-row size.** These are the lines he chose to
///    keep; they get the library's own face (`CobuxTypography.display`, never
///    `passage` — that one is reserved for his own writing) at a
///    length-adaptive size, the treatment `HighlightFlowCard` uses and he
///    already likes. `@ScaledMetric` so Dynamic Type still moves it.
/// 3. **Order meant nothing.** A flat newest-first list is a log. Sections are
///    ordered by the book whose most recent line is newest and lines inside a
///    book stay newest-first, so the surface reads as a shelf of what he has
///    been keeping lately rather than as a feed.
///
/// **A control and a statement do not look alike here.** The section header is
/// the only control on the face of this screen: it names a book, wears a
/// chevron, and opens it. Every card is a statement — no chevron, no fill, not
/// tappable — with its deliberate actions one hold away, which is Flow's own
/// quiet-menu doctrine and the shelf's own `.contextMenu` accelerator pattern.
///
/// **Nothing here grades him.** No count of liked lines per book, no total, no
/// streak, no "you have kept N things" — a per-book tally on this screen would
/// be a leaderboard of his own reading, which is the same frame the completion
/// ticks were retired for.
///
/// File-scope so it can be used as a property-wrapper argument inside the view
/// that reads it. Immutable and built once.
private let likedHighlightsDescriptor: FetchDescriptor<Highlight> = {
    var descriptor = FetchDescriptor<Highlight>(
        predicate: #Predicate<Highlight> { $0.isLiked == true },
        sortBy: [SortDescriptor(\.dateAdded, order: .reverse)]
    )
    // `book` was already here; `chapterRef` joins it because the row's locator
    // line falls back to it when the free-text `chapter` is missing. Both are
    // to-one relationships read while scrolling, and an unprefetched one is a
    // separate round trip per row the first time that row appears.
    descriptor.relationshipKeyPathsForPrefetching = [\.book, \.chapterRef]
    // Text and metadata only. Each row also carries a 2 KB `embeddingData`
    // vector that this screen never reads -- it shows the line, its locator
    // and its book -- so the column is left out of the fetch. A later reader
    // of the vector on one of these rows gets it faulted in lazily by
    // SwiftData; `isLiked` is here because unliking writes it.
    descriptor.propertiesToFetch = [\.id, \.text, \.chapter, \.page, \.isLiked, \.dateAdded]
    return descriptor
}()

/// One book's liked lines. Built once per change, never in `body`.
///
/// The accent is resolved HERE rather than per row: `Color(hex:)` parses a
/// string, and a shelf of a hundred lines from one book would otherwise parse
/// the same six characters a hundred times on every render pass.
private struct LikedShelf: Identifiable {
    let id: String
    let book: Book?
    let accent: Color
    let highlights: [Highlight]
}

struct LikedHighlightsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    // Sorted newest-first by when the highlight was saved. `isLiked` has no
    // timestamp of its own on purpose — one Bool is the whole feature, and a
    // separate `likedAt` would be a schema change earning very little.
    //
    // Spelled as a `FetchDescriptor` rather than `@Query(filter:sort:order:)`
    // for one reason: `relationshipKeyPathsForPrefetching`. The rows below read
    // `highlight.book` and `highlight.chapterRef`, and without the prefetch
    // that is a separate to-one relationship fault per liked highlight the
    // first time it scrolls into view. Prefetching resolves them with the
    // highlights themselves, in one trip, instead of one query per row.
    // Predicate, sort and order are unchanged.
    @Query(likedHighlightsDescriptor)
    private var liked: [Highlight]

    /// The grouped shelves, held rather than recomputed.
    ///
    /// `liked` can hold thousands of rows, so the one pass that buckets them by
    /// book runs when the set actually CHANGES — not on every body evaluation,
    /// and never per row. `visibleShelves` covers the single frame before the
    /// `.task` lands so the list is never briefly empty.
    ///
    /// Optional, not an empty array, and the distinction is load-bearing: `nil`
    /// means "not grouped yet" and `[]` means "grouped, and there is nothing
    /// left". Unliking the LAST line writes `[]` a beat before `@Query`
    /// republishes, and an empty-array sentinel would have read that as "not
    /// grouped yet" and put the row he just unliked straight back on screen for
    /// a frame.
    @State private var shelves: [LikedShelf]?

    // Length-adaptive quote type. `CobuxTypography.display` takes a raw point
    // size (it is built for the fixed-size wordmark), so each base size is
    // wrapped in `@ScaledMetric` — the same fix `HighlightFlowCard` documents:
    // a quote is exactly the user-variable content that must NOT ignore the
    // reader's text-size setting. Smaller than Flow's 34/28/22 on purpose:
    // Flow gives one quote a whole screen, this gives many of them a shelf.
    @ScaledMetric(relativeTo: .title3) private var shortQuoteSize: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var mediumQuoteSize: CGFloat = 17
    @ScaledMetric(relativeTo: .subheadline) private var longQuoteSize: CGFloat = 15

    /// The grouping the list actually renders. Falls back to computing it
    /// inline on the first pass, when `.task` has not run yet — one O(n) walk
    /// of an array that is already in memory, in exchange for never showing an
    /// empty list under a non-empty query.
    private var visibleShelves: [LikedShelf] {
        shelves.flatMap { $0.isEmpty ? nil : $0 } ?? Self.group(liked)
    }

    var body: some View {
        Group {
            if liked.isEmpty {
                // Names the real gesture. This said "Tap Like on any highlight
                // in Flow", and there is no Like control on a Flow card to tap
                // -- it was removed on his own instruction and liking became
                // the double-tap. So the one screen that explains liking was
                // sending people to look for a button that isn't there.
                CobuxEmptyStateView(
                    icon: "heart",
                    title: "Nothing liked yet",
                    message: "Double-tap any card in Flow to like it — or hold the card and choose Like. Everything you like collects here."
                )
            } else {
                shelfList
            }
        }
        .navigationTitle("Liked")
        .navigationBarTitleDisplayMode(.inline)
        // Keyed on the count so a like or an unlike made anywhere else regroups
        // this screen, and re-run on every appearance because `.task` restarts
        // when a view reappears. The only mutation this screen makes itself
        // (unlike) updates `shelves` directly, so the list animates instead of
        // waiting for the query to catch up.
        .task(id: liked.count) { shelves = Self.group(liked) }
    }

    private var shelfList: some View {
        List {
            ForEach(visibleShelves) { shelf in
                Section {
                    ForEach(shelf.highlights) { highlight in
                        quoteCard(highlight, accent: shelf.accent)
                            .listRowInsets(Self.rowInsets)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            // Swipe to unlike rather than a destructive delete —
                            // this list is a view onto highlights that still
                            // exist in the library; removing one here must never
                            // delete the highlight itself.
                            .swipeActions(edge: .trailing) {
                                Button("Unlike") { unlike(highlight) }
                                    .tint(Color.cobuxMuted)
                            }
                            // The quiet menu. Every deliberate action is one
                            // hold away and NONE of them is drawn on the card,
                            // so nothing on a card face can be mistaken for a
                            // control (Flow's own rule, and the reason its
                            // footer lost its Like button).
                            .contextMenu { rowMenu(for: highlight, in: shelf) }
                    }
                } header: {
                    // Zero row insets and a full-bleed ground of its own: the
                    // plain list style pins a section header while its lines
                    // scroll under it, and an inset header would let cards slide
                    // through the strip either side of it.
                    shelfHeader(shelf)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .listSectionSeparator(.hidden)
        .scrollContentBackground(.hidden)
        .background(Color.cobuxBackground)
        // The end of the list clears the floating tab bar and the Flow button
        // by the scroll view's own reservation rather than by a constant baked
        // into the last row — the same correction the shelf footer needed in
        // `LibraryView`.
        .contentMargins(.bottom, CobuxSpacing.xxl, for: .scrollContent)
    }

    // MARK: - The shelf header (the one control on this screen)

    @ViewBuilder
    private func shelfHeader(_ shelf: LikedShelf) -> some View {
        Group {
            if let book = shelf.book {
                NavigationLink(destination: BookDetailView(book: book)) {
                    headerLabel(title: book.title,
                                author: book.author,
                                accent: shelf.accent,
                                opensBook: true)
                }
                .buttonStyle(.plain)
            } else {
                // A liked line whose book was deleted, or one captured through
                // the Share Extension and never filed. It still belongs on this
                // screen -- it is something he kept -- but there is nothing to
                // open, so this header is a statement and wears no chevron.
                headerLabel(title: "Not filed to a book",
                            author: nil,
                            accent: shelf.accent,
                            opensBook: false)
            }
        }
        // Section headers are uppercased by the plain list style; a book's
        // title is a proper noun, not a label.
        .textCase(nil)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cobuxBackground)
    }

    private func headerLabel(title: String, author: String?, accent: Color, opensBook: Bool) -> some View {
        HStack(spacing: CobuxSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                BookTitleText(title: title,
                              font: .subheadline,
                              weight: .semibold,
                              color: accent,
                              lineLimit: 1)
                if let author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(Color.cobuxMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: CobuxSpacing.sm)
            if opensBook {
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CobuxSpacing.screenMargin)
        .padding(.top, CobuxSpacing.lg)
        .padding(.bottom, CobuxSpacing.sm)
        .contentShape(Rectangle())
    }

    // MARK: - One kept line

    private func quoteCard(_ highlight: Highlight, accent: Color) -> some View {
        HStack(alignment: .top, spacing: CobuxSpacing.md) {
            // The attribution thread: the book's own colour, running the full
            // height of the line it came from. It is why no row has to repeat
            // the title -- the colour is the attribution, and it holds even
            // when the header has scrolled off.
            Capsule(style: .continuous)
                .fill(accent)
                .frame(width: 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: CobuxSpacing.sm) {
                Text(highlight.text)
                    .font(quoteFont(for: highlight.text))
                    .foregroundStyle(Color.cobuxInk)
                    // A reference-book highlight can run to thousands of
                    // characters. Twelve lines is past every ordinary quote and
                    // still stops one row from owning the whole screen; the
                    // full text is a hold away, in the book.
                    .lineLimit(12)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if let locator = locator(for: highlight) {
                    Text(locator)
                        .font(.caption)
                        .foregroundStyle(Color.cobuxMuted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CobuxSpacing.cardPadding)
        .cobuxCard()
        // One element, so VoiceOver reads the line and where it is from as one
        // thing rather than swiping through a decorative rule to reach it.
        .accessibilityElement(children: .combine)
    }

    /// A short line lands with weight, a long passage sets like a page. Same
    /// idea as `HighlightFlowCard.quoteFont`, at shelf scale.
    private func quoteFont(for text: String) -> Font {
        switch text.count {
        case ..<90: CobuxTypography.display(colorScheme, size: shortQuoteSize, weight: .semibold)
        case ..<220: CobuxTypography.display(colorScheme, size: mediumQuoteSize, weight: .medium)
        default: CobuxTypography.display(colorScheme, size: longQuoteSize, weight: .regular)
        }
    }

    /// Where in the book the line is, when the book says. The free-text
    /// `chapter` is read FIRST and `chapterRef` only as a fallback -- the
    /// reverse of Flow's order, and deliberately: `chapter` is a stored String
    /// on the row itself, so the common case costs no relationship read at all
    /// on a surface that is scrolling.
    private func locator(for highlight: Highlight) -> String? {
        var parts: [String] = []
        if let chapter = highlight.chapter ?? highlight.chapterRef?.title,
           !chapter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(chapter)
        }
        if let page = highlight.page {
            parts.append("p. \(page)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func rowMenu(for highlight: Highlight, in shelf: LikedShelf) -> some View {
        if let book = shelf.book {
            Button {
                openURL(CobuxDeepLink.highlightURL(bookID: book.id, highlightID: highlight.id))
            } label: {
                Label("Chat about this line", systemImage: "bubble.left.and.text.bubble.right")
            }
            // Same payload and same wording Flow shares, so a line shared from
            // here and the same line shared from Flow arrive identically.
            ShareLink(
                item: CobuxDeepLink.highlightURL(bookID: book.id, highlightID: highlight.id),
                message: Text("\u{201C}\(highlight.text)\u{201D} — \(book.title), via Cobux")
            ) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        } else {
            ShareLink(item: "\u{201C}\(highlight.text)\u{201D} — via Cobux") {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        Button {
            unlike(highlight)
        } label: {
            Label("Unlike", systemImage: "heart.slash")
        }
    }

    // MARK: - Mutation

    /// Unliking only. The highlight itself is untouched and stays in its book.
    ///
    /// `shelves` is rebuilt from `liked` minus this row rather than waiting for
    /// the query to publish: the removal animates, and an empty shelf takes its
    /// header with it in the same pass. The `.task` above then re-runs on the
    /// query's own change and produces the identical grouping.
    private func unlike(_ highlight: Highlight) {
        highlight.isLiked = false
        let remaining = liked.filter { $0.id != highlight.id }
        withAnimation(CobuxMotion.snap) {
            shelves = Self.group(remaining)
        }
    }

    // MARK: - Grouping

    private static let unfiledKey = "cobux.liked.unfiled"

    private static let rowInsets = EdgeInsets(top: CobuxSpacing.xs,
                                              leading: CobuxSpacing.screenMargin,
                                              bottom: CobuxSpacing.xs,
                                              trailing: CobuxSpacing.screenMargin)

    /// One pass, order-preserving. `highlights` arrives newest-first, so a
    /// book's first appearance fixes its position — the shelf whose most recent
    /// line is newest sits at the top, and lines inside a shelf stay
    /// newest-first. No sort, no second pass, and the only relationship read is
    /// `book`, which the descriptor prefetched.
    private static func group(_ highlights: [Highlight]) -> [LikedShelf] {
        var order: [String] = []
        var buckets: [String: [Highlight]] = [:]
        var booksByKey: [String: Book] = [:]

        for highlight in highlights {
            let book = highlight.book
            let key = book.map { $0.id.uuidString } ?? unfiledKey
            if buckets[key] == nil {
                order.append(key)
                if let book { booksByKey[key] = book }
            }
            buckets[key, default: []].append(highlight)
        }

        return order.map { key in
            let book = booksByKey[key]
            return LikedShelf(
                id: key,
                book: book,
                accent: book.map { Color(hex: $0.coverColorHex) } ?? Color.cobuxAccent,
                highlights: buckets[key] ?? []
            )
        }
    }
}
