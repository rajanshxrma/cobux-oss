import SwiftUI
import WidgetKit
import SwiftData

/// Which shape the shelf draws itself in. His ask, near-verbatim: *"list view
/// as well option for the library books"* (ledger N19,
/// docs/instruction-ledger.md) -- the grid (`BookCard`) was the only shape
/// there had ever been.
///
/// `String` raw values, not an `Int`-backed enum: `@AppStorage` persists by
/// the raw value itself, so a case inserted between these two later can't
/// silently reassign a choice someone already made the way reordering an
/// `Int` enum would.
enum LibraryLayout: String, CaseIterable {
    case grid
    case list

    var label: String {
        switch self {
        case .grid: "Grid"
        case .list: "List"
        }
    }

    var systemImage: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }
}

struct LibraryView: View {
    @Binding var path: NavigationPath
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]
    @State private var searchText = ""
    @State private var showingAddBook = false
    @State private var unsortedCount = 0
    @Namespace private var bookHeroNamespace

    let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 16)
    ]

    @AppStorage(BookSourceFilter.excludedKey) private var excludedRaw: String = ""
    @AppStorage(BookSourceFilter.includedKey) private var includedRaw: String = ""
    /// Persisted so the choice survives a relaunch -- default `.grid`, which
    /// is byte-identical to every shelf before this existed.
    @AppStorage("libraryLayout") private var libraryLayout: LibraryLayout = .grid

    /// The filter, resolved ONCE per render.
    ///
    /// `effectiveExcludedIDs` decodes two comma-joined UUID strings and scans
    /// every `Book`, faulting `contentProfileRaw` on each. It used to be
    /// reached through `isExcludedFromFlow(book)` -- called TWICE inside each
    /// card's `.contextMenu` builder (the label and its icon), and this file's
    /// own comment records that "SwiftUI builds a context menu's content ahead
    /// of the press." So laying out the shelf ran two whole-library scans per
    /// visible card, before anything was pressed.
    private var effectiveExcludedIDs: Set<UUID> {
        BookSourceFilter.effectiveExcludedIDs(
            books: books, excludedRaw: excludedRaw, includedRaw: includedRaw)
    }

    /// Kept for the tap path (`toggleFlowInclusion`), which runs once and needs
    /// a fresh answer. The render path uses the single `excluded` set `body`
    /// resolves for the whole grid.
    private func isExcludedFromFlow(_ book: Book) -> Bool {
        effectiveExcludedIDs.contains(book.id)
    }

    /// Writes BOTH keys, never just the exclusion one. Switching a book back ON
    /// has to record an explicit inclusion, or a default-off book silently
    /// returns to being off -- the asymmetry `BookSourceFilterView` already
    /// documents, and the reason a re-included book used to disappear again.
    private func toggleFlowInclusion(_ book: Book) {
        var excluded = BookSourceFilter.decode(excludedRaw)
        var included = BookSourceFilter.decode(includedRaw)
        if isExcludedFromFlow(book) {
            excluded.remove(book.id); included.insert(book.id)
        } else {
            included.remove(book.id); excluded.insert(book.id)
        }
        excludedRaw = BookSourceFilter.encode(excluded)
        includedRaw = BookSourceFilter.encode(included)
        // The widget keeps its own copy via the App Group, so a change here has
        // to be republished or it goes on serving a hidden book.
        BookSourceSharing.publish(BookSourceFilter.effectiveExcludedIDs(
            books: books, excludedRaw: excludedRaw, includedRaw: includedRaw))
        WidgetCenter.shared.reloadAllTimelines()
    }

    var filteredBooks: [Book] {
        if searchText.isEmpty {
            return books
        } else {
            return books.filter { $0.title.localizedCaseInsensitiveContains(searchText) || $0.author.localizedCaseInsensitiveContains(searchText) }
        }
    }

    /// One accelerator menu, callable from either shelf shape. Lifted out of
    /// the grid's `ForEach` unchanged (same four actions, same `.bookMenu`
    /// marking) so the list layout gets it too rather than losing a working
    /// capability just because a book is drawn as a row instead of a card.
    @ViewBuilder
    private func bookContextMenu(for book: Book, excluded: Set<UUID>) -> some View {
        Button {
            CobuxTip.bookMenu.markUsed()
            openURL(CobuxDeepLink.bookURL(bookID: book.id))
        } label: {
            Label("Chat about this book",
                  systemImage: "bubble.left.and.text.bubble.right")
        }
        Button {
            CobuxTip.bookMenu.markUsed()
            openURL(CobuxDeepLink.quizURL())
        } label: {
            Label("Quiz me on this book", systemImage: "checkmark.circle")
        }
        Button {
            CobuxTip.bookMenu.markUsed()
            toggleFlowInclusion(book)
        } label: {
            // Two reads of one already-resolved Set, not two whole-library
            // scans.
            let hidden = excluded.contains(book.id)
            Label(hidden ? "Show in Flow" : "Hide from Flow",
                  systemImage: hidden ? "eye" : "eye.slash")
        }
        Button {
            CobuxTip.bookMenu.markUsed()
            book.dateFinished = book.dateFinished == nil ? .now : nil
            try? modelContext.save()
        } label: {
            Label(book.dateFinished == nil ? "Mark as Finished" : "Mark as Unfinished",
                  systemImage: book.dateFinished == nil ? "checkmark.seal" : "arrow.uturn.backward")
        }
    }

    /// Today's shape, unchanged: a `BookCard` per book in an adaptive grid.
    @ViewBuilder
    private func libraryGrid(excluded: Set<UUID>) -> some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(filteredBooks) { book in
                NavigationLink(destination: BookDetailView(book: book, heroTransitionNamespace: bookHeroNamespace)) {
                    BookCard(book: book)
                        .cobuxZoomTransitionSource(id: book.id, in: bookHeroNamespace)
                }
                .buttonStyle(PlainButtonStyle())
                // Long-press the book itself. A setting that is ABOUT one
                // book belongs on that book, not buried in a Settings screen
                // -- which is where the Flow filter lived for weeks.
                //
                // An accelerator, never a home: every action here also
                // exists somewhere visible. Capped at four, because a
                // context menu with six items is a settings screen with
                // extra steps.
                //
                // Each action marks `.bookMenu` used rather than a single
                // hook on the menu itself: SwiftUI builds a context menu's
                // content ahead of the press, so "the menu was built" is not
                // evidence anyone saw it. Taking an action from it IS.
                .contextMenu { bookContextMenu(for: book, excluded: excluded) }
                .scrollTransition { content, phase in
                    content
                        .opacity(phase.isIdentity ? 1 : 0.4)
                        .scaleEffect(phase.isIdentity ? 1 : 0.92)
                }
            }
        }
        .padding(16)
    }

    /// His ask: *"list view as well option for the library books"* (ledger
    /// N19). Same `filteredBooks`, same destination, same accelerator menu as
    /// the grid -- only `BookCard` is swapped for `BookListRow` and the
    /// layout is a plain vertical stack instead of an adaptive grid.
    @ViewBuilder
    private func libraryList(excluded: Set<UUID>) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(filteredBooks) { book in
                NavigationLink(destination: BookDetailView(book: book, heroTransitionNamespace: bookHeroNamespace)) {
                    BookListRow(book: book)
                        .cobuxZoomTransitionSource(id: book.id, in: bookHeroNamespace)
                }
                .buttonStyle(PlainButtonStyle())
                .contextMenu { bookContextMenu(for: book, excluded: excluded) }
            }
        }
        .padding(.horizontal, CobuxSpacing.screenMargin)
    }

    /// The quiet fact at the end of the shelf: what is actually in here.
    ///
    /// His ask, near-verbatim: *"at the botom of the library it should display
    /// like how many books and or etc info idk but ye"* -- so it is a fact
    /// about the LIBRARY, never about him. No progress, no percentage, no
    /// "read 12 of 156": the standing ruling is that Cobux never grades the
    /// user, and a shelf that scores you is the same frame the completion ticks
    /// were retired for. Two numbers, past tense, no verb.
    ///
    /// It says "shown" rather than "in your library" whenever a search is
    /// narrowing the grid, because the count under a filtered shelf that claims
    /// to be the whole library is just a lie with a number in it.
    ///
    /// WHY IT IS NO LONGER GATED ON AN ASYNC SNAPSHOT. It used to render only
    /// `if let totals = libraryTotals, totals.books > 0` -- an optional tuple
    /// in `@State`, filled by a one-shot `.task` that asked the store for a
    /// second book count. He reported the result as the feature having been
    /// deleted: *"what happened to the end of the library, I told you when a
    /// user scrolls to the bottom it shows the information of how many books
    /// ... now it's not there."* Three ways that gate withholds the line:
    ///
    /// 1. The count was already in hand. The grid directly above this was laid
    ///    out from `books`, so how many books are on this shelf is a
    ///    synchronous fact about what is on screen. Asking the store a second
    ///    time, later, could only ever disagree with what was drawn.
    /// 2. A `fetchCount` that reads an empty store latches `(0, 0)`, and
    ///    `totals.books > 0` then suppresses the footer for the WHOLE of that
    ///    appearance -- under a shelf full of books. That is not hypothetical:
    ///    `SeedRunner.seed` runs a mutating pass on every launch and saves only
    ///    at the end, and a first run / restore populates the store long after
    ///    the tab can have appeared.
    /// 3. `.task` carried no `id`, so a wrong answer was never corrected.
    ///    Adding one book left `filteredBooks.count != totals.books` true for
    ///    the rest of the session and silently swapped the sentence for
    ///    "157 of 156 books shown" -- not the feature he asked for.
    ///
    /// So the books half is `books.count` and cannot fail to render while the
    /// shelf has anything on it. Only the highlight total is asked of the
    /// store, it is re-asked whenever the shelf's own count changes, and it is
    /// ADDITIVE: the line reads "156 books" until it lands and
    /// "156 books · 32,125 highlights" after, rather than nothing at all.
    ///
    /// AND IT IS LEGIBLE NOW, which is the other half of "it's not there".
    /// `.font(.caption)` + `.foregroundStyle(.tertiary)` on
    /// `Color.cobuxBackground` measures **1.73:1 in light and 2.32:1 in dark**
    /// by this app's own `CobuxContrast` arithmetic (UIKit's `tertiaryLabel` is
    /// 30% ink, composited over the near-white / near-black grounds in
    /// `Assets.xcassets`). WCAG's floor is 4.5:1 for type this size and 3:1 for
    /// anything at all; 1.73:1 at 12pt is light grey on white. The design
    /// system's own secondary ink, `Color.cobuxMuted`, is 4.64:1 / 6.08:1 on
    /// the same two grounds -- so the one line that says what the library holds
    /// was painted at roughly a third of the contrast every other secondary
    /// line in the app runs at.
    ///
    /// `scripts/check-contrast.py` is a ship gate for exactly this and could
    /// not catch it: it resolves `.colorset` entries and hex literals, and
    /// SwiftUI's `.tertiary` is neither. That is the same blind spot the same
    /// script was extended for in build 54 (it measured month hues as pill
    /// fills and never as type).
    @ViewBuilder
    private var shelfFooter: some View {
        let narrowed = !searchText.isEmpty || filteredBooks.count != books.count
        VStack(spacing: CobuxSpacing.md) {
            // The end of the shelf, said as a rule rather than implied by
            // running out of cards. It is also what keeps the line below from
            // reading as a stray caption floating under the last row.
            Rectangle()
                .fill(Color.cobuxLine)
                .frame(height: 1)
            Text(narrowed
                 ? "\(filteredBooks.count.formatted()) of \(Self.plural(books.count, "book", "books")) shown"
                 : shelfSummary)
                .font(.footnote)
                .fontWeight(.medium)
                .foregroundStyle(Color.cobuxMuted)
                .monospacedDigit()
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, CobuxSpacing.screenMargin)
        .padding(.top, CobuxSpacing.sm)
        .padding(.bottom, CobuxSpacing.lg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(narrowed
                            ? "Showing \(filteredBooks.count) of \(books.count) books"
                            : shelfSummary)
    }

    /// Two facts, or one while the second is still being counted. Never a
    /// placeholder and never a zero: a number the app does not have yet is
    /// simply not said.
    private var shelfSummary: String {
        let booksPart = Self.plural(books.count, "book", "books")
        guard let highlights = libraryHighlightCount, highlights > 0 else { return booksPart }
        return "\(booksPart) · \(Self.plural(highlights, "highlight", "highlights"))"
    }

    private static func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count.formatted()) \(count == 1 ? one : many)"
    }

    /// One `COUNT`, off the render path -- never by materialising rows, per his
    /// standing rule that a screen renders its first frame with no work behind
    /// it. Re-asked whenever the shelf's own book count changes, which is what
    /// covers the seed/upgrade merge finishing, a book added and a book
    /// deleted. The old one-shot `.task` noticed none of the three.
    private func refreshHighlightCount() {
        libraryHighlightCount = try? modelContext.fetchCount(FetchDescriptor<Highlight>())
    }

    /// Semantic results for the current query, computed OFF the main thread and
    /// debounced -- not a computed property.
    ///
    /// It used to be `var semanticHighlights: [Highlight]` reading straight from
    /// `body`, so every keystroke ran `semanticSearch` synchronously on the main
    /// actor: `books.flatMap(\.highlights)` over the whole bundled library --
    /// 32,125 highlights across 156 seed books (scripts/check-corpus-scale.py,
    /// build 52) -- plus a cosine pass, between one character and the next. That
    /// is why typing into Library search stutters. The work is identical; only
    /// when and where it runs changed.
    @State private var semanticHighlights: [Highlight] = []

    /// Whether `semanticHighlights` has caught up with the text in the field.
    ///
    /// Load-bearing for the no-matches state below, not bookkeeping: the
    /// semantic pass is 300ms behind every keystroke, so without this the
    /// screen would flash "No matches" between letters of a query that does
    /// match something. Also false while the seed merge is running, because a
    /// half-merged library is not evidence that nothing matches.
    @State private var semanticSearchSettled = true
    /// How many highlights the whole library holds. `nil` means "not counted
    /// yet", which the footer says by omitting that half of the sentence --
    /// deliberately NOT by withholding the sentence, which is the bug this
    /// screen shipped with (see `shelfFooter`).
    @State private var libraryHighlightCount: Int?

    /// Debounce, so a fast typist runs the search once rather than once per
    /// letter. 300ms is the usual "stopped typing" threshold.
    private static let searchDebounce: Duration = .milliseconds(300)

    /// A search that found nothing anywhere -- no title, no author, and no
    /// highlight close enough in meaning. Distinct from an empty library,
    /// which has its own state and its own action.
    private var searchFoundNothing: Bool {
        !searchText.isEmpty && !books.isEmpty && semanticSearchSettled
            && filteredBooks.isEmpty && semanticHighlights.isEmpty
    }

    private func refreshSemanticResults(for query: String) async {
        // Same seed-merge guard as `BookDetailView`/`BookCard` (see BookCard's
        // doc comment for the confirmed Build-5 crash class): `semanticSearch`
        // faults every book's `highlights` relationship, which must never race
        // the background seed merge.
        guard !query.isEmpty, !SeedingStatus.shared.isSeeding else {
            semanticHighlights = []
            // Settled only when there is genuinely nothing to search FOR. If
            // we bailed because the merge is running, the results are unknown,
            // not empty -- and "No matches" must never be said on a guess.
            semanticSearchSettled = query.isEmpty
            return
        }
        semanticSearchSettled = false
        try? await Task.sleep(for: Self.searchDebounce)
        guard !Task.isCancelled else { return }
        // Off this actor now: `SemanticSearchProbe` embeds the query, scores
        // the cached vector table and ranks on its own executor, and only the
        // winning ids come back to be fetched here. What used to happen on
        // every keystroke -- faulting every embedded highlight in the library
        // (~33,400 rows, 2 KB of vector each) on the main actor -- no longer
        // touches this actor at all. The debounce stays; the yield it used to
        // need is now the `await` itself.
        let results = await SearchService.semanticSearch(query: query, books: books, topK: 10, in: modelContext)
        guard !Task.isCancelled else { return }
        semanticHighlights = results
        semanticSearchSettled = true
    }

    /// The shelf's walkthrough queue, in priority order. Both tips name a
    /// capability with no affordance anywhere on this screen, which is the
    /// case his standing principle is aimed at: *"user shuold be shown the
    /// features cobux offers and put them in fornt of users eyes against them
    /// manually finding them out wherever."*
    ///
    /// `captureQuote` drops out the moment anything is unsorted -- proof the
    /// Share Extension has been found -- and the host shows only the first
    /// unseen one per visit, so this is never two cards stacked over the grid.
    /// Neither shows on a shelf with no books: that reader has the "Add your
    /// first book" state to read, and a hint about sharing INTO a library
    /// they do not have yet would be advice for later.
    private var libraryTips: [CobuxTip] {
        guard !books.isEmpty else { return [] }
        return unsortedCount > 0 ? [.bookMenu] : [.captureQuote, .bookMenu]
    }

    var body: some View {
        NavigationStack(path: $path) {
            // One resolution for the whole grid -- see `effectiveExcludedIDs`.
            let excluded = effectiveExcludedIDs
            ScrollView {
                CobuxFeatureTipHost(firstOf: libraryTips)
                    .padding(.horizontal, CobuxSpacing.screenMargin)
                    .padding(.top, CobuxSpacing.sm)

                if unsortedCount > 0 {
                    unsortedRow
                }

                if books.isEmpty {
                    CobuxEmptyStateView(
                        icon: "books.vertical",
                        title: "Add your first book",
                        message: "Start storing wisdom from your reading."
                    ) {
                        CobuxEmptyStateButton("Add Book") { showingAddBook = true }
                    }
                } else {
                    // The one thing his ask didn't ask to change: which books
                    // are on the shelf and what a search narrows it to. Both
                    // layouts read `filteredBooks` and `excluded` exactly the
                    // way the grid always did -- only the shape of a book's
                    // row differs.
                    Group {
                        switch libraryLayout {
                        case .grid:
                            libraryGrid(excluded: excluded)
                        case .list:
                            libraryList(excluded: excluded)
                        }
                    }
                    // Plain default animation on the value, per the standing
                    // instruction -- not a custom spring for a switch this
                    // infrequent.
                    .animation(.default, value: libraryLayout)

                    shelfFooter
                }

                if !searchText.isEmpty && !semanticHighlights.isEmpty {
                    highlightsSection
                } else if searchFoundNothing {
                    // Before this, a search that matched nothing left an empty
                    // grid and no words at all -- the reader can't tell a
                    // library search from a broken one. It also says what this
                    // field actually searches, which is more than titles.
                    CobuxEmptyStateView(
                        icon: "magnifyingglass",
                        title: "No matches",
                        message: "No book title or author matches that, and no highlight in your library comes close to the idea either. Try a shorter word."
                    )
                }
            }
            .background(Color.cobuxBackground)
            // REAL CLEARANCE FOR THE END OF THE SHELF, reserved by the layout
            // system at the container rather than baked into the last child.
            //
            // The bottom of this screen is crowded by things this file does not
            // own and cannot see: the floating iOS 26 tab bar, and the Flow
            // launch button, which `ContentView` attaches as a
            // `safeAreaInset(edge: .bottom)` from OUTSIDE this view's
            // `NavigationStack` (`FlowLaunchInset`), so its reservation reaches
            // this scroll view only by propagating down through the stack. The
            // footer used to be the last thing in the content with 24pt under
            // it and nothing else, which put the one line that says what the
            // library holds at the very edge of that chain.
            //
            // `contentMargins(for: .scrollContent)` is the scroll view's own
            // end-of-content reservation and composes ADDITIVELY with whatever
            // safe area does arrive, so this is not a clearance constant
            // standing in for the layout system (the class `magic-clearance` in
            // scripts/swiftui-regression-lint.py exists to catch) -- it is the
            // layout system being asked for the space.
            .contentMargins(.bottom, CobuxSpacing.xxl, for: .scrollContent)
            .navigationTitle("Library")
            .searchable(text: $searchText, prompt: "Search books or authors")
            // Re-runs on every query change and CANCELS the in-flight one, which
            // is what makes the debounce above actually debounce.
            .task(id: searchText) { await refreshSemanticResults(for: searchText) }
            // Keyed on the shelf's own count, so the highlight total is recounted
            // when the seed merge lands, when a book is added and when one is
            // deleted. It was `.task { }` with no id, which asked once per
            // appearance and then believed that answer for the whole session.
            // `Task.yield()` first: `.task` starts in the same main-actor turn
            // as the render pass, and under the UIKit tab shell it restarts on
            // every switch to this tab, so this COUNT over every highlight in
            // the library (~32,000 rows) sat in the frame of every tap on
            // Library. The footer says "not counted yet" by omission, so the
            // answer landing one turn later costs nothing visible.
            .task(id: books.count) {
                await Task.yield()
                refreshHighlightCount()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showingAddBook = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            // NOT a second trailing button -- iOS 26's glass capsules widen
            // the whole trailing group for every item in it, and "Library"
            // already shares that budget with the "+" above. A title menu
            // hangs its chevron off the nav title itself instead, which is
            // where Photos/Files put exactly this kind of view/sort control.
            .toolbarTitleMenu {
                Section("View") {
                    Picker("Layout", selection: $libraryLayout) {
                        ForEach(LibraryLayout.allCases, id: \.self) { layout in
                            Label(layout.label, systemImage: layout.systemImage)
                                .tag(layout)
                                .accessibilityLabel("\(layout.label) layout")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAddBook) {
                AddBookView()
            }
            .onAppear(perform: refreshUnsortedCount)
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active, CrossProcessSync.consumeDirtyFlag() else { return }
                refreshUnsortedCount()
            }
        }
    }

    /// A quote captured via the Share Extension before it's filed to a book. Only shown when
    /// non-zero so the row never adds clutter for anyone who's never used Share.
    private var unsortedRow: some View {
        NavigationLink(destination: UnsortedHighlightsView()) {
            HStack {
                Image(systemName: "tray.fill")
                    .foregroundStyle(Color.cobuxAccent)
                Text("Unsorted (\(unsortedCount))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .cobuxCard()
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func refreshUnsortedCount() {
        let descriptor = FetchDescriptor<Highlight>(predicate: #Predicate<Highlight> { $0.book == nil })
        unsortedCount = (try? modelContext.fetchCount(descriptor)) ?? 0
        // An unsorted quote can only have arrived through the Share Extension,
        // so its presence IS the proof the feature was found. Marking it used
        // (not just filtering the tip out) means it stays gone after the quote
        // is filed and the count returns to zero -- discovery beats instruction.
        if unsortedCount > 0 { CobuxTip.captureQuote.markUsed() }
    }

    @ViewBuilder
    private var highlightsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Highlights")
                .font(.title3)
                .fontWeight(.bold)
                .padding(.horizontal)

            VStack(spacing: 12) {
                ForEach(semanticHighlights) { highlight in
                    if let book = highlight.book {
                        NavigationLink(destination: BookDetailView(book: book)) {
                            HighlightSearchCard(highlight: highlight, book: book)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.top, 8)
    }
}

private struct HighlightSearchCard: View {
    let highlight: Highlight
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\"\(highlight.text)\"")
                .font(.subheadline)
                .italic()
                .lineLimit(3)
                .foregroundStyle(.primary)

            HStack(spacing: 4) {
                BookTitleText(title: book.title, font: .caption, weight: .semibold, color: Color.cobuxAccent)
                if let chapter = highlight.chapter, !chapter.isEmpty {
                    Text("· \(chapter)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cobuxCard()
    }
}
