import SwiftUI
import SwiftData

/// Browse highlights grouped by theme across every book, built purely from the
/// free-text tags the user already types on highlights. No AI, no network calls —
/// deterministic and instant.
struct WisdomGraphView: View {
    @Bindable var claudeService: ClaudeService
    @Binding var path: NavigationPath
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Theme.name) private var themes: [Theme]
    @Query private var highlights: [Highlight]
    @Query private var books: [Book]
    @AppStorage(BookSourceFilter.excludedKey) private var excludedRaw: String = ""
    @AppStorage(BookSourceFilter.includedKey) private var includedRaw: String = ""
    @State private var showingSourcePicker = false
    @State private var searchText = ""
    @State private var showMergeExplanation = false
    @State private var isMerging = false
    @State private var mergeResultMessage: String?
    @State private var showMergeResult = false
    @State private var showNoAPIKeyAlert = false
    @AppStorage("hasSeenTagMergeExplanation") private var hasSeenTagMergeExplanation = false
    @State private var showingFlow = false

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 14)]

    /// The same book scoping Flow applies, shared through `BookSourceFilter`
    /// so a book switched off in one surface is off in both. One filter, one
    /// answer — being told a book is excluded and then meeting it here anyway
    /// would read as the setting being broken.
    private var excludedBookIDs: Set<UUID> {
        BookSourceFilter.effectiveExcludedIDs(books: books, excludedRaw: excludedRaw, includedRaw: includedRaw)
    }

    /// Everything `body` needs to know about book scoping, resolved in exactly
    /// one pass over the library.
    ///
    /// This used to be five separate computed properties (`excludedBookIDs`,
    /// `scopedHighlights`, `scopedThemes`, `visibleHighlights(in:)`,
    /// `filteredThemes`), each recomputed from scratch on every single access —
    /// and `body` touched them nine times, twice from *inside* a `ForEach` over
    /// themes. Worse, the per-highlight `isVisible` helper called
    /// `excludedBookIDs` itself, so `effectiveExcludedIDs` (a full scan of every
    /// `Book`, faulting `contentProfileRaw` on each) ran once per highlight
    /// rather than once per render. With this library's seed content — 26 books,
    /// ~5,900 highlights, hundreds of themes — a single render of this screen
    /// worked out to tens of millions of relationship faults, which is the
    /// "switching tabs takes forever" report: the Wisdom tab was recomputing an
    /// O(themes² × highlights × books) answer to a question with an O(themes +
    /// highlights) answer. Same numbers on screen, computed once.
    private struct Scope {
        var excludedBookIDs: Set<UUID> = []
        var hasAnyVisibleHighlight = false
        /// A theme survives if anything still in scope carries it. Themes that
        /// only ever came from a switched-off book disappear entirely; themes a
        /// reference text merely *shares* with the rest of the library stay,
        /// with their counts narrowed to what's in scope.
        var themes: [Theme] = []
        /// `themes` narrowed by the search field.
        var filteredThemes: [Theme] = []
        var visibleCounts: [UUID: Int] = [:]

        func visibleHighlightCount(in theme: Theme) -> Int { visibleCounts[theme.id] ?? 0 }
    }

    private func makeScope() -> Scope {
        var scope = Scope()
        let excluded = excludedBookIDs
        scope.excludedBookIDs = excluded

        if excluded.isEmpty {
            // Nothing is filtered out, so no highlight needs visiting at all —
            // the counts are the relationship counts and every theme survives.
            scope.hasAnyVisibleHighlight = !highlights.isEmpty
            scope.themes = themes
            for theme in themes { scope.visibleCounts[theme.id] = theme.highlights.count }
        } else {
            // `contains(where:)` rather than building and discarding a filtered
            // array of every visible highlight just to ask whether one exists.
            scope.hasAnyVisibleHighlight = highlights.contains {
                BookSourceFilter.isVisible($0, excluding: excluded)
            }
            for theme in themes {
                let visible = theme.highlights.reduce(into: 0) { total, highlight in
                    if BookSourceFilter.isVisible(highlight, excluding: excluded) { total += 1 }
                }
                scope.visibleCounts[theme.id] = visible
                if visible > 0 { scope.themes.append(theme) }
            }
        }

        // Filters by theme name only — a reference textbook can contribute
        // hundreds of narrow, subject-specific themes (vs. the small handful a
        // self-help book produces), so finding one by scrolling alone stopped
        // being practical.
        scope.filteredThemes = searchText.isEmpty
            ? scope.themes
            : scope.themes.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        return scope
    }

    /// Only `runTagMerge` needs the highlights themselves rather than a count,
    /// and it runs on a tap, not on every render — so this stays a one-shot
    /// computation instead of joining `Scope`. It still resolves
    /// `excludedBookIDs` exactly once rather than once per highlight.
    private var scopedHighlights: [Highlight] {
        let excluded = excludedBookIDs
        guard !excluded.isEmpty else { return highlights }
        return highlights.filter { BookSourceFilter.isVisible($0, excluding: excluded) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            if SeedingStatus.shared.isSeeding {
                // Same seed-merge guard as `BookDetailView`/`QuizHomeView` --
                // `Scope` faults `Theme.highlights` synchronously while building,
                // which is the confirmed Build-5 crash class if it lands mid
                // seed/upgrade merge. Missing here until now; a user swiping to
                // Wisdom during a merge could hit the same crash every other
                // launch-adjacent screen already guards against.
                ProgressView("Syncing your library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Wisdom Graph")
            } else {
                graphContent(makeScope())
            }
        }
    }

    @ViewBuilder
    private func graphContent(_ scope: Scope) -> some View {
            ScrollView {
                VStack(spacing: 20) {
                    // Flow lives here rather than as a 6th tab — five tabs is
                    // already the ergonomic ceiling, and Wisdom is the
                    // browse-your-library tab Flow is the moving version of.
                    if scope.hasAnyVisibleHighlight {
                        flowHeroCard
                    }

                    if themes.isEmpty {
                        emptyState
                    } else if scope.themes.isEmpty {
                        allBooksExcludedState
                    } else if scope.filteredThemes.isEmpty {
                        noSearchResultsState
                    } else {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(scope.filteredThemes) { theme in
                                // `allThemes:` passes the scoped list, not the
                                // search-filtered one — related-theme navigation
                                // inside a theme's detail view shouldn't be
                                // limited by whatever search text happens to be
                                // active here, but it must still respect which
                                // books are switched on.
                                NavigationLink(destination: WisdomThemeDetailView(
                                    theme: theme,
                                    allThemes: scope.themes,
                                    excludedBookIDs: scope.excludedBookIDs
                                )) {
                                    ThemeCard(theme: theme, highlightCount: scope.visibleHighlightCount(in: theme))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Wisdom Graph")
            .searchable(text: $searchText, prompt: "Search themes")
            .fullScreenCover(isPresented: $showingFlow) {
                FlowView()
            }
            .sheet(isPresented: $showingSourcePicker) {
                NavigationStack {
                    BookSourceFilterView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingSourcePicker = false }
                            }
                        }
                }
            }
            .onAppear {
                claudeService.apiKey = KeychainManager.load(key: KeychainManager.anthropicAPIKey) ?? ""
            }
            .toolbar {
                if !themes.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                rebuildGraph()
                            } label: {
                                Label("Rebuild (Free)", systemImage: "arrow.clockwise")
                            }

                            Button {
                                showingSourcePicker = true
                            } label: {
                                Label("Books in Flow and Wisdom", systemImage: "line.3.horizontal.decrease.circle")
                            }

                            Button {
                                if LocalAIService.isAvailable {
                                    // Free and on-device -- no key, no cost, no
                                    // confirmation needed, unlike the Claude path.
                                    runTagMerge()
                                } else if claudeService.apiKey.isEmpty {
                                    showNoAPIKeyAlert = true
                                } else if hasSeenTagMergeExplanation {
                                    runTagMerge()
                                } else {
                                    showMergeExplanation = true
                                }
                            } label: {
                                Label(LocalAIService.isAvailable ? "Merge Similar Tags (On-Device)" : "Merge Similar Tags (AI)", systemImage: "sparkles")
                            }
                            .disabled(isMerging)
                        } label: {
                            if isMerging {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .accessibilityLabel("Wisdom Graph options")
                    }
                }
            }
            .alert("Merge Similar Tags?", isPresented: $showMergeExplanation) {
                Button("Cancel", role: .cancel) { }
                Button("Merge") {
                    hasSeenTagMergeExplanation = true
                    runTagMerge()
                }
            } message: {
                Text("Uses your Anthropic API key to group near-synonym tags (like \"ego\", \"pride\", \"arrogance\") into one theme. This costs a small amount, roughly a few cents, the first time — after that it's cached and free to reuse unless you add enough new tags to need re-merging.")
            }
            .alert("Merge Result", isPresented: $showMergeResult) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(mergeResultMessage ?? "")
            }
            .alert("API Key Required", isPresented: $showNoAPIKeyAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Add your Anthropic API key in Settings to use AI tag merging. The free rebuild option doesn't need one.")
            }
    }

    /// Shared by the two plain "rebuild the graph" call sites (toolbar menu,
    /// empty-state button) -- `buildGraph` now throws (see its doc comment: it
    /// wipes and repopulates every `Theme` row, and a silently swallowed save
    /// failure used to leave the user looking at a rebuilt graph that would
    /// vanish on relaunch with no indication anything went wrong). Reuses the
    /// same alert `runTagMerge` already has rather than adding a second one.
    private func rebuildGraph() {
        do {
            try withAnimation(.easeInOut(duration: 0.25)) {
                try WisdomGraphService.buildGraph(highlights: highlights, modelContext: modelContext)
            }
        } catch {
            mergeResultMessage = "Couldn't rebuild the graph: \(error.localizedDescription)"
            showMergeResult = true
        }
    }

    private func runTagMerge() {
        isMerging = true
        Task {
            do {
                // Scoped, unlike `buildGraph` above: this one can be a real
                // paid call priced on the tag list it's handed, and there's no
                // sense paying to tidy up tags from books that are switched
                // off and will never be displayed.
                let (mapping, madeAPICall, usedLocalAI) = try await WisdomGraphService.mergeSimilarTags(highlights: scopedHighlights, claudeService: claudeService)
                await MainActor.run {
                    isMerging = false
                    do {
                        try withAnimation(.easeInOut(duration: 0.25)) {
                            try WisdomGraphService.buildGraph(highlights: highlights, modelContext: modelContext)
                        }
                    } catch {
                        // Distinct message from the merge-failure `catch` below --
                        // the merge itself already succeeded at this point, only
                        // the rebuild-with-the-merged-tags step failed. `return`
                        // here so the merge-success messaging right below can't
                        // silently overwrite this with "Merged N tag(s)..." after
                        // the graph that was supposed to reflect that merge failed
                        // to save.
                        mergeResultMessage = "Tags merged, but rebuilding the graph failed: \(error.localizedDescription)"
                        showMergeResult = true
                        return
                    }
                    if usedLocalAI {
                        mergeResultMessage = mapping.isEmpty
                            ? "No similar tags found to merge — your tags are already distinct. Ran on-device, no cost."
                            : "Merged \(mapping.count) tag(s) into shared themes — ran entirely on-device, no cost."
                    } else if madeAPICall {
                        mergeResultMessage = mapping.isEmpty
                            ? "No similar tags found to merge — your tags are already distinct."
                            : "Merged \(mapping.count) tag(s) into shared themes."
                    } else {
                        mergeResultMessage = "Already up to date — no new tags since the last merge, so no charge this time."
                    }
                    showMergeResult = true
                }
            } catch {
                await MainActor.run {
                    isMerging = false
                    mergeResultMessage = "Couldn't merge tags right now: \(error.localizedDescription)"
                    showMergeResult = true
                }
            }
        }
    }

    /// Distinct from "you haven't built a graph yet" — the graph exists, every
    /// book feeding it is just switched off. The fix is a switch, not a
    /// rebuild, so the button goes straight to the switch.
    private var allBooksExcludedState: some View {
        CobuxEmptyStateView(
            icon: "line.3.horizontal.decrease.circle",
            title: "No books switched on",
            message: "Every book in your library is currently switched off for Flow and the Wisdom Graph, so there are no themes to show."
        ) {
            CobuxEmptyStateButton("Choose Books", systemImage: "line.3.horizontal.decrease.circle") {
                showingSourcePicker = true
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.bottom, 40)
    }

    private var noSearchResultsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No themes match \"\(searchText)\"")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal)
    }

    /// The entry into the Flow feed — deliberately the most inviting thing on
    /// this screen. Gradient, not a plain row: it's advertising a full-screen
    /// experience, and it should look like one.
    private var flowHeroCard: some View {
        Button {
            showingFlow = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "water.waves")
                    .font(.title2)
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Flow")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Swipe through your library — quotes, lessons, quick checks")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.up.2")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(16)
            .background(
                LinearGradient(
                    colors: [Color.cobuxAccent, Color.cobuxAccent.opacity(0.72)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: CobuxRadius.card)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    private var emptyState: some View {
        CobuxEmptyStateView(
            icon: "point.3.connected.trianglepath.dotted",
            title: "Build your Wisdom Graph",
            message: "Group your highlights by theme across every book in your library — instant, and free."
        ) {
            CobuxEmptyStateButton("Build Wisdom Graph", systemImage: "sparkles") {
                rebuildGraph()
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.bottom, 40)
    }

}

private struct ThemeCard: View {
    let theme: Theme
    /// Passed in rather than read off `theme.highlights`, so the count matches
    /// the list you actually get when you tap through once books are scoped.
    let highlightCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title3)
                .foregroundStyle(Color.cobuxAccent)

            Text(theme.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            Text("\(highlightCount) highlight\(highlightCount == 1 ? "" : "s")")
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.cobuxAccent.opacity(0.15))
                .foregroundStyle(Color.cobuxAccent)
                .clipShape(Capsule())
        }
        .padding(14)
        .frame(height: 120, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cobuxCard()
    }
}

struct WisdomThemeDetailView: View {
    let theme: Theme
    let allThemes: [Theme]
    /// Carried down rather than re-derived from `@AppStorage`, so this screen
    /// and the card that pushed it can never disagree about what's in scope.
    let excludedBookIDs: Set<UUID>

    private var visibleHighlights: [Highlight] {
        excludedBookIDs.isEmpty
            ? theme.highlights
            : theme.highlights.filter { BookSourceFilter.isVisible($0, excluding: excludedBookIDs) }
    }

    /// A related theme built entirely out of switched-off books is dropped
    /// rather than shown greyed out — it isn't unavailable, it doesn't apply.
    private var visibleRelatedNames: [String] {
        guard !excludedBookIDs.isEmpty else { return theme.relatedThemeNames }
        return theme.relatedThemeNames.filter { name in
            allThemes.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if visibleHighlights.isEmpty {
                    Text("No highlights in this theme.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                } else {
                    ForEach(visibleHighlights.sorted(by: { $0.dateAdded > $1.dateAdded })) { highlight in
                        HighlightCitationCard(highlight: highlight)
                    }
                }

                if !visibleRelatedNames.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Related Themes")
                            .font(.headline)
                            .padding(.top, 8)

                        RelatedThemeChips(
                            names: visibleRelatedNames,
                            allThemes: allThemes,
                            excludedBookIDs: excludedBookIDs
                        )
                    }
                }
            }
            .padding()
        }
        .navigationTitle(theme.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HighlightCitationCard: View {
    let highlight: Highlight

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\"\(highlight.text)\"")
                .font(.body)
                .italic()

            if let book = highlight.book {
                NavigationLink(destination: BookDetailView(book: book)) {
                    HStack(spacing: 4) {
                        Image(systemName: "book.closed.fill")
                            .font(.caption2)
                        Text(book.title)
                        if let chapter = highlight.chapter, !chapter.isEmpty {
                            Text("· \(chapter)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Color.cobuxAccent)
                }
            } else if let chapter = highlight.chapter, !chapter.isEmpty {
                Text(chapter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .cobuxCard()
    }
}

private struct RelatedThemeChips: View {
    let names: [String]
    let allThemes: [Theme]
    let excludedBookIDs: Set<UUID>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(names, id: \.self) { name in
                    relatedChip(for: name)
                }
            }
        }
    }

    @ViewBuilder
    private func relatedChip(for name: String) -> some View {
        if let match = allThemes.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            NavigationLink(destination: WisdomThemeDetailView(
                theme: match,
                allThemes: allThemes,
                excludedBookIDs: excludedBookIDs
            )) {
                TagBadge(tag: name)
            }
        } else {
            TagBadge(tag: name)
                .opacity(0.5)
        }
    }
}
