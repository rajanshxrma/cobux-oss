import SwiftUI
import SwiftData
import WidgetKit

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
    @Environment(\.modelContext) private var flowModelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    /// Today's journal echo -- his own writing, never mixed into the library --
    /// resolved at most ONCE per open (see `journalEchoForToday`), not once per
    /// batch. It used to be recomputed inside every `appendBatch` over a
    /// `@Query` of the entire journal, faulting every entry's text on the
    /// main actor every forty cards, from a scroll-triggered callback -- for a
    /// value the builder only reads for batch 0.
    @State private var journalEcho: (entryID: UUID, date: Date, passage: String)?
    @State private var journalEchoResolved = false
    /// Read-only echo of the journal's lock, so Flow can refuse to quote his
    /// writing while it is locked. The gate itself stays in `JournalLocked`
    /// -- and the echo card now wears it too, at render time, so a lock that
    /// re-engages after the deal re-gates the card already on screen.
    @AppStorage(JournalLockStatus.enabledKey) private var journalLockEnabled = true
    @State private var journalLockStatus = JournalLockStatus.shared
    /// Set when a batch was wanted while the scene was not active, so the work
    /// happens on the next activation instead of being lost.
    @State private var batchDeferredUntilActive = false
    /// Has a batch build actually run to completion yet?
    ///
    /// Without this, `items.isEmpty` conflates two entirely different states:
    /// "there is nothing to show you" and "I have not looked yet". Flow opened
    /// on "Nothing to show" for the moment before the first batch finished --
    /// telling him his library was empty when it holds twenty-six books. An
    /// empty state is a claim about his data and must never be guessed.
    @State private var hasBuiltFirstBatch = false
    @Environment(\.openURL) private var openURL
    /// Reduce Motion is a hard gate (`CobuxMotion`). The scaffold and the
    /// launch button already honour it; the opening rise below did not, so the
    /// very first motion of the surface Flow opens on ignored the setting.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var books: [Book]
    /// NEVER traverse a Book's relationships (highlights, chapters,
    /// quizQuestions) while a background seed/upgrade merge is in flight --
    /// the confirmed Build-5 crash class (see `BookCard`'s doc comment):
    /// SwiftData can assert resolving relationship members mid-merge. Flow's
    /// card pipeline no longer walks to-many relationships (`fetchPools` reads
    /// rows through bounded fetches), but every card still resolves `book` and
    /// `chapter` to-one members and the resonance snapshot reads the store, so
    /// the gate stays. Unlike `BookCard` it wasn't gated at all -- reachable the instant the app
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
    /// Folded into the Sources sheet so its "Show hidden highlights again" row
    /// appears the moment a card is hidden and leaves when they are shown
    /// again -- see `FlowSuppressionSignal`.
    @State private var suppressionSignal = FlowSuppressionSignal.shared

    @State private var items: [FeedItem] = []
    @State private var visibleItemID: String?
    @State private var nextBatch = 0
    /// A batch build is already enqueued on the main actor. Two uncoordinated
    /// triggers used to enqueue one each at open -- `onAppear` after dealing
    /// the instant card, and the runway check the instant card's own settle
    /// fired -- so batch 0 AND batch 1 were built back to back, synchronously,
    /// behind the first card. See `scheduleBatch`.
    @State private var batchScheduled = false
    /// The source-filter signature the feed was last dealt under. Nil until
    /// the first `.task(id: sourceSignature)` run, which is the open itself
    /// and must not redeal.
    @State private var appliedSourceSignature: String?
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
                } else if !hasBuiltFirstBatch {
                    // Not "nothing here" -- "not yet". Quiet by design: a
                    // spinner announcing a wait that is usually a few hundred
                    // milliseconds draws more attention to it than it deserves.
                    loadingState
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
                // `.secondary`, not white-at-55%: the light-mode atmosphere is
                // the accent at 0.22 over white, so a translucent white
                // wordmark was invisible on it -- visible in his screenshot as
                // a "FLOW" you can barely read. This is correct in both themes.
                .foregroundStyle(.secondary)
                .padding(16)
                // Centered, not top-leading: it's the page's own wordmark, and
                // the top-left corner also sat directly above each card's
                // kicker, reading as a second stray label rather than a title.
                // The filter/close controls keep the trailing corner, so the
                // center is genuinely free.
                .frame(maxWidth: .infinity, alignment: .top)

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

            // Flow's one-time hint, under the wordmark on the first open.
            // Floated, not stacked: every card is full-screen and this
            // surface's layout is signed off, so nothing here may move it.
            // Gone on the first real swipe (`markUsed` in the settle handler
            // below) or a tap on its close -- whichever comes first.
            if !items.isEmpty {
                CobuxFeatureTipHost(firstOf: [.flow])
                    .padding(.horizontal, CobuxSpacing.screenMargin)
                    .padding(.top, 52)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        // No bottom safeAreaInset any more, and no global "Open Cobux".
        //
        // It lived here because Flow needed a way into chat, and the card
        // footers did not have one yet. Once they did, the app had two: this
        // one, opening the generic chat tab, and each card's own, opening chat
        // WITH the highlight. Both dismissed Flow. Stacked, they read as two
        // competing primaries, which is what survived after the spacing fix
        // that he confirmed worked ("the open Cobux position is much better
        // but still congested"). The sixth report of this area was about count,
        // not position, so the answer is one fewer control -- not smaller ones.
        //
        // The button is not gone; it moved onto the cards, keeping its name,
        // its icon and its prominence, and gaining the highlight as payload.
        // The four status-type cards (daily opener, weak topic, session recap,
        // resonance) deliberately do not get one: their own footers already say
        // what to do next, and a chat exit under "Swipe up to begin" argues
        // with the card it sits on. Closing Flow still reaches chat from there.
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
                    // The reverse of a card's "Don't show this again", on
                    // Flow's one settings surface. A plain row, present only
                    // while there is something to show again, and gone the
                    // moment it is tapped -- no count of what he hid, no
                    // confirmation. `safeAreaInset`, not an overlay: the Form
                    // above shortens to make room, so its last toggle can
                    // never sit under this row.
                    .safeAreaInset(edge: .bottom) {
                        // Reading `revision` is what subscribes this body to
                        // the signal; the value itself is not information.
                        let _ = suppressionSignal.revision
                        if FlowSuppression.hasSuppressions {
                            Button {
                                FlowSuppression.clearAll()
                            } label: {
                                Label("Show hidden highlights again", systemImage: "eye")
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, CobuxSpacing.pillV)
                                    .cobuxGlassTranslucent(shape: RoundedRectangle(cornerRadius: CobuxRadius.card))
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, CobuxSpacing.screenMargin)
                            .padding(.vertical, CobuxSpacing.sm)
                        }
                    }
            }
        }
        .onAppear {
            if items.isEmpty {
                // BEFORE `appendBatch()`, not after. The batch builds the daily
                // opener card from the streak, so recording the day afterwards
                // meant the card was rendered from yesterday's count and
                // disagreed with More and Quiz by one.
                StreakTracker.recordActivityToday()
                // Deal ONE card instantly, then build the real batch behind it.
                //
                // Rajan photographed the opening screen -- a pale gradient, a
                // small glyph and "Gathering your highlights…" -- and said it
                // was "unacceptalble at opening". He was right, and the wait
                // turned out to be an artifact rather than a necessity: on a
                // cold launch the scene is not `.active` when this fires, so
                // `appendBatch` defers, the loading frame commits to screen,
                // and when the scene does activate the builder cold-faults the
                // ENTIRE library on the main actor -- every book's highlights,
                // chapters and quiz questions -- to deal forty cards.
                //
                // The first card needs one readable highlight from one book.
                // So deal that from at most six books, paint it, and let the
                // heavy build happen one runloop later behind something he is
                // already reading. The freeze still exists; it is no longer
                // the first thing he sees.
                if let instant = dealInstantCard() {
                    atmosphereHex = instant.accentHex
                    // The opening breath: the first card rises into place
                    // instead of appearing -- a hard cut into a surface this
                    // composed read as a glitch, not an arrival. Shortened,
                    // not removed, under Reduce Motion: the arrival still
                    // wants to be an arrival, it just stops being a rise.
                    withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.45)) {
                        items = [FeedItem(id: "instant-\(instant.id)", card: instant)]
                    }
                    if case .highlight(let highlight) = instant {
                        FlowRecentlyShownStore.recordShown(highlight.id)
                    }
                    scheduleBatch()
                } else {
                    appendBatch()
                }
                // Opening Flow -- now the very first thing a launch shows --
                // is itself real engagement: seeing a highlight and reflecting
                // on it, exactly the bar Rajan wanted the streak to clear.
                // Deliberately in addition to, not instead of, the existing
                // quiz/highlight/journal triggers elsewhere -- this removes
                // the felt PRESSURE to quiz for a streak without taking any
                // existing path to one away.
            }
        }
        // Closing Flow mid-celebration used to leave the milestone pending --
        // StreakCelebrationCenter.dismiss() only ran from the overlay's own
        // "Keep Going" tap, so a fresh FlowView built on the next open re-read
        // the still-set milestone and showed the exact same celebration
        // again. Leaving Flow now always finalizes an in-progress one; a
        // no-op when nothing's pending (clearPendingMilestone on an absent
        // key is a plain removeObject).
        .onDisappear {
            celebrationCenter.dismiss()
        }
        // The source filter's side effects (redeal, widget sync, resonance
        // snapshot) all live in ONE debounced `.task(id: sourceSignature)` at
        // the bottom of this chain -- see there.
        //
        // `appendBatch`/`computeResonancePairs` both no-op while seeding --
        // retry the instant it ends, or a Flow opened mid-merge would sit on
        // `settingUpState` forever (its own onAppear already ran and won't
        // fire again).
        .onChange(of: scenePhase) { _, phase in
            // Pick up a batch that was skipped because the scene was not
            // active. Without this, deferring above would simply lose it and
            // Flow would open empty.
            guard phase == .active, batchDeferredUntilActive else { return }
            appendBatch()
        }
        .onChange(of: seedingStatus.isSeeding) { wasSeeding, isSeeding in
            guard wasSeeding, !isSeeding else { return }
            if items.isEmpty {
                appendBatch()
            }
            if !resonanceReady {
                Task { await computeResonancePairs() }
            }
        }
        // Everything the book-source filter touches, in one place, debounced.
        //
        // First run (the open itself): seed the widget's copy of the filter,
        // so an install that set it before this shipped doesn't wait for the
        // next toggle to sync, and take the resonance snapshot. Keyed on the
        // filter, not a bare `.task`: the pair snapshot is taken from the
        // included books once per session, so switching a book back ON
        // mid-session would otherwise leave it unable to produce a resonance
        // card until Flow was closed and reopened. `buildBatch` already drops
        // pairs touching an excluded book, so this is the re-inclusion half of
        // the same rule.
        //
        // Every later run is a toggle in the picker. Changing which books Flow
        // draws from mid-session has to re-deal the feed: cards from a
        // just-excluded book are already built and sitting a few swipes below,
        // and leaving them there makes the setting look broken. But this used
        // to be an `.onChange` that redealt SYNCHRONOUSLY on every single
        // Toggle -- a full-library rebuild, a resonance recompute and a widget
        // timeline reload on the main actor, per flip, while the sheet was
        // still up. `.task(id:)` cancels the previous run when the id changes,
        // so rapid toggles cancel each other and only the SETTLED selection
        // pays for a redeal. Toggling a book off and straight back on lands on
        // the signature the feed already has and costs nothing at all.
        .task(id: sourceSignature) {
            guard let applied = appliedSourceSignature else {
                appliedSourceSignature = sourceSignature
                BookSourceSharing.publish(excludedBookIDs)
                // The open's resonance snapshot is NOT taken here. It used to
                // be, and this task fires the instant Flow appears -- so the
                // probe's COUNT over the whole highlight table, its large
                // OFFSET and its 1,200-row read ran CONCURRENTLY with batch
                // 0's build on the main actor. SwiftData's coordinator
                // serialises store access, so the two contended for the lock
                // while the first card was rising (the contention the
                // `warmFlowRowCache` note below documents). The snapshot now
                // waits for batch 0: see `.task(id: hasBuiltFirstBatch)`.
                return
            }
            guard applied != sourceSignature else { return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            appliedSourceSignature = sourceSignature
            redealFeed()
            // Keep the widget's copy honest -- it runs in its own process and
            // can't see `UserDefaults.standard`, which is why books switched
            // off here kept showing up there.
            BookSourceSharing.publish(excludedBookIDs)
            WidgetCenter.shared.reloadAllTimelines()
            await computeResonancePairs()
        }
        // The open's resonance snapshot, AFTER the first batch exists.
        //
        // Nothing about Flow's first frame or its first forty cards needs the
        // pairs: `resonanceReady` gates every reader, and `computeResonancePairs`
        // already splices one gold card into the live feed when it finishes
        // during batch 0's lifetime. Keying on `hasBuiltFirstBatch` (set by
        // `appendBatch`'s defer, so never by a deferred-until-active build)
        // is what puts the probe's store reads behind the build instead of
        // beside it. The mid-seed case stays with the `isSeeding` onChange
        // above, which retries the snapshot the moment the merge ends.
        .task(id: hasBuiltFirstBatch) {
            guard hasBuiltFirstBatch, !resonanceReady else { return }
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

    /// Whether the journal is locked right now. Read at DEAL time so a locked
    /// journal means no echo, silently -- the card simply is not dealt, which
    /// is already its normal state on most days. The card itself wears the
    /// same rule at render time (`JournalEchoFlowCard` is wrapped in
    /// `JournalLocked`), because a deal is a decision made once and the lock
    /// is a state that changes underneath it.
    private var journalIsLocked: Bool { journalLockEnabled && !journalLockStatus.isUnlocked }

    /// An entry written on this calendar date in an earlier year.
    ///
    /// Selected here rather than in the builder so the builder stays pure. Uses
    /// the journal's own guards, not Flow's: the 14-day floor (fresh writing is
    /// a wound), the excluded-phrase list, and the same passage scoring, so a
    /// fragment that could embarrass him can no more appear here than on the
    /// journal card. Returns nil far more often than not, and that is correct —
    /// most days have no echo, and none of them should say so.
    ///
    /// Bounded on purpose. The old version filtered a `@Query` of the ENTIRE
    /// journal and tested each entry's text (the quiet-words scan) BEFORE its
    /// date, so every call faulted every entry's body -- 1,500 bodies on the
    /// main actor, every batch. This one fetches a projection of two columns
    /// (`id`, `modifiedDate`), decides on the date first, and touches `text`
    /// only for the handful of entries actually written on this calendar
    /// date. Called once per open, from batch 0 (see `appendBatch`).
    private func journalEchoForToday() -> (entryID: UUID, date: Date, passage: String)? {
        let calendar = Calendar.current
        let today = calendar.dateComponents([.month, .day], from: .now)
        guard let floor = calendar.date(byAdding: .day,
                                        value: -JournalHighlightSelector.minimumAgeDays,
                                        to: .now) else { return nil }
        var descriptor = FetchDescriptor<PersonalWritingEntry>()
        descriptor.propertiesToFetch = [\.id, \.modifiedDate]
        guard let entries = try? flowModelContext.fetch(descriptor) else { return nil }
        // A permanently silenced entry may never resurface, on any surface.
        let suppressed = EbbSuppressionStore.suppressedIDs()
        // An entry whose date is unknown (`modifiedDate == nil`) can never be
        // "this day in an earlier year", so it is out before anything else.
        let matches: [(entry: PersonalWritingEntry, date: Date)] = entries.compactMap { entry in
            guard let date = entry.modifiedDate, date < floor else { return nil }
            let parts = calendar.dateComponents([.month, .day], from: date)
            guard parts.month == today.month, parts.day == today.day else { return nil }
            guard !suppressed.contains(entry.id) else { return nil }
            return (entry, date)
        }
        for (entry, date) in matches.sorted(by: { $0.date > $1.date }) {
            // Only here does an entry's body get read.
            let text = entry.text
            guard JournalHighlightSelector.maySurface(text) else { continue }
            let body = JournalHighlightSelector.stripStamp(text)
            let standalone = Set(body.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) })
            if let passage = JournalHighlightSelector.best(
                from: JournalHighlightSelector.candidates(in: text),
                standaloneLines: standalone) {
                return (entry.id, date, passage)
            }
        }
        return nil
    }

    /// One highlight, cheaply, for the very first frame.
    ///
    /// Single-row draws, never a relationship fault. The previous version
    /// read `book.highlights` for up to six random books "instead of all 54"
    /// -- but this library's books average 206 highlights (the largest ~580),
    /// each row carrying a 2 KB embedding blob, so the cheap path was itself
    /// faulting up to a thousand-plus managed objects onto the main actor
    /// before the first frame. That is the "it used to be super fast the
    /// moment it opens" he lost. Now: for each of at most six random books,
    /// one indexed `COUNT` (cached for the session, see `highlightCount(in:)`)
    /// and one `fetchLimit = 1` read at a seeded offset inside that book --
    /// twelve tiny SELECTs at worst, no blob but the one row's.
    ///
    /// Honours the same two rules the full builder does, because breaking
    /// either would undo a fix he already reported: `readsStandalone` keeps out
    /// fragments that cannot be understood alone, and `recentIDs` keeps the
    /// first card from repeating what he just saw. A draw that fails either
    /// test moves on to the next book rather than re-drawing, so the work
    /// stays bounded; six books at one draw each is plenty. `recordShown` on
    /// the way out means batch zero's own demotion pass pushes this pick to
    /// the back rather than dealing it twice.
    private func dealInstantCard() -> FlowCard? {
        // The seed/merge race is the one thing that outranks a fast first
        // frame: reading the store mid-merge is the Build-5 crash class.
        guard !seedingStatus.isSeeding else { return nil }
        var rng = FlowQueueBuilder.SeededRandomNumberGenerator(seed: seedBase)
        let recent = FlowRecentlyShownStore.recentIDs()
        // The one rule that outranks both of those: a line he asked never to
        // see is never the first thing he sees.
        let suppressed = FlowSuppression.suppressedHighlightIDs()
        for book in flowBooks.shuffled(using: &rng).prefix(6) {
            let total = highlightCount(in: book)
            guard total > 0 else { continue }
            var draw = Self.highlightsDescriptor(in: book.id)
            draw.fetchOffset = Int.random(in: 0..<total, using: &rng)
            draw.fetchLimit = 1
            guard let pick = try? flowModelContext.fetch(draw).first else { continue }
            guard FlowQueueBuilder.readsStandalone(pick.text),
                  !recent.contains(pick.id), !suppressed.contains(pick.id) else { continue }
            return .highlight(pick)
        }
        return nil
    }

    // MARK: - Pools: bounded, indexed fetches -- never a relationship fault

    /// How many books one batch's highlight pool is drawn from, and how many
    /// consecutive rows are read from each. 24 x 20 = 480 candidates for the
    /// ~24 highlight slots a batch has, spread across two dozen books.
    private static let poolBooksPerBatch = 24
    private static let poolWindow = 20
    /// The cloze slot's candidate window. The builder caps clozes at 6 per
    /// batch (2 at night) after its own shuffle, so 60 due candidates is ten
    /// times what any batch can deal.
    private static let clozeWindow = 60
    /// Keeps the pool's offset stream separate from the builder's shuffle
    /// stream. The builder's draw order is load-bearing (a fixed `seedBase`
    /// must deal the same feed), so the pools must never consume from it.
    private static let poolSeedSalt: UInt64 = 0x5EED_F10E_D00F_4A11

    /// Every highlight fetch goes through this predicate on purpose. Core Data
    /// (and so SwiftData) indexes every to-one foreign-key column, so
    /// `book?.id == X` resolves through `ZHIGHLIGHT.ZBOOK`'s index: a `COUNT`
    /// walks a few hundred index entries and `LIMIT n OFFSET k` skips k
    /// entries of the SAME index range before reading n rows. The alternative
    /// -- table-wide random `fetchOffset`s over `book != nil`, the
    /// `widgetInviteSample` primitive -- has to walk and discard every skipped
    /// row of a 32,000-row table on each draw, which for two dozen draws per
    /// batch is a dozen full passes over the table's pages. Proven form:
    /// `WisdomGraphView.swift` and `DiagnosticsView.swift` both count and fetch
    /// with exactly this predicate.
    private static func highlightsDescriptor(in bookID: UUID) -> FetchDescriptor<Highlight> {
        FetchDescriptor<Highlight>(predicate: #Predicate<Highlight> { $0.book?.id == bookID })
    }

    /// Per-book highlight counts, fetched once per book per open. Plain
    /// integers, never model rows, so this cache cannot go stale in the way a
    /// `@Model` held in `@State` across a store mutation does; a count that
    /// drifts (a highlight saved while Flow is up) only ever makes a window
    /// return fewer rows, which the builder's cycling absorbs.
    @State private var highlightCountByBook: [UUID: Int] = [:]

    private func highlightCount(in book: Book) -> Int {
        if let cached = highlightCountByBook[book.id] { return cached }
        let count = (try? flowModelContext.fetchCount(Self.highlightsDescriptor(in: book.id))) ?? 0
        highlightCountByBook[book.id] = count
        return count
    }

    /// One batch's highlight candidates: a seeded choice of books, and one
    /// seeded window of consecutive rows inside each. Deterministic per
    /// (seedBase, batch), like everything else the batch is built from, so a
    /// redeal under the same filter deals the same feed.
    ///
    /// Sampling is per book, not per row: each of the drawn books contributes
    /// one window regardless of its size, where the old `flatMap` pool weighted
    /// a 580-highlight book three times a 200-highlight one. The rules that
    /// decide WHAT gets dealt from the pool -- standalone demotion, recency
    /// demotion, night weighting, exclusion, the pattern -- are unchanged.
    ///
    /// A highlight can now recur across batches within one session (two
    /// batches may draw overlapping windows of the same book), where the old
    /// whole-library shuffle could not repeat until the pool cycled. That is
    /// what the existing `recentlyShownIDs` demotion in `buildBatch` is for:
    /// every card that settles on screen is recorded by the feed's settle
    /// handler, and a later batch that draws it again moves it to the back of
    /// its cycle. Within a single batch the pool is ~480 rows for ~24 slots
    /// and the books are distinct, so no batch deals the same row twice.
    private func drawHighlightPool(batch: Int) -> [Highlight] {
        var rng = FlowQueueBuilder.SeededRandomNumberGenerator(
            seed: FlowQueueBuilder.seed(base: seedBase, forBatch: batch) ^ Self.poolSeedSalt)
        var pool: [Highlight] = []
        pool.reserveCapacity(Self.poolBooksPerBatch * Self.poolWindow)
        for book in flowBooks.shuffled(using: &rng).prefix(Self.poolBooksPerBatch) {
            let total = highlightCount(in: book)
            guard total > 0 else { continue }
            var window = Self.highlightsDescriptor(in: book.id)
            window.fetchLimit = Self.poolWindow
            // A full window whenever the book can give one, so rows near the
            // end of a book are drawn as often as rows near the start.
            window.fetchOffset = total > Self.poolWindow
                ? Int.random(in: 0...(total - Self.poolWindow), using: &rng)
                : 0
            pool.append(contentsOf: (try? flowModelContext.fetch(window)) ?? [])
        }
        return pool
    }

    /// Gradeable, due at `now`, attached to a chapter -- the cloze slot's
    /// candidates and the opener's due count share this predicate, exactly as
    /// the builder's two in-memory filters shared theirs. Every form here is
    /// already proven against SwiftData's SQL translation elsewhere in this
    /// app: `!$0.isSuspended && ($0.dueDate ?? distantFuture) <= now` is
    /// `DiagnosticsView`'s dueNow count, `$0.chapter != nil` is
    /// `WatchSyncService.scheduledDueDates`, and `!= nil` on an attribute is
    /// everywhere. The 12 h re-review guard stays in Swift (the builder's
    /// `isGradeableAndDue`), so the SQL never has to express a subtraction.
    /// `chapter != nil` keeps the pool identical to the old
    /// `chapters.flatMap(\.quizQuestions)`.
    private static func dueDescriptor(now: Date) -> FetchDescriptor<QuizQuestion> {
        let distantFuture = Date.distantFuture
        return FetchDescriptor<QuizQuestion>(predicate: #Predicate<QuizQuestion> {
            !$0.isSuspended && $0.correctAnswerIndex != nil && $0.chapter != nil
                && ($0.dueDate ?? distantFuture) <= now
        })
    }

    /// Fills `FlowQueueBuilder.Pools` for one batch with fetches. Every read
    /// here is bounded by a predicate, a limit, or a column projection; none
    /// walks a `Book`'s relationships.
    private func fetchPools(batch: Int, now: Date, wantsDueCount: Bool) -> FlowQueueBuilder.Pools {
        // A second seeded stream (`&+` where the highlight pool uses `^`) so
        // the cloze window's offset is independent of the highlight windows'.
        var rng = FlowQueueBuilder.SeededRandomNumberGenerator(
            seed: FlowQueueBuilder.seed(base: seedBase, forBatch: batch) &+ Self.poolSeedSalt)

        // Chapters: one fetch of the chapter table (a few hundred rows of
        // title, summary and key lessons). The builder applies the source
        // filter through `chapter.book?.id`; `book != nil` here matches the old
        // `books.flatMap(\.chapters)`, which by construction never held an
        // orphan chapter.
        let chapters = (try? flowModelContext.fetch(
            FetchDescriptor<Chapter>(predicate: #Predicate<Chapter> { $0.book != nil }))) ?? []

        // Cloze candidates: a seeded window of `clozeWindow` full rows out of
        // everything due. The COUNT sizes the window's offset so the slot
        // varies between sessions instead of always drawing the first sixty in
        // row order.
        let dueTotal = (try? flowModelContext.fetchCount(Self.dueDescriptor(now: now))) ?? 0
        var dueWindow = Self.dueDescriptor(now: now)
        dueWindow.fetchLimit = Self.clozeWindow
        dueWindow.fetchOffset = dueTotal > Self.clozeWindow
            ? Int.random(in: 0...(dueTotal - Self.clozeWindow), using: &rng)
            : 0
        let dueQuestions = dueTotal > 0 ? ((try? flowModelContext.fetch(dueWindow)) ?? []) : []

        // The opener's number, only when an opener will be dealt (batch 0,
        // once a day): the same predicate projected to the one column the 12 h
        // guard needs. `propertiesToFetch` keeps each row to that column, the
        // `WatchSyncService.scheduledDueDates` pattern.
        var dueCount = 0
        if wantsDueCount && dueTotal > 0 {
            var scheduled = Self.dueDescriptor(now: now)
            scheduled.propertiesToFetch = [\.lastReviewedAt]
            let rows = (try? flowModelContext.fetch(scheduled)) ?? []
            dueCount = rows.filter { row in
                guard let last = row.lastReviewedAt else { return true }
                return now.timeIntervalSince(last) >= FlowQueueBuilder.clozeReReviewGuard
            }.count
        }

        // "N cards ripen overnight": a COUNT, same terms as
        // `FlowQueueBuilder.ripeningCount` (not suspended, due after now and
        // within 24 h; a nil dueDate falls to distantPast and fails `> now`).
        // `DiagnosticsView` counts with `($0.dueDate ?? distantPast) > now`.
        let tomorrow = now.addingTimeInterval(24 * 60 * 60)
        let distantPast = Date.distantPast
        let ripening = FetchDescriptor<QuizQuestion>(predicate: #Predicate<QuizQuestion> {
            !$0.isSuspended && $0.chapter != nil
                && ($0.dueDate ?? distantPast) > now && ($0.dueDate ?? distantPast) <= tomorrow
        })
        let ripeningTomorrow = (try? flowModelContext.fetchCount(ripening)) ?? 0

        // Weak topics: cards the scheduler has seen lapse twice or more. Only
        // ever a handful of rows by nature (he has to have missed the card
        // repeatedly), and the builder needs `question.book` to apply the
        // source filter, so these are full rows rather than a column
        // projection -- a projected row would fault back to the store for the
        // relationship anyway. Skipped at night, when the builder deals none.
        let lapsedQuestions: [QuizQuestion]
        if FlowQueueBuilder.isNight(now) {
            lapsedQuestions = []
        } else {
            let lapsed = FetchDescriptor<QuizQuestion>(predicate: #Predicate<QuizQuestion> {
                $0.fsrsLapses >= 2 && $0.chapter != nil
            })
            lapsedQuestions = (try? flowModelContext.fetch(lapsed)) ?? []
        }

        return FlowQueueBuilder.Pools(
            highlights: drawHighlightPool(batch: batch),
            chapters: chapters,
            dueQuestions: dueQuestions,
            lapsedQuestions: lapsedQuestions,
            dueCount: dueCount,
            ripeningTomorrow: ripeningTomorrow
        )
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
        // The shared token now -- Flow wrote the original, and the stops and
        // ease live in `CobuxAtmosphere` so Ebb and Chat can never drift from
        // it again.
        CobuxAtmosphere(accent: Color(hex: atmosphereHex), strength: .card)
            .animation(.easeInOut(duration: 0.6), value: atmosphereHex)
    }

    private var feed: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    FlowCardView(card: item.card, onSuppress: suppressCard)
                        .containerRelativeFrame(.vertical)
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $visibleItemID)
        .scrollIndicators(.hidden)
        // NO `.ignoresSafeArea(edges: .bottom)` here.
        //
        // There is no bottom `safeAreaInset` left for it to defeat -- the
        // global "Open Cobux" button moved onto the cards, and the inset that
        // reserved its height went with it (see the note at the top of `body`).
        // The ban stays anyway, because the cards did not change shape: each is
        // `containerRelativeFrame(.vertical)`, so a scroll view told to ignore
        // the bottom safe area hands every card the FULL screen height and
        // lands its bottom-anchored footer at the true screen edge, under the
        // home indicator.
        //
        // The history is the reason this line is a rule and not a preference.
        // It WAS here, and it silently cancelled the inset that then existed:
        // the inset reserved the button's measured height, this line extended
        // the scroll view straight back through the reserved strip, and the
        // comment on the inset went on claiming overlap was impossible at any
        // size. That was the fifth report of this same bottom area -- every
        // previous fix correct, and then defeated by this one line.
        // The settle tick: one soft haptic exactly when a card clicks into
        // the paging detent — half of a good feed's physical grip. The
        // condition skips the very first settle (nil -> first card at feed
        // open), which is presentation, not a gesture.
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: visibleItemID) { oldValue, _ in
            oldValue != nil
        }
        .onChange(of: visibleItemID) { oldID, newID in
            guard let newID, let index = items.firstIndex(where: { $0.id == newID }) else { return }
            // A settle from a real card is a swipe -- Flow has been used, so
            // its hint retires. nil -> first card is presentation, not use.
            if oldID != nil { CobuxTip.flow.markUsed() }
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
            // Deferred one runloop turn so the batch build (a few dozen
            // bounded fetches, see `fetchPools`) never lands on the same frame
            // as the settle haptic and atmosphere cross-fade.
            //
            // Not before the first batch exists. The instant card settles the
            // moment it is dealt, and with `items.count == 1` this branch fired
            // for it -- enqueueing a second build right behind the one
            // `onAppear` had already enqueued, so batch 0 and batch 1 were built
            // back to back behind the first card. The runway for the instant
            // card IS batch 0, and `onAppear` owns that.
            if hasBuiltFirstBatch && index >= items.count - 5 {
                scheduleBatch()
            }
        }
    }

    /// Enqueues one batch build on the main actor, coalescing: a second
    /// request while one is pending is a no-op, and a request that a
    /// synchronous build (a redeal, a scene re-activation) overtakes is
    /// dropped when it finally runs.
    private func scheduleBatch() {
        guard !batchScheduled else { return }
        batchScheduled = true
        Task { @MainActor in
            guard batchScheduled else { return }
            appendBatch()
        }
    }

    /// Shown instead of `emptyState` while a background seed/upgrade merge is
    /// in flight -- "Nothing to flow through yet, add a book" would be an
    /// outright false thing to tell someone whose library the app is
    /// actively populating right now.
    /// Shown only while the first batch is being built.
    ///
    /// Deliberately almost nothing: the wait is usually a few hundred
    /// milliseconds, and a spinner would draw more attention to it than it
    /// deserves. A quiet pulse says "working" without claiming anything about
    /// his library, which is the mistake the empty state was making.
    /// A title page, not a progress report.
    ///
    /// With `dealInstantCard` in place this is a fallback -- it shows only when
    /// no highlight can be dealt cheaply (mid-seed, or a library whose books are
    /// all excluded) -- but it is still a frame he can land on, and the version
    /// he photographed was a pale glyph over a grey "Gathering your highlights…"
    /// on an almost-white screen. Naming the machinery was the mistake: a wait
    /// that announces itself reads as broken, where the same wait under the
    /// app's own wordmark reads as opening.
    private var loadingState: some View {
        Text("FLOW")
            .font(CobuxTypography.display(colorScheme, size: 28, weight: .semibold))
            .kerning(6)
            .foregroundStyle(.secondary)
            .symbolEffect(.pulse)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .accessibilityLabel("Opening Flow")
    }

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

    // Both of these were hand-rolled VStacks -- a grey glyph, a `.headline`
    // and a `.borderedProminent` button -- while the Wisdom Graph's literally
    // identical pair of states used `CobuxEmptyStateView`. Two mechanisms for
    // the same moment across two sibling surfaces is the drift that component
    // exists to close, and Rajan named the treatment he wants everywhere:
    // *"i loev the ui nad colors and how this is beirtifull dipalyed and
    // eplained... also look for more stuff where this could be done."*
    private var emptyState: some View {
        CobuxEmptyStateView(
            icon: "water.waves",
            title: "Nothing to flow through yet",
            message: "Add a book or a few highlights and Flow turns your library into a feed you can read one card at a time."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var allBooksExcludedState: some View {
        CobuxEmptyStateView(
            icon: "line.3.horizontal.decrease.circle",
            title: "Every book is switched off",
            message: "Flow draws from the books you choose. Switch at least one back on and the feed fills right back up."
        ) {
            CobuxEmptyStateButton("Choose Books", systemImage: "line.3.horizontal.decrease.circle") {
                showingSourcePicker = true
            }
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

    // No `warmFlowRowCache` any more.
    //
    // It fetched every Highlight -- 32,125 highlights across 156 seed books
    // (scripts/check-corpus-scale.py, build 52), several times over what the
    // oldest comments in this file were written against -- and every Chapter
    // on a detached context, touched `highlight.book?.title` for each, and was
    // launched from a `.task` -- so it ran CONCURRENTLY with the main-actor
    // batch build scheduled from `onAppear`, never ahead of it. The figure is
    // stated as something a script re-derives, not a number to trust: the one
    // it replaces was itself a correction of an older stale figure, and had
    // gone stale in turn.
    //
    // It could not warm batch 0, and it made the freeze it was written to
    // shorten longer: SwiftData's coordinator serialises store access, so a
    // background full-table read holds the lock the main context's
    // relationship faults then wait on; and a to-many fault
    // (`book.highlights`) runs its own SELECT regardless of what the row cache
    // holds, so the "read once" was a read twice. The value-snapshot rewrite
    // that moves the build itself off the main actor (registered for 3.1) is
    // the real fix; a warm pass was never a half of it.

    private func appendBatch() {
        // Whatever was scheduled, this build satisfies it.
        batchScheduled = false
        // NEVER build a batch while the scene is not active.
        //
        // Real crash, build 46, 2026-09-02 12:56:42, symbolicated from the
        // MetricKit report Rajan shared:
        //
        //   0x8BADF00D  scene-update watchdog transgression:
        //   exhausted real (wall clock) time allowance of 10.00 seconds
        //   ProcessVisibility: Background   lowPowerModeEnabled: true
        //     FlowQueueBuilder.buildBatch(books:batch:seedBase:...)
        //     FlowView.appendBatch()             FlowView.swift:429
        //     closure #9 in FlowView.body.getter FlowView.swift:246
        //
        // `buildBatch(books:)` ran synchronously on the main actor and faulted
        // every book's relationships -- roughly 5s of CPU against a real
        // library. Doing that during a background scene-update is what iOS
        // kills an app for. The build is now pool-fed from bounded fetches
        // (`fetchPools`), a different order of magnitude, but the guard stays:
        // it still runs on the main actor, and deferring costs nothing -- a
        // Flow batch is only ever looked at while the app is on screen.
        guard scenePhase == .active else {
            batchDeferredUntilActive = true
            return
        }
        batchDeferredUntilActive = false
        // Recorded even when the batch comes back empty: the point is that the
        // question has now been ASKED, which is what separates "nothing to
        // show" from "not looked yet".
        defer { hasBuiltFirstBatch = true }
        // See the `seedingStatus` doc comment up top: the pools are fetched
        // and the cards read `book`/`chapter` to-one relationships, none of
        // which may race a background merge. The `seedingStatus.isSeeding`
        // onChange above retries this the moment it's safe.
        guard !seedingStatus.isSeeding else { return }
        // The daily opener is a once-a-DAY greeting. Reading the flag here
        // (rather than inside the builder) keeps `buildBatch` pure and
        // deterministic for its tests; `markDailyOpenerShown()` below closes
        // the loop so a later reopen today deals a feed without it.
        let showOpener = !StreakTracker.hasShownDailyOpenerToday
        // The echo is only ever dealt into batch 0, so it is only ever looked
        // for there -- and once per open, not once per redeal. Locked means
        // not dealt and not even looked up: his text stays unread until the
        // journal is open, and a later unlock plus redeal resolves it then.
        if nextBatch == 0 && !journalIsLocked && !journalEchoResolved {
            journalEcho = journalEchoForToday()
            journalEchoResolved = true
        }
        let echo = (nextBatch == 0 && !journalIsLocked) ? journalEcho : nil
        // One clock for the fetch predicates and the builder's own filters,
        // so "due at now" means the same instant in SQL and in Swift.
        let now = Date.now
        // Pools, not books. `buildBatch(books:)` derived its pools by faulting
        // every book's highlights, chapters and quiz questions -- the whole
        // library as managed objects, on this actor, per batch. `fetchPools`
        // reads a few hundred rows through bounded, indexed fetches instead;
        // the builder, its pattern, cursors, recap rhythm and RNG order are
        // exactly what they were.
        let pools = fetchPools(batch: nextBatch, now: now,
                               wantsDueCount: nextBatch == 0 && showOpener)
        let batch = FlowQueueBuilder.buildBatch(
            pools: pools,
            batch: nextBatch,
            seedBase: seedBase,
            resonancePairs: resonanceReady ? resonancePairs : [],
            journalEcho: echo,
            excludedBookIDs: excludedBookIDs,
            continuation: &batchContinuation,
            now: now,
            recentlyShownIDs: FlowRecentlyShownStore.recentIDs(),
            suppressedIDs: FlowSuppression.suppressedHighlightIDs(),
            includeDailyOpener: showOpener
        )
        // Only the first batch can carry the opener, so only that one marks it.
        if nextBatch == 0 && showOpener && !batch.isEmpty {
            StreakTracker.markDailyOpenerShown()
        }
        guard !batch.isEmpty else { return }
        let positioned = batch.enumerated().map { offset, card in
            FeedItem(id: "\(nextBatch)-\(offset)-\(card.id)", card: card)
        }
        items.append(contentsOf: positioned)
        nextBatch += 1
        pruneDistantHistory()
    }

    /// A card's "Don't show this again" (`FlowCardView.onSuppress`).
    ///
    /// Records the id, then takes every card carrying it out of the live feed
    /// -- the highlight itself, a quick check built from it, or a resonance
    /// pair it is half of -- with the deck's usual motion: `EbbView.suppress`'s
    /// exact animation, Reduce Motion honoured. If the card being hidden is
    /// the one on screen, the position moves to the card below it first (or
    /// above, at the very end) inside the same animation, so the page turns
    /// rather than the feed re-anchoring on an item that no longer exists.
    /// Nothing else happens: no toast, no undo, no count. Later batches skip
    /// the id through `appendBatch`'s `suppressedIDs`.
    private func suppressCard(_ id: UUID) {
        FlowSuppression.suppress(id)
        let doomed = Set(items.filter { Self.card($0.card, carries: id) }.map(\.id))
        guard !doomed.isEmpty else { return }
        let survivors = items.filter { !doomed.contains($0.id) }
        var landing = visibleItemID
        if let visibleItemID, doomed.contains(visibleItemID),
           let index = items.firstIndex(where: { $0.id == visibleItemID }) {
            landing = items[(index + 1)...].first(where: { !doomed.contains($0.id) })?.id
                ?? items[..<index].last(where: { !doomed.contains($0.id) })?.id
        }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .default) {
            items = survivors
            visibleItemID = landing
        }
        // Hiding cards near the end shortens the runway the settle handler
        // measures; top it back up the same way a swipe would.
        if hasBuiltFirstBatch, let landing,
           let index = items.firstIndex(where: { $0.id == landing }),
           index >= items.count - 5 {
            scheduleBatch()
        }
    }

    /// Whether a card is built from the given highlight or quick check.
    private static func card(_ card: FlowCard, carries id: UUID) -> Bool {
        switch card {
        case .highlight(let highlight): highlight.id == id
        case .clozeTeaser(let question): question.id == id
        case .resonance(let a, let b): a.id == id || b.id == id
        default: false
        }
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

    /// How many embedded highlights the resonance window reads. Comfortably
    /// more than the 120 candidates it needs, so the book filter and the
    /// occasional undecodable embedding can thin it without starving the
    /// pairing -- and small enough that the read is a page, not a table.
    private static let resonancePoolSize = 1_200
    /// What `FlowQueueBuilder.resonancePairs` is scored over. Unchanged: this
    /// was always 120, and the pairing is O(n²) in it.
    private static let resonanceCandidateCount = 120

    /// Snapshot (id, bookID, embedding) as plain values on a `@ModelActor`
    /// probe, score the pairs off it, then map the winners back to Highlights
    /// on this actor — SwiftData models never cross the thread boundary.
    /// Comparing stored embeddings is free; nothing here creates one.
    ///
    /// Nothing on this path is allowed to block Flow opening. `resonanceReady`
    /// gates every reader of `resonancePairs`, so the feed is correct and
    /// interactive for the whole time this is still working.
    private func computeResonancePairs() async {
        // Same merge-race guard as `appendBatch` -- `flowBooks.flatMap(\.highlights)`
        // below is exactly the relationship fault that must not race a
        // background seed/upgrade merge.
        guard !seedingStatus.isSeeding else { return }
        // Sampled with a bounded, indexed fetch rather than
        // `flowBooks.flatMap(\.highlights)`.
        //
        // That flatMap faulted EVERY included book's highlights relationship --
        // ~32,000 rows on this library, materialised as managed objects on the
        // main actor -- then shuffled all 32,000 of them, then built a
        // 32,000-entry dictionary, to end up keeping 120. All of it at Flow
        // open, right behind the instant card he is already reading, which is
        // exactly where a stutter is felt.
        //
        // The fetch takes a random window instead: one `COUNT` to size the
        // pool, a random offset into it, and `poolSize` rows read from there.
        // Embeddings are required, so the predicate does that filtering in SQL
        // instead of by decoding every row. The window moves each session, so
        // the pairs still vary the way `.shuffled()` was added to make them --
        // and `FlowQueueBuilder.resonancePairs` was already only ever handed
        // 120 candidates, so nothing about what reaches the card changed.
        //
        // `excludedBookIDs` is still applied, and still here rather than only
        // inside the builder: the spliced gold card below bypasses
        // `FlowQueueBuilder` entirely, so filtering only there would leak an
        // excluded book's quote onto the one card most likely to be noticed.
        // THE SAMPLE RUNS OFF THE MAIN ACTOR. This is the whole fix.
        //
        // Build 53 did the count, the windowed fetch, the filter, the shuffle
        // and the embedding decode right here -- and `computeResonancePairs` is
        // a method on a `@MainActor` View awaited from `.task`, with NO
        // suspension point anywhere between its first line and the
        // `Task.detached` below. So every one of those steps ran synchronously
        // on the main actor, and the first run is not debounced: it fires the
        // instant Flow appears. On his library that is a predicate `COUNT` over
        // 32,125 rows, a large SQL `OFFSET` (SQLite walks and discards every
        // skipped row -- up to ~30,000 of them), 1,200 managed objects
        // materialised, and up to 120 `book` faults and embedding decodes,
        // all while he is looking at a screen that will not respond. That is
        // "the flow doesn't open".
        //
        // Nothing about Flow's first frame needs any of it: the scoring was
        // already detached, and `resonanceReady` already gates every use of the
        // result, so the feed is correct the entire time this is still running.
        // It blocked purely because it was on the wrong actor.
        //
        // `FlowResonanceProbe` owns its own `ModelContext` on its own executor
        // and returns plain `Sendable` values -- no `@Model` and no
        // `ModelContext` crosses the boundary (SE-0338: a `nonisolated` async
        // function does NOT inherit the caller's actor, which is this app's
        // known crash class). Same shape as `QuizAnalyticsProbe` and
        // `DiagnosticsProbe`.
        let excluded = excludedBookIDs
        // Plain values by the time they get here, so the per-card suppression
        // is one cheap pass on this actor -- and, like the book filter, it has
        // to be applied HERE and not only in the builder: the spliced gold
        // card below bypasses `FlowQueueBuilder`.
        let suppressed = FlowSuppression.suppressedHighlightIDs()
        let candidates = await FlowResonanceProbe(modelContainer: flowModelContext.container)
            .candidates(excluding: excluded,
                        poolSize: Self.resonancePoolSize,
                        candidateCount: Self.resonanceCandidateCount)
            .filter { !suppressed.contains($0.id) }
        guard !candidates.isEmpty else { resonanceReady = true; return }

        let pairIDs = await Task.detached(priority: .utility) {
            FlowQueueBuilder.resonancePairs(
                from: candidates.map { ($0.id, $0.bookID, $0.embedding) })
        }.value

        // At most `limit` pairs come back (six), so at most twelve ids -- fetch
        // exactly those rows by id rather than holding the 1,200-object pool on
        // this actor just to look twelve of them up. The pool cannot come back
        // from the probe anyway: those are `@Model` objects belonging to the
        // probe's own context.
        let wantedIDs = Array(Set(pairIDs.flatMap { [$0.0, $0.1] }))
        guard !wantedIDs.isEmpty else { resonanceReady = true; return }
        let matched = (try? flowModelContext.fetch(
            FetchDescriptor<Highlight>(
                predicate: #Predicate<Highlight> { wantedIDs.contains($0.id) }))) ?? []
        let byID = Dictionary(matched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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

/// One resonance candidate as plain values. `Sendable` and free of any
/// `@Model` reference, so it can leave the probe's actor -- which is the entire
/// reason this type exists rather than passing `Highlight` rows back.
struct FlowResonanceCandidate: Sendable {
    let id: UUID
    let bookID: UUID
    let embedding: [Float]
}

/// Flow's resonance sample, taken off the main actor.
///
/// `QuizAnalyticsProbe`/`DiagnosticsProbe`'s shape exactly: a `@ModelActor`
/// owns a `ModelContext` confined to its own serial executor, every model read
/// happens there, and only plain `Sendable` values come back. Flow used to do
/// this same work inline on the main actor while the screen was opening.
///
/// Lives in this file rather than in `Services/` because the project lists every
/// source file individually in `project.pbxproj` (no synchronised folder
/// groups), so a new file would not join the target without a project edit.
@ModelActor
actor FlowResonanceProbe {
    /// Sampling is deliberately unchanged in kind: one `COUNT` to size the
    /// pool, a random window into it, the source filter, a shuffle, and the
    /// first `candidateCount` that carry a decodable embedding. The window is
    /// what makes the pairs vary between sessions, and
    /// `FlowQueueBuilder.resonancePairs` was already only ever handed
    /// `candidateCount` of them, so nothing about what reaches a card changed.
    func candidates(excluding excludedBookIDs: Set<UUID>,
                    poolSize: Int,
                    candidateCount: Int) -> [FlowResonanceCandidate] {
        // No `sortBy`. Build 53 sorted the whole matching table by `id` before
        // taking its window -- and `Highlight.id` carries no index, so that is a
        // full sort of every embedded highlight in the library, ~32,000 rows,
        // to choose 1,200 that are then SHUFFLED anyway. The sort could not
        // affect the outcome: the window is arbitrary by design and its
        // contents are randomised immediately below. Dropping it lets the fetch
        // be a plain scan.
        var descriptor = FetchDescriptor<Highlight>(
            predicate: #Predicate<Highlight> { $0.embeddingData != nil && $0.book != nil })
        let poolCount = (try? modelContext.fetchCount(descriptor)) ?? 0
        guard poolCount > 0 else { return [] }
        descriptor.fetchLimit = poolSize
        descriptor.fetchOffset = poolCount > poolSize
            ? Int.random(in: 0...(poolCount - poolSize))
            : 0
        let pool = ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { BookSourceFilter.isVisible($0, excluding: excludedBookIDs) }

        // Only the kept candidates pay the Data->[Float] decode -- an eager
        // compactMap over the whole pool would decode rows it then discards.
        return Array(
            pool.shuffled().lazy
                .compactMap { highlight -> FlowResonanceCandidate? in
                    guard let bookID = highlight.book?.id,
                          let embedding = highlight.embedding else { return nil }
                    return FlowResonanceCandidate(
                        id: highlight.id, bookID: bookID, embedding: embedding)
                }
                .prefix(candidateCount)
        )
    }
}
