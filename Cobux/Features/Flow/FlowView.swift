import SwiftUI
import SwiftData

/// The Flow feed — a full-screen, vertically-paging stream of cards from the
/// user's own library (quotes, chapter lessons, quick self-tests, weak-topic
/// callouts, and the occasional cross-book resonance find).
/// Presented from the Wisdom tab via `fullScreenCover`. iOS 17 paging APIs
/// (`scrollTargetBehavior(.paging)` on a `LazyVStack` of
/// `containerRelativeFrame` pages) — deliberately not the rotated-TabView
/// hack. Infinite: nearing the end appends the next deterministic batch from
/// `FlowQueueBuilder`.
struct FlowView: View {
    /// A positioned card. Cards legitimately repeat across batches (a small
    /// library's pools cycle — that's the feed staying infinite, not a bug),
    /// so `ForEach` identity comes from the feed position, not the card alone.
    private struct FeedItem: Identifiable {
        let id: String
        let card: FlowCard
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Query private var books: [Book]
    /// NEVER traverse a Book's relationships (highlights, chapters,
    /// quizQuestions) while a background seed/upgrade merge is in flight --
    /// the confirmed Build-5 crash class (see `BookCard`'s doc comment):
    /// SwiftData can assert resolving relationship members mid-merge. Flow's
    /// entire card pipeline (`FlowQueueBuilder.buildBatch`, the resonance
    /// snapshot below) is exactly that kind of traversal, and unlike
    /// `BookCard` it wasn't gated at all -- reachable the instant the app
    /// launches for a RETURNING user (whose `@Query`-backed `highlights`
    /// already has data from last session, so Wisdom's Flow hero card is
    /// tappable immediately), which is precisely the mutating-merge window a
    /// same-day book seed or repair pass runs on every launch.
    private let seedingStatus = SeedingStatus.shared

    /// Which books Flow may draw from — shared with the Wisdom Graph, see
    /// `BookSourceFilter`. Read as `@AppStorage` (not the static accessor) so
    /// flipping a book in the picker actually re-renders this view and
    /// re-deals the feed.
    @AppStorage(BookSourceFilter.excludedKey) private var excludedRaw: String = ""
    @AppStorage(BookSourceFilter.includedKey) private var includedRaw: String = ""
    @State private var showingSourcePicker = false

    @State private var items: [FeedItem] = []
    @State private var visibleItemID: String?
    @State private var nextBatch = 0
    /// Fresh per presentation (the fullScreenCover builds a new FlowView each
    /// open, so @State re-initializes): every open of Flow deals a different
    /// feed, while re-renders within one session keep the cards stable.
    @State private var seedBase = UInt64.random(in: UInt64.min...UInt64.max)
    @State private var stats = FlowSessionStats()
    /// Feed positions already counted into stats — scrolling back to re-read
    /// a card must not inflate the recap numbers.
    @State private var settledItemIDs: Set<String> = []
    /// Recap numbering/rhythm state threaded across batches.
    @State private var batchContinuation = FlowQueueBuilder.BatchContinuation()
    /// Cross-book resonance pairs, computed once per session off the scroll
    /// path from the embeddings the library already stores.
    @State private var resonancePairs: [(Highlight, Highlight)] = []
    @State private var resonanceReady = false
    /// The visible card's accent — drives the shared atmosphere layer so the
    /// background melts from one book's color to the next mid-swipe instead
    /// of hard-cutting at every page boundary.
    @State private var atmosphereHex = "#6366F1"
    /// Grading a quick-check card in here can cross a streak milestone, and
    /// ContentView's celebration overlay lives UNDER this `fullScreenCover` —
    /// so Flow hosts its own copy of the overlay rather than letting the
    /// celebration ambush the user only after they close the feed.
    @State private var celebrationCenter = StreakCelebrationCenter.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            atmosphere

            if items.isEmpty {
                if seedingStatus.isSeeding {
                    settingUpState
                } else if everythingExcluded {
                    allBooksExcludedState
                } else {
                    emptyState
                }
            } else {
                feed
            }

            // The page itself never named itself -- every card carries its
            // own kicker ("From your library", "Two books, one idea"...) but
            // nothing said "this is Flow," unlike ChatView's own COBUX
            // wordmark. Sits above the per-card kicker's own top padding (68pt)
            // with clear room between them, at the same corner height as the
            // filter/close controls opposite it.
            Text("FLOW")
                .font(.caption.weight(.bold))
                .kerning(3)
                .foregroundStyle(.white.opacity(0.55))
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            HStack(spacing: 0) {
                Button {
                    showingSourcePicker = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .padding(16)
                }
                .accessibilityLabel("Choose which books Flow uses")

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .padding(16)
                }
                .accessibilityLabel("Close Flow")
            }

            // Flow is the front door now (opens on every launch) -- without an
            // explicit way deeper into the app, it would be a dead end rather
            // than an entry point. Reuses the same `cobux://chat` self-link
            // `ContentView.onOpenURL` already routes on the widget's cold-launch
            // path, instead of inventing a second app-to-app coupling for the
            // same "go to the Chat tab" action.
            //
            // Sized and labeled as a real doorway out of Flow, not a small
            // utility action: "Open Cobux" names what's on the other side of
            // the tap (the whole app) rather than just one of its features,
            // and the accent-tinted capsule (`cobuxAccent`, the one fixed
            // brand color -- see `CobuxColor`) matches the same pill-button
            // language the cards' own Go Deeper/Share use, instead of a flat
            // gray material that read as disconnected from everything else
            // on screen while the cards' own colors change underneath it.
            //
            // `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment:
            // .bottom)` overrides this ZStack's own `.topTrailing` default for
            // just this one element -- without it, a plain child sizes to its
            // own content (the button) and the outer alignment would pin it to
            // the top-trailing corner instead of bottom-center.
            Button {
                dismiss()
                openURL(URL(string: "cobux://chat")!)
            } label: {
                Label("Open Cobux", systemImage: "message.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 16)
                    .background(Color.cobuxAccent, in: Capsule())
            }
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .overlay {
            if let milestone = celebrationCenter.milestone {
                MilestoneCelebrationView(days: milestone) {
                    celebrationCenter.dismiss()
                }
                .transition(.opacity)
            }
        }
        .environment(stats)
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
            if items.isEmpty {
                appendBatch()
                // Opening Flow -- now the very first thing a launch shows --
                // is itself real engagement: seeing a highlight and reflecting
                // on it, exactly the bar Rajan wanted the streak to clear.
                // Deliberately in addition to, not instead of, the existing
                // quiz/highlight/journal triggers elsewhere -- this removes
                // the felt PRESSURE to quiz for a streak without taking any
                // existing path to one away.
                StreakTracker.recordActivityToday()
            }
        }
        // Changing which books Flow draws from mid-session has to re-deal the
        // feed: cards from a just-excluded book are already built and sitting
        // a few swipes below, and leaving them there makes the setting look
        // broken.
        .onChange(of: sourceSignature) { _, _ in
            redealFeed()
        }
        // `appendBatch`/`computeResonancePairs` both no-op while seeding --
        // retry the instant it ends, or a Flow opened mid-merge would sit on
        // `settingUpState` forever (its own onAppear already ran and won't
        // fire again).
        .onChange(of: seedingStatus.isSeeding) { wasSeeding, isSeeding in
            guard wasSeeding, !isSeeding else { return }
            if items.isEmpty {
                appendBatch()
            }
            if !resonanceReady {
                Task { await computeResonancePairs() }
            }
        }
        // Keyed on the filter, not a bare `.task`: the pair snapshot is taken
        // from the included books once per session, so switching a book back
        // ON mid-session would otherwise leave it unable to produce a
        // resonance card until Flow was closed and reopened. `buildBatch`
        // already drops pairs touching an excluded book, so this is the
        // re-inclusion half of the same rule.
        .task(id: sourceSignature) {
            await computeResonancePairs()
        }
    }

    /// Both halves of the source filter as one value. Switching a book back ON
    /// writes the *inclusion* key, not the exclusion key, so watching only the
    /// latter would leave a re-included book unable to reach the feed until
    /// Flow was closed and reopened — the re-inclusion half of the same rule
    /// the resonance snapshot below already documents.
    private var sourceSignature: String { excludedRaw + "|" + includedRaw }

    private var excludedBookIDs: Set<UUID> {
        BookSourceFilter.effectiveExcludedIDs(books: books, excludedRaw: excludedRaw, includedRaw: includedRaw)
    }

    /// Books the feed is actually allowed to use. `FlowQueueBuilder` applies
    /// the same filter itself — this copy exists for the resonance snapshot
    /// (which is computed here, outside the builder) and for the empty state.
    private var flowBooks: [Book] {
        excludedBookIDs.isEmpty ? books : books.filter { !excludedBookIDs.contains($0.id) }
    }

    /// Distinct from "your library is empty" — the fix is a switch, not an
    /// import, and telling someone to add a book when they have twelve would
    /// read as the app being broken.
    private var everythingExcluded: Bool { !books.isEmpty && flowBooks.isEmpty }

    /// One shared, animated background under the whole feed — cards
    /// themselves are transparent. The 0.6s ease means a swipe from a blue
    /// book to an orange one produces a visible color melt mid-transition,
    /// which is what makes the feed read as one living surface instead of
    /// forty stapled screens.
    private var atmosphere: some View {
        let accent = Color(hex: atmosphereHex)
        return LinearGradient(
            colors: [accent.opacity(0.22), Color(.systemBackground), accent.opacity(0.08)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: atmosphereHex)
    }

    private var feed: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    FlowCardView(card: item.card)
                        .containerRelativeFrame(.vertical)
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $visibleItemID)
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .bottom)
        // The settle tick: one soft haptic exactly when a card clicks into
        // the paging detent — half of a good feed's physical grip. The
        // condition skips the very first settle (nil -> first card at feed
        // open), which is presentation, not a gesture.
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: visibleItemID) { oldValue, _ in
            oldValue != nil
        }
        .onChange(of: visibleItemID) { _, newID in
            guard let newID, let index = items.firstIndex(where: { $0.id == newID }) else { return }
            let card = items[index].card
            atmosphereHex = card.accentHex
            // Count each feed position exactly once — revisits don't inflate
            // the recap numbers.
            if settledItemIDs.insert(newID).inserted {
                stats.recordSettled(on: card)
                // Only a genuinely-settled highlight counts as "shown" for
                // `FlowRecentlyShownStore` -- one that scrolled past
                // unseen shouldn't bias a future session away from it.
                if case .highlight(let highlight) = card {
                    FlowRecentlyShownStore.recordShown(highlight.id)
                }
            }
            // Append before the user can reach the end — 5 cards of runway.
            // Deferred one runloop turn so the batch build (full-library
            // flatMaps) never lands on the same frame as the settle haptic
            // and atmosphere cross-fade.
            if index >= items.count - 5 {
                Task { @MainActor in
                    appendBatch()
                }
            }
        }
    }

    /// Shown instead of `emptyState` while a background seed/upgrade merge is
    /// in flight -- "Nothing to flow through yet, add a book" would be an
    /// outright false thing to tell someone whose library the app is
    /// actively populating right now.
    private var settingUpState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(seedingStatus.message)
                .font(.headline)
            Text("Flow will fill in the moment your library finishes setting up.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "water.waves")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Nothing to flow through yet")
                .font(.headline)
            Text("Add a book or a few highlights and Flow will turn your library into a feed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var allBooksExcludedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Every book is switched off")
                .font(.headline)
            Text("Flow draws from the books you choose. Switch at least one back on and the feed fills right back up.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Choose Books") { showingSourcePicker = true }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Rebuilds the feed from card zero under a new book selection. Recap
    /// numbering, the settled-position ledger and the session tallies all
    /// reset together — feed-item IDs restart at batch 0, so a stale
    /// `settledItemIDs` would collide with fresh positions and silently stop
    /// counting them, and recap numbers would resume mid-sequence over a feed
    /// that just started over.
    private func redealFeed() {
        items.removeAll()
        visibleItemID = nil
        settledItemIDs.removeAll()
        batchContinuation = FlowQueueBuilder.BatchContinuation()
        stats = FlowSessionStats()
        nextBatch = 0
        appendBatch()
    }

    private func appendBatch() {
        // See the `seedingStatus` doc comment up top: `buildBatch` faults
        // every book's highlights/chapters/quizQuestions, which must never
        // race a background merge. The `seedingStatus.isSeeding` onChange
        // above retries this the moment it's safe.
        guard !seedingStatus.isSeeding else { return }
        let batch = FlowQueueBuilder.buildBatch(
            books: books,
            batch: nextBatch,
            seedBase: seedBase,
            resonancePairs: resonanceReady ? resonancePairs : [],
            excludedBookIDs: excludedBookIDs,
            continuation: &batchContinuation,
            recentlyShownIDs: FlowRecentlyShownStore.recentIDs()
        )
        guard !batch.isEmpty else { return }
        let positioned = batch.enumerated().map { offset, card in
            FeedItem(id: "\(nextBatch)-\(offset)-\(card.id)", card: card)
        }
        items.append(contentsOf: positioned)
        nextBatch += 1
        pruneDistantHistory()
    }

    /// A marathon session must not grow `items` (and the LazyVStack's
    /// retained children, and the per-settle firstIndex scan) forever on a
    /// 4GB device. Prunes only when far past the kept window; the
    /// scrollPosition binding re-anchors the visible id, and 80 cards of
    /// back-scroll history is more than anyone rewinds through.
    private func pruneDistantHistory() {
        guard items.count > 200,
              let visibleItemID,
              let index = items.firstIndex(where: { $0.id == visibleItemID }),
              index > 120 else { return }
        items.removeFirst(index - 80)
    }

    /// Snapshot (id, bookID, embedding) as plain values on the MainActor,
    /// score the pairs off it, then map winners back to Highlights — SwiftData
    /// models never cross the thread boundary. Comparing stored embeddings is
    /// free; nothing here creates one.
    private func computeResonancePairs() async {
        // Same merge-race guard as `appendBatch` -- `flowBooks.flatMap(\.highlights)`
        // below is exactly the relationship fault that must not race a
        // background seed/upgrade merge.
        guard !seedingStatus.isSeeding else { return }
        // `flowBooks`, not `books` — this snapshot feeds both the builder AND
        // the spliced first-session gold card below, and the splice bypasses
        // `FlowQueueBuilder` entirely, so filtering only inside the builder
        // would leak an excluded book's quote onto the one card most likely
        // to be noticed.
        let allHighlights = flowBooks.flatMap(\.highlights)
        // .shuffled() before the lazy chain, not after: relationship order is
        // stable across sessions, so the un-shuffled version of this always
        // sampled the exact same first 120 highlights for resonance pairing
        // every single time -- the same day-to-day repetition class 2.5.10
        // already fixed for ordinary highlight cards, just missed here.
        // Shuffling the plain `[Highlight]` array is a cheap reference
        // reorder; it happens BEFORE `.lazy`, so it doesn't change which
        // property (`.lazy`) is doing the real work below: only the 120 kept
        // candidates pay the Data->[Float] decode — an eager compactMap
        // would decode EVERY embedded highlight on the main actor at feed
        // open just to throw most of them away.
        let candidates: [(id: UUID, bookID: UUID, embedding: [Float])] = Array(
            allHighlights.shuffled().lazy
                .compactMap { highlight -> (id: UUID, bookID: UUID, embedding: [Float])? in
                    guard let bookID = highlight.book?.id, let embedding = highlight.embedding else { return nil }
                    return (highlight.id, bookID, embedding)
                }
                .prefix(120)
        )

        let pairIDs = await Task.detached(priority: .utility) {
            FlowQueueBuilder.resonancePairs(from: candidates)
        }.value

        let byID = Dictionary(allHighlights.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        resonancePairs = pairIDs.compactMap { a, b in
            guard let first = byID[a], let second = byID[b] else { return nil }
            return (first, second)
        }
        resonanceReady = true

        // Batch 0 built before the pairs existed — splice one gold card a
        // few swipes ahead so the first session still gets its resonance
        // moment instead of deferring it 40 cards out.
        if nextBatch == 1, let pair = resonancePairs.first {
            let card = FlowCard.resonance(pair.0, pair.1)
            let currentIndex = visibleItemID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
            let insertAt = min(items.count, currentIndex + 6)
            items.insert(FeedItem(id: "spliced-\(card.id)", card: card), at: insertAt)
            resonancePairs.removeFirst()
        }
    }
}
