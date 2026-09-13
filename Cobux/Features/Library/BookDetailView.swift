import SwiftUI
import SwiftData
import WidgetKit
import UIKit

struct BookDetailView: View {
    @Bindable var book: Book
    /// Set only when reached from a source that registered a matching
    /// `.matchedTransitionSource` (currently: Library's book grid) -- see
    /// `View+ZoomTransition.swift`. Left nil elsewhere so this view still
    /// works unchanged from search results and Wisdom's theme highlights.
    var heroTransitionNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTab = "Highlights"
    @State private var showingAddHighlight = false
    @State private var showingAddChapter = false
    @State private var showingClosingInterview = false
    @State private var chapterToggleFeedback = false
    /// The remote-fetch-cache tier (a book added by hand). Unchanged.
    @State private var coverImage: UIImage?
    /// The bundled cover at FULL resolution, decoded off the main thread in
    /// `.task` -- see `heroBackground`.
    @State private var heroImage: UIImage?
    /// The two stats-card numbers, and the two lists, computed ONCE per visit
    /// rather than once per body evaluation.
    ///
    /// `book.highlights` and `book.chapters` are to-many relationships: reading
    /// either is a SQL round trip that materialises every row it returns. This
    /// screen read them SIX times per body -- two counts, `chapterProgress`,
    /// `completedChapterCount`, an `isEmpty`, and a full `sorted()` handed to a
    /// `ForEach` -- and `body` re-runs on the segmented picker, on every sheet
    /// flag, and on the cover image landing. On a reference text that is
    /// several thousand `Highlight` rows, each carrying its full text and a
    /// 512-float embedding, faulted and sorted between the tap on a book and
    /// its first frame, and again on every tap inside it.
    ///
    /// `nil` means "not read yet", so a number is never shown before it is
    /// known -- the same rule `DiagnosticsView` follows.
    @State private var highlightCount: Int?
    @State private var chapterCount: Int?
    @State private var sortedHighlights: [Highlight] = []
    @State private var sortedChapters: [Chapter] = []
    @State private var contentsLoaded = false
    /// Bumped by anything that changes what the two lists hold, so `.task(id:)`
    /// re-reads them. A delete is the only such thing from inside this screen.
    @State private var contentsRevision = 0

    /// How far the stats card rides up over the hero's bottom edge.
    ///
    /// Read this together with the hero's bottom padding below -- the two are
    /// the same number on purpose, and separating them is what broke. The card
    /// is drawn ON TOP (`zIndex(1)`), so this is an OCCLUSION, not a gap:
    /// whatever it covers is gone. It used to be a bare `-24` against a hero
    /// whose text block had the default 16pt bottom padding, so the card ate
    /// 24 - 16 = 8pt of the author's line, on every book, one-line title or
    /// not. Rajan: *"u see how the autor name is hidden partly behind looks
    /// unprifesional."* The hero now reserves this exact amount as extra
    /// bottom padding, so the card can only ever overlap empty hero.
    private static let statsCardOverlap: CGFloat = 24

    /// A FLOOR for the hero, not its height.
    ///
    /// It was a fixed 232/260 chosen to fit a 2-line title at default text
    /// size -- the same hand-computed-clearance shape `docs/flow-bottom-layout`
    /// Invariant 2 exists to forbid, and it had the matching failure mode: at
    /// an accessibility text size the title and author simply grew past it.
    /// The hero is now sized BY its own text plus that text's clearance, with
    /// this as a minimum, so the arithmetic cannot go wrong in either
    /// direction: too short is impossible, and the overlap is reserved space.
    private var heroMinHeight: CGFloat {
        book.dateFinished != nil ? 260 : 232
    }

    var body: some View {
        Group {
            if SeedingStatus.shared.isSeeding {
                // Same seed-merge guard as `BookCard`/`QuizHomeView` -- this
                // screen's stats row, chapterProgress, highlightsList, and
                // chaptersList all fault this book's `highlights`/`chapters`
                // relationships synchronously in `body`. Landing that fault
                // mid seed/upgrade merge is the confirmed Build-5 crash
                // class (see `BookCard`'s doc comment). `LibraryView` never
                // shows a book row you can tap until it renders (and
                // `BookCard` itself defers its own relationship read to
                // `.task`), but the seed/upgrade merge can still be running
                // for an *existing* user re-opening an already-populated
                // library after a content update, so this guard matters even
                // when it isn't the very first launch.
                ProgressView("Syncing your library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                detailContent
            }
        }
    }

    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Hero Header.
                //
                // The text block drives the height and the cover fills behind
                // it, rather than the text being bottom-pinned inside a fixed
                // frame that a hand-picked negative offset then overlapped.
                // `lineLimit: 2` + `minimumScaleFactor` still bound the title
                // (the longest shipped title, "The Cynic's Breviary: Maxims
                // and Anecdotes from Nicolas de Chamfort" at 67 characters,
                // sets to two lines and shrinks rather than wrapping to
                // three), and the scrim still reaches high enough to hold a
                // two-line title against any cover -- both unchanged. What
                // changed is that the hero can now GROW when the type does,
                // and that the clearance the stats card needs is part of the
                // text block's own height instead of a second number that had
                // to be kept larger than the first by hand.
                VStack(alignment: .leading, spacing: 8) {
                    if let dateFinished = book.dateFinished {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                            Text("Finished \(dateFinished.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2)
                        }
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.18))
                        .clipShape(Capsule())
                    }
                    BookTitleText(
                        title: book.title,
                        font: .largeTitle,
                        weight: .bold,
                        color: .white,
                        lineLimit: 2,
                        expandsWidth: true
                    )
                    .minimumScaleFactor(0.7)
                    Text(book.author)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.9))
                }
                .padding()
                // The author's clearance, reserved rather than hoped for. This
                // is the SAME constant the stats card is offset by, so the
                // card lands exactly on the hero's bottom edge and the author
                // keeps the full 16pt the `.padding()` above gives it, at
                // every title length and every Dynamic Type size.
                .padding(.bottom, Self.statsCardOverlap)
                .frame(maxWidth: .infinity, minHeight: heroMinHeight, alignment: .bottomLeading)
                .background(alignment: .bottom) {
                    // Both layers sized by the frame above, so the cover bleed
                    // and the scrim follow the hero wherever its text takes it
                    // -- neither carries a height of its own any more.
                    ZStack {
                        // `Color.clear.overlay { }` is load-bearing, not a
                        // wrapper for its own sake. `heroBackground` fills with
                        // `.aspectRatio(contentMode: .fill)`, and a filling
                        // image REPORTS its overflowing size -- so placed
                        // directly in this ZStack it sized the stack to the
                        // image (roughly 393x655 for a portrait cover behind a
                        // 232pt hero), centred the gradient inside THAT, and
                        // then bottom-aligned the whole thing: the dark end of
                        // the scrim floated in the middle of the hero and the
                        // text band came out ~62% brighter than build 52, on
                        // every one of the 156 bundled covers. Clamping the
                        // image inside a zero-size `Color.clear` makes the
                        // stack take the frame's size instead, which is what
                        // the comment above always claimed was happening.
                        // Verified by rendering both versions and sampling
                        // luminance down the hero: this reproduces build 52's
                        // profile at every sample point.
                        Color.clear
                            .overlay { heroBackground }
                            .clipped()
                        LinearGradient(
                            colors: [.black.opacity(0.85), .black.opacity(0.35), .clear],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    }
                }
                .clipped()

                // Stats card — floats slightly over the hero's bottom edge
                // instead of sitting as a flat, disconnected block directly
                // beneath it.
                VStack(spacing: 10) {
                    HStack(spacing: 24) {
                        // An en dash until the count is read, not a "0": a zero
                        // is a claim about his book, and this screen must never
                        // make one on the strength of not having looked yet.
                        StatView(value: highlightCount.map(String.init) ?? "–", label: "Highlights")
                        StatView(value: chapterCount.map(String.init) ?? "–", label: "Chapters")
                        StatView(value: book.dateAdded.formatted(date: .abbreviated, time: .omitted), label: "Added")
                    }

                    // Derived from the already-read chapter list, so the
                    // progress bar costs no further relationship faults. It was
                    // `book.chapterProgress` plus `book.completedChapterCount`
                    // plus `book.chapters.count` -- three more reads of the
                    // same relationship, in the same body.
                    if contentsLoaded, !sortedChapters.isEmpty {
                        let completed = sortedChapters.filter(\.isCompleted).count
                        VStack(spacing: 4) {
                            ProgressView(value: Double(completed) / Double(sortedChapters.count))
                                .tint(Color(hex: book.coverColorHex))
                            Text("\(completed)/\(sortedChapters.count) chapters read")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .cobuxCard()
                .padding(.horizontal)
                // The one place this number is spent. The hero reserves the
                // same amount above, so this rides over empty hero and never
                // over the author's line.
                .padding(.top, -Self.statsCardOverlap)
                .zIndex(1)

                // Segmented Picker
                Picker("View", selection: $selectedTab) {
                    Text("Highlights").tag("Highlights")
                    Text("Chapters").tag("Chapters")
                }
                .pickerStyle(.segmented)
                .padding()

                // Content
                if selectedTab == "Highlights" {
                    highlightsList
                } else {
                    chaptersList
                }
            }
        }
        .background(Color.cobuxBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: { showingAddHighlight = true }) {
                        Label("Add Highlight", systemImage: "quote.opening")
                    }
                    Button(action: { showingAddChapter = true }) {
                        Label("Add Chapter", systemImage: "text.book.closed")
                    }
                    if book.dateFinished == nil {
                        Button(action: {
                            book.dateFinished = .now
                            showingClosingInterview = true
                        }) {
                            Label("Mark as Finished", systemImage: "checkmark.seal")
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.white)
                }
            }
        }
        .sheet(isPresented: $showingAddHighlight) {
            AddHighlightView(book: book)
        }
        .sheet(isPresented: $showingAddChapter) {
            AddChapterView(book: book)
        }
        .sheet(isPresented: $showingClosingInterview) {
            ClosingInterviewView(book: book)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .ignoresSafeArea(edges: .top)
        .sensoryFeedback(.selection, trigger: chapterToggleFeedback)
        .cobuxZoomTransitionDestination(id: book.id, in: heroTransitionNamespace)
        .task(id: book.id) {
            await loadCoverImage()
        }
        // The relationship reads, after the first frame. Two yields, exactly as
        // `SettingsView`'s counts do it, so the push animation commits before a
        // reference text's several thousand rows are faulted; the stats card
        // and the lists fill in behind it.
        .task(id: contentsKey) {
            await Task.yield()
            await Task.yield()
            loadContents()
        }
    }

    /// Re-reads when the book changes, when this screen deletes something, and
    /// when a seed/upgrade merge finishes -- never during one, which is the
    /// Build-5 crash class this screen's outer guard exists for.
    private var contentsKey: String {
        "\(book.id)|\(contentsRevision)|\(SeedingStatus.shared.isSeeding)"
    }

    /// One read of each relationship, sorted into the order the lists draw in.
    ///
    /// `@MainActor` explicitly, the way `DiagnosticsView.load` is: `book` is a
    /// `@Model` object and a bare `async` method makes no promise about which
    /// actor it resumes on (SE-0338). Nothing here leaves the main actor --
    /// this is about doing the work ONCE and after the first frame, never about
    /// moving a model object across an actor boundary.
    @MainActor
    private func loadContents() {
        guard !SeedingStatus.shared.isSeeding else { return }
        let highlights = book.highlights
        let chapters = book.chapters
        highlightCount = highlights.count
        chapterCount = chapters.count
        sortedHighlights = highlights.sorted { $0.dateAdded > $1.dateAdded }
        sortedChapters = chapters.sorted { ($0.chapterNumber ?? 0) < ($1.chapterNumber ?? 0) }
        contentsLoaded = true
    }

    // Same resolution order as `BookCard.coverBackground`: bundled asset ->
    // on-device remote-fetch cache -> gradient. See its doc comment.
    //
    // `"Cover-" + assetName`, not the bare `assetName` -- the imageset's real
    // name is `Cover-<slug>` (`Book.coverAssetName`'s own doc comment), and
    // the bare slug returned nil from `UIImage(named:)` for all 26 seed books
    // until this was caught.
    //
    // `UIImage(named:)` used to be called RIGHT HERE, in `body`, defended by a
    // comment that said the pixels were "decoded lazily by the render server,
    // not here". They are decoded on the main thread, at first draw, at full
    // source resolution -- these covers run to 1400x2100, 11.2 MB of bitmap
    // (`BookCoverThumbnails`' own measurement), and UIKit's image cache purges
    // them constantly under a 156-cover grid, so the "cached dictionary hit"
    // was routinely a full JPEG decode between the tap on a book and its
    // first frame, on every body pass that followed. `body` now only reads
    // state; the decode happens in `.task`, off the main thread, and the
    // hero KEEPS full resolution -- it is one cover at hero size, which is
    // exactly the case `BookCard` documents as deliberately not downsampled.
    //
    // Frame one shows the same thing the grid he tapped was showing: the
    // grid's warm display-size thumbnail when there is one (a dictionary
    // read, `BookCoverThumbnails.cached`), else the cover gradient -- so the
    // zoom transition lands on the art it left, and the full-resolution
    // bitmap replaces it a beat later with no layout change.
    @ViewBuilder
    private var heroBackground: some View {
        if let heroImage {
            Image(uiImage: heroImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let assetName = book.coverAssetName,
                  let warm = BookCoverThumbnails.cached(assetName: assetName) {
            Image(uiImage: warm)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let coverImage {
            Image(uiImage: coverImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            CoverGradientView(colorHex: book.coverColorHex)
        }
    }

    // On-device cache, not `AsyncImage` -- see `CoverImageCache`'s doc comment
    // and `BookCard`'s matching conversion (2.2.0 offline resilience).
    //
    // Skipped only when the bundled asset genuinely resolves, not merely when
    // `coverAssetName` is set -- see `BookCard.loadCoverImage`'s matching fix
    // and doc comment for why that distinction matters: a `coverAssetName`
    // that fails to resolve must fall through here instead of dead-ending.
    @MainActor
    private func loadCoverImage() async {
        if let assetName = book.coverAssetName {
            // Off the main thread: the asset-catalog lookup AND the decode.
            // `byPreparingForDisplay()` forces the full-resolution bitmap to
            // exist now, on this detached task, so the render server is
            // handed pixels rather than a JPEG to decode under his thumb.
            // Same shape as `BookCard.loadCoverImage`, minus its downsample.
            // `UIImage(named:)` is thread-safe; `BookCoverThumbnails.thumbnail`
            // already calls it off-main.
            let full = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let image = UIImage(named: "Cover-" + assetName) else { return nil }
                return await image.byPreparingForDisplay() ?? image
            }.value
            if let full {
                heroImage = full
                return
            }
            // Falls through deliberately when the imageset does not actually
            // resolve -- see `BookCard.loadCoverImage` for why a set-but-
            // unresolvable `coverAssetName` must reach the remote path.
        }
        if let cached = CoverImageCache.cachedImage(for: book.id) {
            coverImage = cached
            return
        }
        guard let urlString = book.coverImageURL, let url = URL(string: urlString) else { return }
        coverImage = await CoverImageCache.downloadAndCache(bookID: book.id, remoteURL: url)
    }

    @ViewBuilder
    private var highlightsList: some View {
        LazyVStack(spacing: 16) {
            if !contentsLoaded {
                // Not "nothing saved from this book" -- "not read yet". An
                // empty state is a claim about his data and must never be
                // guessed, which is the same rule `FlowView.hasBuiltFirstBatch`
                // exists to enforce.
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else if sortedHighlights.isEmpty {
                // Was a bare "No highlights yet." -- the name of a state, and
                // nothing about what a highlight is or where the one action
                // that fixes it lives (buried in the toolbar's `+` menu).
                // Same shape as every other empty state in the app now.
                CobuxEmptyStateView(
                    icon: "quote.opening",
                    title: "Nothing saved from this book yet",
                    message: "A highlight is a line worth keeping. Save one and it comes back to you in Flow, in the Wisdom Graph, and in anything you ask about this book."
                ) {
                    CobuxEmptyStateButton("Add Highlight", systemImage: "quote.opening") {
                        showingAddHighlight = true
                    }
                }
            } else {
                ForEach(sortedHighlights) { highlight in
                    HStack(alignment: .top, spacing: 0) {
                        // A colored accent bar ties each card back to its
                        // book, and replaces the old literal quote marks
                        // (which doubled up whenever a pasted excerpt
                        // already carried its own quotation marks).
                        Rectangle()
                            .fill(Color(hex: book.coverColorHex))
                            .frame(width: 3)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(quotedText(for: highlight.text))
                                .font(.body)
                                // Italic reads fine for a short aphorism but
                                // hurts readability on long, dense clinical
                                // paragraphs — only apply it below a length
                                // where it still helps rather than hinders.
                                .italic(highlight.text.count < 150)

                            if let note = highlight.personalNote, !note.isEmpty {
                                Text("Note: \(note)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 12) {
                                if let chapter = highlight.chapter, !chapter.isEmpty {
                                    Label(chapter, systemImage: "text.book.closed")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                if let page = highlight.page {
                                    Label("p. \(page)", systemImage: "number")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }

                            if !highlight.tags.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack {
                                        ForEach(highlight.tags, id: \.self) { tag in
                                            TagBadge(tag: tag)
                                        }
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                    .cobuxCard()
                    .padding(.horizontal)
                    .contextMenu {
                        Button(role: .destructive) {
                            deleteHighlight(highlight)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .padding(.bottom)
    }

    @ViewBuilder
    private var chaptersList: some View {
        LazyVStack(spacing: 16) {
            if !contentsLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else if sortedChapters.isEmpty {
                // Same fix as the highlights tab: say what a chapter is FOR
                // (it is what Chapter Cram quizzes against), and put the
                // existing Add Chapter action where the reader already is.
                CobuxEmptyStateView(
                    icon: "text.book.closed",
                    title: "No chapters yet",
                    message: "Chapters break a book into parts you can revisit one at a time — a summary and its key lessons, in your own words."
                ) {
                    CobuxEmptyStateButton("Add Chapter", systemImage: "text.book.closed") {
                        showingAddChapter = true
                    }
                }
            } else {
                ForEach(sortedChapters) { chapter in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(chapter.summary)
                                .font(.body)
                                .foregroundStyle(.secondary)

                            if !chapter.keyLessons.isEmpty {
                                Text("Key Lessons:")
                                    .font(.headline)
                                    .padding(.top, 8)
                                ForEach(chapter.keyLessons, id: \.self) { lesson in
                                    HStack(alignment: .top) {
                                        Text("•")
                                        Text(lesson)
                                    }
                                    .font(.subheadline)
                                }
                            }
                        }
                        // The outer card already carries `.padding()` below —
                        // this used to ALSO pad the top, doubling the gap
                        // between the label row and the expanded content.
                        .padding(.top, 4)
                    } label: {
                        HStack {
                            // This is a DisclosureGroup label (not a Button
                            // label) in a LazyVStack, where a .plain inner
                            // Button keeps its own tap; verified working on
                            // device. Inside a List or a real Button label
                            // this WOULD be dead.
                            // lint-ok: nested-tap -- DisclosureGroup label, works
                            Button {
                                chapter.isCompleted.toggle()
                                chapterToggleFeedback.toggle()
                            } label: {
                                Image(systemName: chapter.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(chapter.isCompleted ? Color(hex: book.coverColorHex) : .secondary)
                            }
                            .buttonStyle(.plain)

                            Text(chapter.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .strikethrough(chapter.isCompleted, color: .secondary)
                        }
                    }
                    .padding()
                    .cobuxCard()
                    .padding(.horizontal)
                    .contextMenu {
                        Button(role: .destructive) {
                            deleteChapter(chapter)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .padding(.bottom)
    }

    /// Many pasted-in excerpts (especially from the medical textbooks)
    /// already carry their own leading/trailing quotation marks straight
    /// from the source PDF — wrapping those again produced a visible
    /// double-quote (`""..."."`). Only add quotes when the text doesn't
    /// already have its own.
    private func quotedText(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoteChars: Set<Character> = ["\"", "\u{201C}", "\u{201D}"]
        if let first = trimmed.first, let last = trimmed.last,
           quoteChars.contains(first), quoteChars.contains(last) {
            return trimmed
        }
        return "\"\(trimmed)\""
    }

    /// Both deletes drop the row from the cached list directly and bump
    /// `contentsRevision`, so the screen updates on the frame of the tap and
    /// the caches are re-read behind it. Removing it locally first matters: the
    /// re-read is a runloop turn away, and without it a deleted card would sit
    /// on screen until then.
    private func deleteHighlight(_ highlight: Highlight) {
        if let index = book.highlights.firstIndex(of: highlight) {
            book.highlights.remove(at: index)
            modelContext.delete(highlight)
            SpotlightIndexer.deindex(highlight)
            WidgetCenter.shared.reloadAllTimelines()
            sortedHighlights.removeAll { $0.id == highlight.id }
            highlightCount = sortedHighlights.count
            contentsRevision += 1
        }
    }

    private func deleteChapter(_ chapter: Chapter) {
         if let index = book.chapters.firstIndex(of: chapter) {
            book.chapters.remove(at: index)
            modelContext.delete(chapter)
            sortedChapters.removeAll { $0.id == chapter.id }
            chapterCount = sortedChapters.count
            contentsRevision += 1
        }
    }
}

struct StatView: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline)
                .fontWeight(.bold)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
