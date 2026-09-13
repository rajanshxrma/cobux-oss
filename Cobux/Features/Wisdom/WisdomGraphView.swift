import SwiftUI
import SwiftData

/// Browse highlights grouped by theme across every book, built purely from the
/// free-text tags the user already types on highlights. No AI, no network calls —
/// deterministic and instant.
struct WisdomGraphView: View {
    @Bindable var claudeService: ClaudeService
    @Binding var path: NavigationPath
    @Environment(\.modelContext) private var modelContext
    /// For the "Open Settings" action on the API-key alert (`cobux://settings`).
    @Environment(\.openURL) private var openURL
    @Query(sort: \Theme.name) private var themes: [Theme]
    /// No `@Query private var highlights: [Highlight]` any more.
    ///
    /// It was the single largest unbounded read left in the app: all ~32,000
    /// `Highlight` rows -- each carrying its full text and a 512-float
    /// embedding blob -- materialised on the main actor before the Wisdom tab
    /// could draw its first frame, and held resident for as long as the tab
    /// stayed alive. Three of its four readers (`rebuildGraph`, `runTagMerge`,
    /// `scopedHighlights`) run on a TAP and now fetch what they need then; the
    /// fourth wanted one boolean, which is a `fetchCount` (see `WisdomProbe`).
    @Query private var books: [Book]
    /// Stage one from `WisdomProbe`: whether anything in scope exists at all.
    /// `nil` until the probe answers -- the Flow hero card is a claim about his
    /// library, so it waits to be true rather than guessing.
    @State private var hasAnyVisibleHighlight: Bool?
    /// Stage two: highlight count per theme id. `nil` until it lands, and each
    /// card shows a pending count in the meantime rather than a wrong one.
    @State private var visibleCounts: [UUID: Int]?
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
    /// rather than once per render. With this library's seed content — 32,125
    /// highlights across 156 seed books (scripts/check-corpus-scale.py, build
    /// 52), hundreds of themes — a single render of this screen worked out to
    /// hundreds of millions of relationship faults, which is the "switching
    /// tabs takes forever" report: the Wisdom tab was recomputing an
    /// O(themes² × highlights × books) answer to a question with an O(themes +
    /// highlights) answer. Same numbers on screen, computed once.
    private struct Scope {
        var excludedBookIDs: Set<UUID> = []
        /// `nil` until the probe answers. Three-valued on purpose: "there is
        /// nothing to flow through" is a claim about his library, and a screen
        /// that has not read anything yet is not entitled to make it.
        var hasAnyVisibleHighlight: Bool?
        /// A theme survives if anything still in scope carries it. Themes that
        /// only ever came from a switched-off book disappear entirely; themes a
        /// reference text merely *shares* with the rest of the library stay,
        /// with their counts narrowed to what's in scope.
        var themes: [Theme] = []
        /// `themes` narrowed by the search field.
        var filteredThemes: [Theme] = []
        var visibleCounts: [UUID: Int]?

        /// `nil` while the count is still being worked out, so a card can show
        /// a pending state instead of a confident "0 highlights" that is only
        /// true because nothing has been read yet.
        func visibleHighlightCount(in theme: Theme) -> Int? { visibleCounts?[theme.id] }
    }

    /// Pure now: no store access at all, so calling it once per body evaluation
    /// costs a dictionary lookup per theme instead of a to-many relationship
    /// fault per theme.
    ///
    /// It used to read `theme.highlights` inside this loop — one SQL round trip
    /// per theme, returning that theme's highlight rows in full — from a screen
    /// that is `.searchable`, so every keystroke in the search field re-walked
    /// the whole tag join on the main actor. The numbers are identical; only
    /// where they come from changed (`WisdomProbe`).
    private func makeScope() -> Scope {
        var scope = Scope()
        scope.excludedBookIDs = excludedBookIDs
        // (61) The FIRST body of this tab reads `TabWarmCache` synchronously
        // when its own state is still empty, so the grid draws its real
        // numbers and the hero card on frame one -- no pending badges, no
        // probe -- whenever the cache was filled under exactly this book
        // scope. `loadCounts` then confirms or, if the cache is empty, probes.
        let cached = (hasAnyVisibleHighlight == nil || visibleCounts == nil)
            ? TabWarmCache.shared.wisdomCounts(for: modelContext.container, excluding: scope.excludedBookIDs)
            : nil
        scope.hasAnyVisibleHighlight = hasAnyVisibleHighlight ?? cached?.hasAnyVisibleHighlight
        scope.visibleCounts = visibleCounts ?? cached?.counts

        if let counts = scope.visibleCounts {
            // `?? 1`, not `?? 0`: a theme the counts have never heard of is
            // PENDING, not empty. That is what lets the previous counts stay on
            // screen while a refresh runs -- a theme added since the last probe
            // shows until its real number arrives, instead of the whole grid
            // emptying because every id changed underneath it.
            scope.themes = themes.filter { (counts[$0.id] ?? 1) > 0 }
        } else {
            // Counts not in yet. Every theme is shown, which is exactly right
            // for the ordinary library (nothing switched off, so nothing can be
            // narrowed away) and is the honest answer everywhere else: a theme
            // is not hidden until something has actually been read that says it
            // should be.
            scope.themes = themes
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

    /// Every highlight, for the two operations that genuinely need the rows
    /// rather than a count. Both run on a TAP — never on a render — so this is
    /// a one-shot fetch at the moment of use instead of a table held resident
    /// for the life of the screen.
    private func allHighlights() -> [Highlight] {
        (try? modelContext.fetch(FetchDescriptor<Highlight>())) ?? []
    }

    /// `allHighlights()` narrowed to the books currently switched on. Only
    /// `runTagMerge` reads it, and it resolves `excludedBookIDs` exactly once
    /// rather than once per highlight.
    private func scopedHighlights() -> [Highlight] {
        let all = allHighlights()
        let excluded = excludedBookIDs
        guard !excluded.isEmpty else { return all }
        return all.filter { BookSourceFilter.isVisible($0, excluding: excluded) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            if SeedingStatus.shared.isSeeding {
                // Same seed-merge guard as `BookDetailView`/`QuizHomeView` --
                // `WisdomProbe` faults `Theme.highlights` while building, which
                // is the confirmed Build-5 crash class if it lands mid
                // seed/upgrade merge. Missing here until now; a user swiping to
                // Wisdom during a merge could hit the same crash every other
                // launch-adjacent screen already guards against.
                ProgressView("Syncing your library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Wisdom Graph")
            } else {
                graphContent(makeScope())
                    // Keyed on the seed flag AND the book filter, so the counts
                    // follow a book being switched off the way the old
                    // synchronous recompute did, and re-run the moment a merge
                    // finishes rather than during one.
                    .task(id: probeKey) { await loadCounts() }
            }
        }
    }

    /// The grid's kicker. Plural by count and nothing else -- no "of", no
    /// "so far", nothing that could turn a library fact into a score.
    static func themeCountKicker(_ count: Int) -> String {
        "\(count) theme\(count == 1 ? "" : "s")"
    }

    /// What the probe's answer depends on: which books are in scope, and what
    /// the theme table currently holds.
    ///
    /// The newest `dateGenerated` and not just `themes.count`, because
    /// `WisdomGraphService.buildGraph` WIPES every `Theme` row and writes fresh
    /// ones -- so a rebuild that happens to land on the same number of themes
    /// would leave this key unchanged while every id in `visibleCounts` had
    /// just been invalidated, and the grid would sit on pending counts forever.
    /// `buildGraph` stamps each new theme `.now`, so this always moves.
    ///
    /// O(themes) per body evaluation and nothing more -- a few hundred stored
    /// `Date` reads on objects the `@Query` has already materialised. No
    /// relationship is touched, which is the whole point.
    private var probeKey: String {
        let newest = themes.map(\.dateGenerated).max() ?? .distantPast
        return "\(excludedRaw)|\(includedRaw)|\(themes.count)|\(newest.timeIntervalSince1970)|\(SeedingStatus.shared.isSeeding)"
    }

    /// Two publishes, cheapest first — `DiagnosticsView.load()`'s shape, for
    /// the same reason it has it: a screen that is drawn but has nothing to say
    /// has not opened, and the cheap half of what it has to say must not wait
    /// behind the expensive half.
    ///
    /// `@MainActor` explicitly, the way `DiagnosticsView.load` and
    /// `JournalHighlightCard.buildDeck` are: this assigns `@State`, and a bare
    /// `async` method makes no promise about which actor it resumes on
    /// (SE-0338). The probe's own methods are isolated to its `@ModelActor`, so
    /// awaiting them hops off main and only `Sendable` values come back — no
    /// `@Model` object and no `ModelContext` crosses.
    @MainActor
    private func loadCounts() async {
        // NOT cleared first. Clearing made the grid re-flow on every refresh:
        // with no counts every theme is shown, and when they land the ones
        // with nothing in them disappear -- so the screen visibly changed a
        // beat after it drew, on entry AND on every re-entry. Rajan, on the
        // shipped build: "the wisdom section entries take a little bit of
        // second to load now not right away!!!!"
        //
        // The reason it cleared was real but is handled better below: a
        // rebuild replaces every theme id, so a stale dictionary would filter
        // every theme away and empty the grid. `makeScope` now treats an id it
        // has never seen as PENDING rather than empty, so a stale dictionary
        // can only ever show too much, never too little -- and the last good
        // counts can stay on screen while the new ones are fetched.
        guard !SeedingStatus.shared.isSeeding else { return }
        let excluded = excludedBookIDs
        let container = modelContext.container
        // (61) The cache first: `TabWarmCache` ran this probe ~1.2 s after
        // launch, off the main actor, under the scope it read from the same
        // two keys, and again after every save that touched a theme or a
        // highlight. Served only when the scope matches exactly.
        if let cached = TabWarmCache.shared.wisdomCounts(for: container, excluding: excluded) {
            hasAnyVisibleHighlight = cached.hasAnyVisibleHighlight
            visibleCounts = cached.counts
            return
        }
        let generation = TabWarmCache.shared.generation
        // One probe at a time, shared with the launch warm (61): the same
        // fill that is already running is awaited, never duplicated.
        let snapshot = await TabWarmCache.shared.fillWisdom(
            container: container, excludedRaw: excludedRaw, includedRaw: includedRaw)
        if snapshot.excludedBookIDs == excluded {
            hasAnyVisibleHighlight = snapshot.hasAnyVisibleHighlight
            visibleCounts = snapshot.counts
            TabWarmCache.shared.storeWisdom(snapshot, for: container, ifGeneration: generation, verified: false)
        } else {
            // The scope moved under the fill (a source toggled mid-probe):
            // one direct read for this scope, no cache write.
            let probe = WisdomProbe(modelContainer: container)
            hasAnyVisibleHighlight = await probe.hasAnyVisibleHighlight(excluding: excluded)
            visibleCounts = await probe.visibleCounts(excluding: excluded, verifyCache: false)
        }
    }

    @ViewBuilder
    private func graphContent(_ scope: Scope) -> some View {
            ScrollView {
                VStack(spacing: 20) {
                    // Flow lives here rather than as a 6th tab — five tabs is
                    // already the ergonomic ceiling, and Wisdom is the
                    // browse-your-library tab Flow is the moving version of.
                    // `== true`, not a bare `if`: the probe's answer is
                    // three-valued. Offering an entry into Flow before anything
                    // has been read would be a claim about his library made on
                    // a guess, and yanking it back a frame later is worse than
                    // showing it a beat late.
                    if scope.hasAnyVisibleHighlight == true {
                        flowHeroCard
                    }

                    if themes.isEmpty {
                        emptyState
                    } else if scope.themes.isEmpty {
                        allBooksExcludedState
                    } else if scope.filteredThemes.isEmpty {
                        noSearchResultsState
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            // The screen's own voice, before it shows the
                            // thing -- the journal's kicker grammar, the way
                            // Library names its shelf. A fact about the
                            // graph, never about him: the number is the one
                            // `filteredThemes` already holds, said once, in
                            // small caps, in the interactive accent. Never a
                            // target, never a total to reach.
                            Text(Self.themeCountKicker(scope.filteredThemes.count))
                                .cobuxKicker(tint: .cobuxAccent, scale: .screen)
                                .monospacedDigit()
                                .accessibilityAddTraits(.isHeader)
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
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            // The tab room's ground (P9): the journal's crimson wash in dark,
            // nothing added in light.
            .cobuxRoomGround()
            .navigationTitle("Wisdom Graph")
            .searchable(text: $searchText, prompt: "Search themes")
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
            // Behind the frame, not in front of it. This was `.onAppear`, and
            // under the UIKit tab shell `.onAppear` re-fires on EVERY switch to
            // this tab -- so a blocking keychain `SecItemCopyMatching` sat in
            // the same frame as every tap on Wisdom. The key is only read by
            // the tag-merge tap; one `Task.yield()` puts the read on the turn
            // after the swap, the same fix `ChatView`'s launch `.task`
            // documents. `.task` shares `.onAppear`'s trigger, so a key added
            // or removed in Settings is still reflected on the way back.
            .task {
                await Task.yield()
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
                // A route, not a direction -- see `MoreRoute.settings`.
                Button("Open Settings") {
                    if let url = URL(string: "cobux://settings") { openURL(url) }
                }
                Button("Not Now", role: .cancel) { }
            } message: {
                Text("AI tag merging runs on Claude with your own Anthropic API key. Add it under More → Settings. The free rebuild option doesn't need one.")
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
            // Fetched at the tap. Rebuilding IS a whole-library operation --
            // it wipes and repopulates every `Theme` row from every highlight's
            // tags -- so this read is irreducible; what changed is that it now
            // happens when someone asks for a rebuild rather than every time
            // the tab is opened.
            let highlights = allHighlights()
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
        // Both reads happen at the tap, on the main actor, before anything is
        // handed to the async work below -- `@Model` objects never cross an
        // actor boundary here.
        let scoped = scopedHighlights()
        let everything = allHighlights()
        Task {
            do {
                // Scoped, unlike `buildGraph` above: this one can be a real
                // paid call priced on the tag list it's handed, and there's no
                // sense paying to tidy up tags from books that are switched
                // off and will never be displayed.
                let (mapping, madeAPICall, usedLocalAI) = try await WisdomGraphService.mergeSimilarTags(highlights: scoped, claudeService: claudeService)
                await MainActor.run {
                    isMerging = false
                    do {
                        try withAnimation(.easeInOut(duration: 0.25)) {
                            try WisdomGraphService.buildGraph(highlights: everything, modelContext: modelContext)
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

    /// The last hand-rolled empty state on this screen -- the two above it
    /// already used the shared component, and this one sat between them with a
    /// grey glyph and a `.subheadline` where a title belongs. Same shape as
    /// the journal feed's own no-matches state now.
    private var noSearchResultsState: some View {
        CobuxEmptyStateView(
            icon: "magnifyingglass",
            title: "No matches",
            message: "No theme in your graph mentions \"\(searchText)\". Try a shorter word, or clear the search to see them all."
        )
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
    }

    /// The entry into the Flow feed — deliberately the most inviting thing on
    /// this screen. Gradient, not a plain row: it's advertising a full-screen
    /// experience, and it should look like one.
    private var flowHeroCard: some View {
        Button {
            // Through ContentView's in-place overlay (60), not a cover of our
            // own: the system slide is the wait he still felt.
            NotificationCenter.default.post(name: .cobuxOpenFlow, object: nil)
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
    /// the list you actually get when you tap through once books are scoped —
    /// and so a grid of hundreds of these costs no relationship faults at all.
    /// `nil` means the count has not landed yet.
    let highlightCount: Int?

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

            // The badge is drawn at its final size either way, so the card does
            // not resize when the number arrives. An em space, not a spinner: a
            // grid of two hundred spinners is a busier screen than the one this
            // is meant to make calm.
            Text(highlightCount.map { "\($0) highlight\($0 == 1 ? "" : "s")" } ?? "\u{2003}")
                .font(.caption2)
                .fontWeight(.medium)
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.cobuxAccent.opacity(highlightCount == nil ? 0.07 : 0.15))
                .foregroundStyle(Color.cobuxAccent)
                .clipShape(Capsule())
        }
        .padding(14)
        .frame(height: 120, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cobuxCard()
    }
}

/// Reads the tag join off the main actor, in two passes: the one boolean the
/// Flow hero card needs, then the per-theme counts.
///
/// This exists because the question "how many highlights carry this theme" has
/// no `COUNT` that answers it — `Theme.highlights` is a many-to-many, and the
/// join is the only place the answer lives. The old code asked it from inside
/// `body`, once per theme, on a `.searchable` screen. The work is the same; it
/// no longer happens between a tap on the Wisdom tab and its first frame.
@ModelActor
actor WisdomProbe {
    /// Whether anything Flow could draw from exists. Every branch is a `COUNT`
    /// — no rows read, no objects registered — and the loop runs over the
    /// EXCLUDED books (normally none, at most a handful of reference texts),
    /// never over the library. A highlight belongs to at most one book, so the
    /// subtraction is exact rather than an estimate.
    func hasAnyVisibleHighlight(excluding excludedBookIDs: Set<UUID>) -> Bool {
        var visible = count(FetchDescriptor<Highlight>())
        for bookID in excludedBookIDs {
            visible -= count(FetchDescriptor<Highlight>(
                predicate: #Predicate<Highlight> { $0.book?.id == bookID }))
        }
        return visible > 0
    }

    /// Highlights per theme, narrowed to the books currently switched on.
    ///
    /// THE 58 CRASH ON THE WISDOM TAB. Build 58 asked the store this question
    /// with `#Predicate<Highlight> { $0.themes.contains { $0.name == name } }`
    /// -- a subquery through the many-to-many tag join -- so that no highlight
    /// row would be registered. His report on 58, within the hour: "clicking
    /// on the wisdom making it crash". SwiftData does not throw when it cannot
    /// translate a predicate shape; it traps inside the fetch, on whatever
    /// executor asked, and `try?` never sees it. A to-many `contains` with a
    /// nested closure is exactly such a shape. Back to the relationship read
    /// that shipped in 57: `theme.highlights` faulted HERE, on the probe's
    /// executor, never on the main actor. It costs the rows' bytes off-main;
    /// it cannot trap. The build-53 record that moved this off the main actor
    /// stands; the 58 record that swapped the read for a predicate is
    /// reversed, and says so.
    ///
    /// THE 61 SHAPE: no rows at all on the ordinary path. The count is a
    /// stored column now -- `Theme.cachedHighlightCount`, with the per-book
    /// breakdown beside it -- written by `WisdomGraphService.buildGraph`
    /// where every highlight of every theme is already in hand, so this is
    /// one fetch of small `Theme` rows and arithmetic, on every phone
    /// class. The relationship read survives as the fallback for exactly
    /// two cases: a theme row the column was never written on (built before
    /// 61), and `verifyCache` -- a highlight or book was deleted since the
    /// columns were last known true (`TabWarmCache.verificationKey`). Both
    /// paths WRITE the corrected columns back, so each runs once per theme,
    /// not once per open. Never a `#Predicate` through the tag join.
    func visibleCounts(excluding excludedBookIDs: Set<UUID>, verifyCache: Bool) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        var repaired = 0
        for theme in (try? modelContext.fetch(FetchDescriptor<Theme>())) ?? [] {
            if !verifyCache, let cached = theme.cachedVisibleHighlightCount(excluding: excludedBookIDs) {
                counts[theme.id] = cached
                continue
            }
            // The relationship read (57's and 60's path), on this executor.
            var total = 0
            var byBook: [UUID: Int] = [:]
            for highlight in theme.highlights {
                total += 1
                if let bookID = highlight.book?.id { byBook[bookID, default: 0] += 1 }
            }
            if theme.cachedHighlightCount != total || theme.cachedBookCounts != byBook {
                theme.cachedHighlightCount = total
                theme.cachedBookCounts = byBook
                repaired += 1
            }
            counts[theme.id] = theme.cachedVisibleHighlightCount(excluding: excludedBookIDs) ?? total
        }
        if repaired > 0 {
            // Behind the gate, so `TabWarmCache`'s listener reads this save
            // as the repair it is and not as a change to re-warm for.
            TabWarmCache.writeBackGate.withWriteBack {
                try? modelContext.save()
            }
        }
        return counts
    }

    /// Both stages under the scope the store itself implies, for
    /// `TabWarmCache`, which has no `@Query books` to hand
    /// `effectiveExcludedIDs`. Two columns of every `Book` (the id and the
    /// content profile the default-off rule reads), then the same two calls
    /// `WisdomGraphView.loadCounts` makes. `verifyCache` as above.
    func countsSnapshot(excludedRaw: String, includedRaw: String, verifyCache: Bool) -> WisdomCountsSnapshot {
        var books = FetchDescriptor<Book>()
        books.propertiesToFetch = [\.id, \.contentProfileRaw]
        let excluded = BookSourceFilter.effectiveExcludedIDs(
            books: (try? modelContext.fetch(books)) ?? [],
            excludedRaw: excludedRaw, includedRaw: includedRaw)
        return WisdomCountsSnapshot(
            hasAnyVisibleHighlight: hasAnyVisibleHighlight(excluding: excluded),
            counts: visibleCounts(excluding: excluded, verifyCache: verifyCache),
            excludedBookIDs: excluded)
    }

    /// One theme's lines as values, for `WisdomThemeDetailView`.
    ///
    /// Resolved by NAME (stable across a graph rebuild, where ids are not --
    /// the same reason the detail view resolves its theme by name), then read
    /// through the relationship on this executor and sorted here. Same
    /// reversal as `visibleCounts`: the 58 predicate through the tag join
    /// trapped; a relationship fault off-main cannot.
    ///
    /// The book filter is `BookSourceFilter.isVisible`'s rule applied to the
    /// snapshot: a line with no book is visible, a line whose book is
    /// switched off is not. `totalCount` is the unfiltered size, which is
    /// what lets the detail tell an empty theme from a switched-off one.
    func themeRows(named name: String, excluding excludedBookIDs: Set<UUID>) -> WisdomThemeRows {
        let themes = (try? modelContext.fetch(
            FetchDescriptor<Theme>(predicate: #Predicate<Theme> { $0.name == name }))) ?? []
        guard let theme = themes.first else { return WisdomThemeRows(totalCount: 0, visible: []) }
        let all = theme.highlights.sorted { $0.dateAdded > $1.dateAdded }

        var visible: [WisdomThemeRow] = []
        visible.reserveCapacity(all.count)
        for highlight in all {
            let book = highlight.book
            if let book, excludedBookIDs.contains(book.id) { continue }
            visible.append(WisdomThemeRow(
                id: highlight.id,
                text: highlight.text,
                chapter: highlight.chapter,
                tags: highlight.tags,
                bookID: book?.id,
                bookTitle: book?.title,
                bookCoverHex: book?.coverColorHex))
        }
        return WisdomThemeRows(totalCount: all.count, visible: visible)
    }

    private func count<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> Int {
        (try? modelContext.fetchCount(descriptor)) ?? 0
    }
}

struct WisdomThemeDetailView: View {
    /// THE CRASH ON AMAL'S PHONE, and why this view holds no model objects.
    ///
    /// Build 49, iPhone 13 Pro, 4 Sep: `EXC_BREAKPOINT` in `body`, frame 4
    /// `Theme.relatedThemeNames.getter`, frame 5 `visibleRelatedNames`. The
    /// view held `let theme: Theme` and `let allThemes: [Theme]` -- live
    /// `@Model` references -- for as long as it was pushed. `WisdomGraphService`
    /// rebuilds the graph by DELETING every Theme row and inserting fresh ones
    /// (`modelContext.delete(theme)`), so after any rebuild every one of those
    /// references pointed at a row that no longer existed, and the next body
    /// pass read a persisted property off an invalidated model. That is the
    /// Swift runtime trap, not a recoverable error. The new tab shell keeps
    /// every tab's view tree alive across tab switches, which made a pushed
    /// detail surviving a rebuild the ordinary case rather than a rare one.
    /// Three more terminations on build 56, same device, carried no log; this
    /// is the only crash class this screen has, and the fix removes it whole.
    ///
    /// So: the pushed value is used ONLY to read the theme's name at init.
    /// Everything the body needs comes back out of the store through
    /// `@Query`, which re-fetches on every store change and never hands out an
    /// invalidated instance. The theme is resolved BY NAME rather than by id
    /// on purpose: a rebuild recreates the same theme under a new UUID, so a
    /// name lookup keeps the screen working straight through the rebuild,
    /// where an id lookup would have gone blank. Themes are unique by name --
    /// the merge and the rebuild both key on it.
    private let themeName: String
    /// Carried down rather than re-derived from `@AppStorage`, so this screen
    /// and the card that pushed it can never disagree about what's in scope.
    let excludedBookIDs: Set<UUID>

    @Query private var liveThemes: [Theme]
    @Query(sort: \Theme.name) private var liveAllThemes: [Theme]
    /// For the probe's container only; no fetch happens on this context here.
    @Environment(\.modelContext) private var modelContext

    init(theme: Theme, allThemes: [Theme], excludedBookIDs: Set<UUID>) {
        // `liveAllThemes` is accepted so the two call sites do not change; it is
        // deliberately not stored. A stale list of models is the same defect
        // as a stale model.
        let name = theme.name
        self.themeName = name
        self.excludedBookIDs = excludedBookIDs
        _liveThemes = Query(filter: #Predicate<Theme> { $0.name == name })
    }

    /// The theme as the store knows it right now, or nil if a rebuild has not
    /// yet produced its successor. Nil renders a quiet notice, never a trap.
    private var liveTheme: Theme? { liveThemes.first }

    /// The theme's lines as VALUES, loaded off the main actor -- `nil` until
    /// the first load lands.
    ///
    /// This screen has been through three shapes, and the doc comment above
    /// says why the first two were wrong: live `@Model` references held across
    /// a graph rebuild trap in `body`. This third shape keeps that invariant
    /// exactly -- the theme is still resolved through `liveThemes` by name and
    /// nothing here holds a `Theme` or a `Highlight` -- and fixes what the
    /// second shape still cost:
    ///
    ///   * `prefaultBookTitles()` walked the ENTIRE `theme.highlights`
    ///     relationship on the main actor from a synchronous `.task`,
    ///     faulting every row -- text, tags, and the 2 KB embedding vector
    ///     each -- for a theme this file says can hold thousands of lines.
    ///   * `visibleHighlights()` ran in `body`: the same to-many fault plus a
    ///     full sort, on every evaluation.
    ///   * The empty-state branch faulted the relationship a second time.
    ///
    /// Now `WisdomProbe.themeRows(named:excluding:)` does one fetch on its own
    /// executor -- predicate on the theme name, sorted by `dateAdded` in the
    /// store, `book` prefetched, `embeddingData` left out -- and returns plain
    /// `WisdomThemeRow` values: id, text, chapter, tags, the book's id and
    /// title. Values cannot be invalidated by a rebuild or a deletion; a stale
    /// one reads as slightly old text, never as a trap. The book link carries
    /// the book's UUID and resolves the row only when it is opened
    /// (`WisdomBookDestination`), so no `Book` is held either.
    ///
    /// `nil` is drawn as a quiet progress indicator, not as an empty state --
    /// defect 1 in the comment above was exactly a `nil` collapsed to `[]`
    /// and shown as "Its books are switched off" on every push.
    @State private var rows: WisdomThemeRows?

    /// Bumped on every store save so the rows follow the library the way the
    /// live relationship did: delete a line from Library, come back, and it is
    /// gone here too. Folded into the `.task(id:)` key rather than firing its
    /// own `Task`, so reloads are serialised and a cancelled one never lands
    /// on top of a newer one.
    @State private var storeGeneration = 0

    /// A related theme built entirely out of switched-off books is dropped
    /// rather than shown greyed out — it isn't unavailable, it doesn't apply.
    private var visibleRelatedNames: [String] {
        let related = liveTheme?.relatedThemeNames ?? []
        guard !excludedBookIDs.isEmpty else { return related }
        return related.filter { name in
            liveAllThemes.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    var body: some View {
        ScrollView {
            // Lazy, like every other long list in this app (`BookDetailView`'s
            // two tabs, Library's grid). A plain `VStack` builds every card up
            // front, so a broad theme constructed thousands of citation cards
            // before the first frame could commit.
            LazyVStack(alignment: .leading, spacing: 16) {
                if let rows {
                    if rows.visible.isEmpty {
                        // Two different situations used to wear the same three
                        // words. A theme whose books are all switched off is
                        // not a theme with nothing in it -- the graph one
                        // screen up already draws that distinction, and the
                        // fix is a switch rather than a rebuild, so the copy
                        // must not confuse them.
                        if rows.totalCount == 0 {
                            CobuxEmptyStateView(
                                icon: "point.3.connected.trianglepath.dotted",
                                title: "Nothing under this theme",
                                message: "The highlights this theme was built from aren't in your library any more. Rebuilding the graph redraws it from what's there now."
                            )
                        } else {
                            CobuxEmptyStateView(
                                icon: "line.3.horizontal.decrease.circle",
                                title: "Its books are switched off",
                                message: "Every book behind this theme is currently switched off for Flow and the Wisdom Graph, so none of its lines can show here."
                            )
                        }
                    } else {
                        ForEach(rows.visible) { row in
                            HighlightCitationCard(row: row)
                        }
                    }
                } else {
                    // First load in flight. Says nothing about the library
                    // until it knows something about it.
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }

                if !visibleRelatedNames.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        // A kicker, not a headline: the journal never sets a
                        // bare system heading, and Ebb names its own
                        // mechanism lines exactly this way
                        // (`EbbCardViews.swift`, "Another tradition"). Same
                        // token, same scale, same accent.
                        Text("Related themes")
                            .cobuxKicker(tint: .cobuxAccent, scale: .inline)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.top, 8)

                        RelatedThemeChips(
                            names: visibleRelatedNames,
                            allThemes: liveAllThemes,
                            excludedBookIDs: excludedBookIDs
                        )
                    }
                }
            }
            .padding()
        }
        .navigationTitle(themeName)
        .navigationBarTitleDisplayMode(.inline)
        // Keyed on the NAME, which is stable across a rebuild, not on the live
        // row's id -- that would mint a fresh key on every pass while the theme
        // is absent and re-fire this task for nothing. The filter is in the
        // key so switching a book off re-scopes the list; the store generation
        // so a deletion elsewhere reaches it.
        .task(id: "\(themeName)|\(excludedBookIDs.sorted().map(\.uuidString).joined())|\(storeGeneration)") {
            await loadRows()
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
                    .receive(on: DispatchQueue.main)) { _ in
            // Not during a seed, which saves in small batches hundreds of
            // times -- `MoreView` makes the same exception. The rows are
            // re-read when the merge finishes and the key next moves.
            guard !SeedingStatus.shared.isSeeding else { return }
            storeGeneration += 1
        }
    }

    /// `@MainActor` explicitly, the way `WisdomGraphView.loadCounts` is: this
    /// assigns `@State`, and a bare `async` method makes no promise about
    /// which actor it resumes on (SE-0338). The probe's method is isolated to
    /// its `@ModelActor`, so the await hops off main and only `Sendable`
    /// values come back.
    @MainActor
    private func loadRows() async {
        // Same seed-merge guard as the graph one screen up: `WisdomProbe`
        // reads the tag join, which must never race the background merge.
        guard !SeedingStatus.shared.isSeeding else { return }
        let probe = WisdomProbe(modelContainer: modelContext.container)
        let loaded = await probe.themeRows(named: themeName, excluding: excludedBookIDs)
        guard !Task.isCancelled else { return }
        rows = loaded
    }
}

/// One line under a theme, as a value. Everything the citation card draws,
/// and nothing that can be invalidated.
struct WisdomThemeRow: Identifiable, Sendable, Equatable {
    let id: UUID
    let text: String
    let chapter: String?
    let tags: [String]
    /// The owning book, by id only -- resolved to a row when the link is
    /// opened, never held here.
    let bookID: UUID?
    let bookTitle: String?
    /// The book's own cover colour, as the hex it is stored as -- for the
    /// spine on the citation card. A string and not a `Color`, so the value
    /// stays `Sendable` and crosses back from the probe like everything else
    /// here.
    let bookCoverHex: String?
}

/// A theme's lines, scoped to the books switched on, plus how many the theme
/// holds in all -- the second number is what tells "nothing under this theme"
/// apart from "its books are switched off".
struct WisdomThemeRows: Sendable, Equatable {
    let totalCount: Int
    let visible: [WisdomThemeRow]
}

private struct HighlightCitationCard: View {
    let row: WisdomThemeRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\"\(row.text)\"")
                .font(.body)
                .italic()

            if let bookID = row.bookID, let bookTitle = row.bookTitle {
                NavigationLink(destination: WisdomBookDestination(bookID: bookID)) {
                    HStack(spacing: 4) {
                        // The book's spine, in its own cover colour -- the
                        // same 4pt mark `QuizBookRow` sets beside a title and
                        // Library's list row now carries, so "this line
                        // belongs to that book" is drawn one way everywhere.
                        // Content owns its hue; the link stays violet. A
                        // static fill, no per-frame cost.
                        if let hex = row.bookCoverHex {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(hex: hex))
                                .frame(width: 4, height: 14)
                                .padding(.trailing, 2)
                                .accessibilityHidden(true)
                        }
                        Image(systemName: "book.closed.fill")
                            .font(.caption2)
                        Text(bookTitle)
                        if let chapter = row.chapter, !chapter.isEmpty {
                            Text("· \(chapter)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Color.cobuxAccent)
                }
            } else if let chapter = row.chapter, !chapter.isEmpty {
                Text(chapter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !row.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(row.tags, id: \.self) { tag in
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

/// Resolves a book by id at the moment it is opened, through `@Query`, so the
/// citation card above never holds a `Book`. The same reason the theme is
/// resolved by name through `liveThemes`: a model held across a store change
/// is the trap on Amal's phone. A book deleted between the card being drawn
/// and the link being tapped renders a quiet notice, never a trap.
private struct WisdomBookDestination: View {
    @Query private var books: [Book]

    init(bookID: UUID) {
        _books = Query(filter: #Predicate<Book> { $0.id == bookID })
    }

    var body: some View {
        if let book = books.first {
            BookDetailView(book: book)
        } else {
            CobuxEmptyStateView(
                icon: "book.closed",
                title: "This book isn't here any more",
                message: "It was removed from your library after this theme was drawn. Rebuilding the graph redraws it from what's there now."
            )
        }
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
