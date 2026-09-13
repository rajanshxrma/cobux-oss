import SwiftUI
import SwiftData
import WidgetKit
#if canImport(UIKit)
import UIKit
#endif

/// The Flow feed — a full-screen, vertically-paging stream of cards from the
/// user's own library (quotes, chapter lessons, quick self-tests, weak-topic
/// callouts, and the occasional cross-book resonance find).
/// Inserted as an in-place overlay by `ContentView.flowOverlay` (build 60;
/// the Wisdom hero card still presents it as a `fullScreenCover`, and
/// `dismiss()` remains the fallback for that route -- see `close()`). iOS 17
/// paging APIs (`scrollTargetBehavior(.paging)` on a `LazyVStack` of
/// `containerRelativeFrame` pages) — deliberately not the rotated-TabView
/// hack. Infinite: nearing the end appends the next deterministic batch from
/// `FlowQueueBuilder`.
struct FlowView: View {
    /// How the overlay route closes Flow. `nil` on the cover route, where
    /// `dismiss()` still does the job.
    private let onClose: (() -> Void)?

    /// Explicit because the synthesised memberwise initialiser of a struct
    /// with `private` stored properties is itself private, and
    /// `WisdomGraphView` builds this view with no arguments.
    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

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
    /// Which path dealt the first card -- "warm deck", "instant card" or
    /// "batch N" -- reported to `SpeedTrace` from the first card's own
    /// `.onAppear`, once per open (`firstCardReported`).
    @State private var dealPath = ""
    @State private var firstCardReported = false
    /// A batch build is already enqueued on the main actor. Two uncoordinated
    /// triggers used to enqueue one each at open -- `onAppear` after dealing
    /// the instant card, and the runway check the instant card's own settle
    /// fired -- so batch 0 AND batch 1 were built back to back, synchronously,
    /// behind the first card. See `scheduleBatch`.
    @State private var batchScheduled = false
    /// Bumped by every redeal. A batch build now awaits `FlowPoolProbe`, and
    /// a redeal (a Sources toggle) can land while one is in flight; the build
    /// compares this on the way back and, if the deck moved under it, drops
    /// its cards and builds again from the new state instead of appending
    /// forty cards dealt under the old filter.
    @State private var dealGeneration = 0
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
                    close()
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
                // BEFORE the deal, not after. The batch builds the daily
                // opener card from the streak, so recording the day afterwards
                // meant the card was rendered from yesterday's count and
                // disagreed with More and Quiz by one. (The warm deck's opener
                // carries no streak for the same reason: `FlowCardSnapshot`
                // fills it in here, after this line.)
                StreakTracker.recordActivityToday()
                FlowWarmCache.shared.flowDidAppear()
                // THE WARM PATH. "It is fast but it's not right away."
                //
                // `FlowWarmCache` built the instant card AND batch 0 at launch
                // settle, off the main actor, as values (see its doc comment).
                // If that deck was dealt under exactly the inputs this open
                // would read -- same day, same filter, same hidden cards, same
                // journal lock -- adopt its `seedBase` and deal all forty-one
                // cards now: forty primary-key lookups on this context, a few
                // milliseconds, and the feed swipes the instant the cover
                // lands. Consumed once; the cache rebuilds after Flow closes.
                let fingerprint = FlowWarmCache.Fingerprint.current(
                    excludedRaw: excludedRaw, includedRaw: includedRaw, now: .now)
                if let deck = FlowWarmCache.shared.take(for: flowModelContext.container, matching: fingerprint),
                   dealWarmDeck(deck) {
                    // Dealt. Batch 1 is the runway now; the settle handler
                    // asks for it five cards out, as it always has.
                } else if let instant = dealInstantCard() {
                    // THE COLD PATH. Deal ONE card instantly, then build the
                    // real batch behind it -- on `FlowPoolProbe`'s executor
                    // now, so the card is swipeable while the batch builds.
                    //
                    // Rajan photographed the opening screen -- a pale gradient,
                    // a small glyph and "Gathering your highlights…" -- and
                    // said it was "unacceptalble at opening". The first card
                    // needs one readable highlight from one book: six single
                    // row draws at most, and it is on screen.
                    atmosphereHex = instant.accentHex
                    dealPath = "instant card"
                    riseIn { items = [FeedItem(id: "instant-\(instant.id)", card: instant)] }
                    if case .highlight(let highlight) = instant {
                        FlowRecentlyShownStore.recordShown(highlight.id)
                    }
                    scheduleBatch()
                } else {
                    scheduleBatch()
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
            // The next open's deck is built from here: past the dismissal,
            // off the main actor, under the recently-shown set this session
            // just added to -- so opening Flow again is as instant as the
            // first time.
            FlowWarmCache.shared.flowDidDisappear()
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
            scheduleBatch()
        }
        .onChange(of: seedingStatus.isSeeding) { wasSeeding, isSeeding in
            guard wasSeeding, !isSeeding else { return }
            if items.isEmpty {
                scheduleBatch()
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

    /// Closes Flow by whichever route opened it: the overlay's `onClose`
    /// (`ContentView.closeFlow`), else the cover's `dismiss()`.
    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    /// The first card's `.onAppear`: the render pass that puts a card on
    /// screen, reported once per open. `SpeedTrace` ignores it when no tap
    /// started the clock (the Wisdom cover route).
    private func reportFirstCardIfNeeded() {
        guard !firstCardReported else { return }
        firstCardReported = true
        SpeedTrace.flowFirstCardShown(via: dealPath)
    }

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

    /// One highlight, cheaply, for the very first frame of the cold path.
    ///
    /// `FlowPoolProbe.drawInstant` on this context: for each of at most six
    /// seeded books, one indexed `COUNT` and one `fetchLimit = 1` read at a
    /// seeded offset -- twelve tiny SELECTs at worst, no blob but the one
    /// row's, never a relationship fault. The previous version read
    /// `book.highlights` for up to six random books; this library's books
    /// average 206 highlights, each row carrying a 2 KB embedding blob, so
    /// the "cheap" path was faulting a thousand-plus managed objects before
    /// the first frame. That is the "it used to be super fast the moment it
    /// opens" he lost, and this is what gave it back.
    ///
    /// Honours the same rules the full builder does: `readsStandalone` keeps
    /// out fragments, `recentIDs` keeps the first card from repeating what he
    /// just saw, and a line he asked never to see is never the first thing
    /// he sees. `recordShown` at the call site means batch zero's demotion
    /// pass pushes this pick to the back rather than dealing it twice.
    private func dealInstantCard() -> FlowCard? {
        // The seed/merge race is the one thing that outranks a fast first
        // frame: reading the store mid-merge is the Build-5 crash class.
        guard !seedingStatus.isSeeding else { return nil }
        // The probe's fixed book order (sorted by id), not `@Query` order, so
        // the cold path's first card is the one a warm deck for this
        // `seedBase` would have dealt.
        let books = FlowPoolProbe.sourceBooks(in: flowModelContext, excludedRaw: excludedRaw, includedRaw: includedRaw).books
        return FlowPoolProbe.drawInstant(
            in: flowModelContext, books: books, seedBase: seedBase,
            recentlyShownIDs: FlowRecentlyShownStore.recentIDs(),
            suppressedIDs: FlowSuppression.suppressedHighlightIDs()
        ).map(FlowCard.highlight)
    }

    /// The whole first deck from `FlowWarmCache`, dealt in one frame.
    ///
    /// Adopts the deck's `seedBase` (so batch 1 chains from the same base the
    /// deck was drawn under), resolves the instant card and batch 0's rows by
    /// primary key on this context, and commits `items`, `nextBatch`, the
    /// recap continuation and the echo together. Returns false -- and changes
    /// nothing -- when the rows have gone or the deck is empty, so the cold
    /// path runs instead. Same seeding guard as the cold path; a merge would
    /// have dropped the deck anyway (`FlowWarmCache`'s `didSave` listener),
    /// but the guard is a rule, not an optimisation.
    private func dealWarmDeck(_ deck: FlowWarmCache.Deck) -> Bool {
        guard !seedingStatus.isSeeding else { return false }
        guard let cards = resolve(deck.plan) else { return false }
        var first: [FeedItem] = []
        var instantHighlightID: UUID?
        if let instant = deck.instant,
           let row = FlowRowResolver.rows(Highlight.self, for: [instant.rowID], in: flowModelContext)[instant.rowID] {
            first.append(FeedItem(id: "instant-\(FlowCard.highlight(row).id)", card: .highlight(row)))
            instantHighlightID = row.id
            atmosphereHex = instant.accentHex
        }
        guard !first.isEmpty || !cards.isEmpty else { return false }
        seedBase = deck.seedBase
        journalEcho = deck.journalEcho
        journalEchoResolved = true
        if let instantHighlightID { FlowRecentlyShownStore.recordShown(instantHighlightID) }
        if first.isEmpty, let opening = cards.first { atmosphereHex = opening.accentHex }
        let positioned = cards.enumerated().map { offset, card in
            FeedItem(id: "\(deck.plan.batch)-\(offset)-\(card.id)", card: card)
        }
        // No rise. The overlay's own 0.12 s arrival (`ContentView
        // .flowOverlay`) is the motion now, and the cover's slide was on the
        // other route; a second animation inside either would read as the
        // card arriving after the surface -- the exact gap this deck exists
        // to close. Committed plainly, so the first frame that carries the
        // overlay carries the card.
        dealPath = "warm deck"
        items = first + positioned
        if deck.plan.batch == 0 && deck.plan.includedDailyOpener && !cards.isEmpty {
            StreakTracker.markDailyOpenerShown()
        }
        nextBatch = deck.plan.batch + 1
        batchContinuation = deck.plan.continuation
        hasBuiltFirstBatch = true
        return true
    }

    /// The opening breath. The first card rises into place instead of
    /// appearing -- a hard cut into a surface this composed read as a
    /// glitch, not an arrival. 0.15 s, down from 0.45: "It has to be right
    /// away, like a highlight should open right away." Shortened, not
    /// removed, under Reduce Motion: the arrival still wants to be an
    /// arrival, it just stops being a rise.
    private func riseIn(_ change: () -> Void) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .easeOut(duration: 0.15), change)
    }

    /// `FlowBatchPlan` -> `[FlowCard]` over this context's rows: three
    /// primary-key resolves (highlights, chapters, quick checks), at most
    /// forty rows in all, then the streak read for the opener. `nil` when
    /// the plan had cards and none of them resolved -- the rows are gone.
    private func resolve(_ plan: FlowBatchPlan) -> [FlowCard]? {
        let highlights = FlowRowResolver.rows(
            Highlight.self, for: plan.cards.flatMap(\.highlightIDs), in: flowModelContext)
        let chapters = FlowRowResolver.rows(
            Chapter.self, for: plan.cards.compactMap(\.chapterID), in: flowModelContext)
        let questions = FlowRowResolver.rows(
            QuizQuestion.self, for: plan.cards.compactMap(\.questionID), in: flowModelContext)
        let streak = StreakTracker.currentStreak
        let cards = plan.cards.compactMap {
            $0.card(highlights: highlights, chapters: chapters, questions: questions, streak: streak)
        }
        if !plan.cards.isEmpty && cards.isEmpty { return nil }
        return cards
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
                        // The tap-to-card sample, taken where the card is
                        // rendered rather than where it was dealt.
                        .onAppear(perform: reportFirstCardIfNeeded)
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

    /// Enqueues one batch build, coalescing: a second request while one is
    /// pending or in flight is a no-op. Every trigger -- the open, the
    /// runway check, a scene re-activation, the end of a seed merge, a
    /// redeal -- comes through here, so at most one `FlowPoolProbe` build
    /// exists per feed at a time.
    private func scheduleBatch() {
        guard !batchScheduled else { return }
        batchScheduled = true
        Task { @MainActor in
            await appendBatch()
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
    ///
    /// The build is asynchronous now, so `hasBuiltFirstBatch` drops back to
    /// false for its duration: an empty `items` with the flag still true
    /// would show "Nothing to flow through yet" for the few frames the probe
    /// takes -- a claim about his data the empty state must never guess. The
    /// generation bump is what makes a build already in flight discard
    /// itself instead of appending cards from the old selection.
    private func redealFeed() {
        dealGeneration += 1
        items.removeAll()
        visibleItemID = nil
        settledItemIDs.removeAll()
        batchContinuation = FlowQueueBuilder.BatchContinuation()
        stats = FlowSessionStats()
        nextBatch = 0
        hasBuiltFirstBatch = false
        scheduleBatch()
    }

    // No `warmFlowRowCache` any more, and no main-actor batch build either.
    //
    // `warmFlowRowCache` fetched every Highlight (32,125 across 156 seed books
    // per scripts/check-corpus-scale.py, build 52) on a detached context
    // concurrently with the main-actor build, so it contended for SwiftData's
    // coordinator lock and made the freeze it was written to shorten longer.
    // The value-snapshot pass registered for 3.1 is now half built: the pools
    // and the builder run on `FlowPoolProbe`'s executor and come back as a
    // `FlowBatchPlan` of values; `FlowCard` itself still carries rows, so the
    // last step is forty primary-key lookups on this context.

    /// One batch, built off the main actor and dealt here.
    ///
    /// Reads every non-store input on this actor first (the opener flag, the
    /// echo, the recently-shown and hidden sets, the filter's raw strings,
    /// the recap continuation, the resonance pair ids), sends them to the
    /// probe as a `FlowBatchRequest`, awaits the plan, and resolves it. The
    /// builder, its pattern, cursors, recap rhythm and RNG order are exactly
    /// what they were -- `FlowPoolProbe.drawPools` makes the same bounded,
    /// indexed fetches `fetchPools` made here.
    ///
    /// NEVER started while the scene is not active. Real crash, build 46,
    /// 2026-09-02 12:56:42, symbolicated from the MetricKit report Rajan
    /// shared:
    ///
    ///   0x8BADF00D  scene-update watchdog transgression:
    ///   exhausted real (wall clock) time allowance of 10.00 seconds
    ///   ProcessVisibility: Background   lowPowerModeEnabled: true
    ///     FlowQueueBuilder.buildBatch(books:batch:seedBase:...)
    ///     FlowView.appendBatch()             FlowView.swift:429
    ///
    /// `buildBatch(books:)` ran synchronously on the main actor and faulted
    /// every book's relationships during a background scene update. The
    /// build is off this actor now and a different order of magnitude, but
    /// the guard stays: a Flow batch is only ever looked at while the app is
    /// on screen, and deferring costs nothing.
    private func appendBatch() async {
        guard scenePhase == .active else {
            batchDeferredUntilActive = true
            batchScheduled = false
            return
        }
        batchDeferredUntilActive = false
        // See the `seedingStatus` doc comment up top: the cards read
        // `book`/`chapter` to-one relationships, which must not race a
        // background merge. The `isSeeding` onChange retries the moment it is
        // safe. Recorded as built even so: the question has now been ASKED,
        // which is what separates "nothing to show" from "not looked yet".
        guard !seedingStatus.isSeeding else {
            batchScheduled = false
            hasBuiltFirstBatch = true
            return
        }
        let generation = dealGeneration
        let batchNumber = nextBatch
        // The daily opener is a once-a-DAY greeting. Reading the flag here
        // keeps `buildBatch` pure and deterministic for its tests;
        // `markDailyOpenerShown()` below closes the loop.
        let showOpener = batchNumber == 0 && !StreakTracker.hasShownDailyOpenerToday
        // The echo is only ever dealt into batch 0, so it is only ever looked
        // for there -- and once per open, not once per redeal. Locked means
        // not dealt and not even looked up: his text stays unread until the
        // journal is open, and a later unlock plus redeal resolves it then.
        if batchNumber == 0 && !journalIsLocked && !journalEchoResolved {
            journalEcho = FlowJournalEcho.today(in: flowModelContext)
            journalEchoResolved = true
        }
        let echo = (batchNumber == 0 && !journalIsLocked) ? journalEcho : nil
        // One clock for the fetch predicates and the builder's own filters,
        // so "due at now" means the same instant in SQL and in Swift.
        let request = FlowBatchRequest(
            seedBase: seedBase,
            batch: batchNumber,
            now: .now,
            excludedRaw: excludedRaw,
            includedRaw: includedRaw,
            recentlyShownIDs: FlowRecentlyShownStore.recentIDs(),
            suppressedIDs: FlowSuppression.suppressedHighlightIDs(),
            includeDailyOpener: showOpener,
            journalEcho: echo,
            continuation: batchContinuation,
            resonancePairIDs: resonanceReady
                ? resonancePairs.map { (FlowRowKey($0.0), FlowRowKey($0.1)) }
                : []
        )
        let plan = await FlowWarmCache.shared.probe(for: flowModelContext.container).plan(request)
        batchScheduled = false
        // The deck moved while the probe worked (a redeal, or a build that
        // overtook this one): these cards belong to a feed that no longer
        // exists. Build again from the state that does.
        guard generation == dealGeneration, batchNumber == nextBatch else {
            scheduleBatch()
            return
        }
        // A merge that started mid-flight: the rows are not to be touched.
        // The `isSeeding` onChange retries when it ends.
        guard !seedingStatus.isSeeding else {
            hasBuiltFirstBatch = true
            return
        }
        defer { hasBuiltFirstBatch = true }
        guard let cards = resolve(plan) else { return }
        // Only the first batch can carry the opener, so only that one marks it.
        if batchNumber == 0 && showOpener && !cards.isEmpty {
            StreakTracker.markDailyOpenerShown()
        }
        guard !cards.isEmpty else { return }
        let positioned = cards.enumerated().map { offset, card in
            FeedItem(id: "\(batchNumber)-\(offset)-\(card.id)", card: card)
        }
        if items.isEmpty, let opening = cards.first {
            atmosphereHex = opening.accentHex
            dealPath = "batch \(batchNumber)"
        }
        items.append(contentsOf: positioned)
        nextBatch = batchNumber + 1
        batchContinuation = plan.continuation
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

// MARK: - Batch 0 off the main actor: the pool probe, the plan, the warm cache

/// One dealt card as plain values -- what a built batch looks like when it has
/// to leave the actor that built it.
///
/// `FlowCard` carries `@Model` rows (`Highlight`, `Chapter`, `QuizQuestion`),
/// and a row belongs to the context that fetched it. So the batch that
/// `FlowPoolProbe` builds on its own executor comes back as this: the row's
/// `PersistentIdentifier` (a `Sendable` value the main context can turn back
/// into ITS row with a primary-key lookup) plus the few scalars each card
/// type already carried. Forty of these resolve on the main actor in a few
/// milliseconds; forty `Highlight`s crossing an actor boundary is the
/// SE-0338 crash class this codebase has already paid for.
///
/// `dailyOpener` deliberately drops the streak. The builder reads
/// `StreakTracker.currentStreak` when it deals the card, and a plan built at
/// launch settle would bake in a count taken BEFORE this open's
/// `recordActivityToday()` -- the off-by-one the comment above `.onAppear`
/// documents. The main actor fills it in at resolve time instead.
enum FlowCardSnapshot: Sendable {
    case highlight(FlowRowKey)
    case keyLesson(FlowRowKey, lessonIndex: Int)
    case clozeTeaser(FlowRowKey)
    case weakTopic(topic: String, lapseCount: Int)
    case dailyOpener(dueCount: Int)
    case sessionRecap(setNumber: Int, ripeningTomorrow: Int, nextBook: String?)
    case journalEcho(entryID: UUID, date: Date, passage: String)
    case resonance(FlowRowKey, FlowRowKey)

    init(_ card: FlowCard) {
        switch card {
        case .highlight(let highlight):
            self = .highlight(FlowRowKey(highlight))
        case .keyLesson(let chapter, let lessonIndex):
            self = .keyLesson(FlowRowKey(chapter), lessonIndex: lessonIndex)
        case .clozeTeaser(let question):
            self = .clozeTeaser(FlowRowKey(question))
        case .weakTopic(let topic, let lapseCount):
            self = .weakTopic(topic: topic, lapseCount: lapseCount)
        case .dailyOpener(_, let dueCount):
            self = .dailyOpener(dueCount: dueCount)
        case .sessionRecap(let setNumber, let ripeningTomorrow, let nextBook):
            self = .sessionRecap(setNumber: setNumber, ripeningTomorrow: ripeningTomorrow, nextBook: nextBook)
        case .journalEcho(let entryID, let date, let passage):
            self = .journalEcho(entryID: entryID, date: date, passage: passage)
        case .resonance(let a, let b):
            self = .resonance(FlowRowKey(a), FlowRowKey(b))
        }
    }

    /// The identifiers this card needs resolved, by table.
    var highlightIDs: [FlowRowKey] {
        switch self {
        case .highlight(let id): [id]
        case .resonance(let a, let b): [a, b]
        default: []
        }
    }
    var chapterID: FlowRowKey? {
        if case .keyLesson(let id, _) = self { return id }
        return nil
    }
    var questionID: FlowRowKey? {
        if case .clozeTeaser(let id) = self { return id }
        return nil
    }

    /// Back to a `FlowCard` over the main context's rows. `nil` when a row is
    /// gone -- deleted between the build and the deal -- and the card is
    /// simply not dealt, which the feed's cycling absorbs.
    func card(highlights: [FlowRowKey: Highlight],
              chapters: [FlowRowKey: Chapter],
              questions: [FlowRowKey: QuizQuestion],
              streak: Int) -> FlowCard? {
        switch self {
        case .highlight(let id):
            guard let highlight = highlights[id] else { return nil }
            return .highlight(highlight)
        case .keyLesson(let id, let lessonIndex):
            guard let chapter = chapters[id], chapter.keyLessons.indices.contains(lessonIndex) else { return nil }
            return .keyLesson(chapter, lessonIndex: lessonIndex)
        case .clozeTeaser(let id):
            guard let question = questions[id] else { return nil }
            return .clozeTeaser(question)
        case .weakTopic(let topic, let lapseCount):
            return .weakTopic(topic: topic, lapseCount: lapseCount)
        case .dailyOpener(let dueCount):
            return .dailyOpener(streak: streak, dueCount: dueCount)
        case .sessionRecap(let setNumber, let ripeningTomorrow, let nextBook):
            return .sessionRecap(setNumber: setNumber, ripeningTomorrow: ripeningTomorrow, nextBook: nextBook)
        case .journalEcho(let entryID, let date, let passage):
            return .journalEcho(entryID: entryID, date: date, passage: passage)
        case .resonance(let a, let b):
            guard let first = highlights[a], let second = highlights[b] else { return nil }
            return .resonance(first, second)
        }
    }
}

/// Everything one batch build reads that is not in the store, gathered on
/// the main actor at the moment the batch is asked for and handed across as
/// values. Every field is what `FlowView.appendBatch` used to read inline,
/// so the builder's inputs are unchanged -- only where they are read from.
struct FlowBatchRequest: Sendable {
    var seedBase: UInt64
    var batch: Int
    var now: Date
    /// The two halves of the book-source filter, raw, exactly as
    /// `@AppStorage` holds them; the probe derives the effective set from
    /// its own `Book` rows with the same `BookSourceFilter` call the view
    /// makes, so the two can never disagree about a default-off book.
    var excludedRaw: String
    var includedRaw: String
    var recentlyShownIDs: Set<UUID>
    var suppressedIDs: Set<UUID>
    var includeDailyOpener: Bool
    var journalEcho: (entryID: UUID, date: Date, passage: String)?
    var continuation: FlowQueueBuilder.BatchContinuation
    /// The session's resonance pairs, as identifiers. Empty until
    /// `computeResonancePairs` has run, which is every batch 0 at open.
    var resonancePairIDs: [(FlowRowKey, FlowRowKey)] = []
}

/// One built batch, ready to be dealt: the cards as values, the recap state
/// after them, and the filter the pools were drawn under.
struct FlowBatchPlan: Sendable {
    let seedBase: UInt64
    let batch: Int
    let cards: [FlowCardSnapshot]
    let continuation: FlowQueueBuilder.BatchContinuation
    let excludedBookIDs: Set<UUID>
    let includedDailyOpener: Bool
}

/// The first card, as values, for the warm cache.
struct FlowInstantSnapshot: Sendable {
    let rowID: FlowRowKey
    let highlightID: UUID
    let accentHex: String
}

/// Flow's pool fetches and batch build, off the main actor.
///
/// `FlowResonanceProbe`'s shape (and `QuizAnalyticsProbe`'s, and
/// `DiagnosticsProbe`'s): a `@ModelActor` owns a `ModelContext` confined to
/// its own serial executor, every model read happens there, and only plain
/// `Sendable` values come back. Until this, `FlowView.fetchPools` ran the
/// same two dozen indexed fetches and `FlowQueueBuilder.buildBatch` on the
/// main actor one turn after the instant card was dealt -- so the card was
/// visible but the surface would not answer a swipe until the build was
/// done. Now the main actor sends a `FlowBatchRequest`, awaits a
/// `FlowBatchPlan`, and resolves at most forty rows by primary key.
///
/// The drawing itself is `static` and takes a `ModelContext`, so the tests
/// run it over an in-memory context on the main actor and prove that a plan
/// built here deals the same cards `buildBatch(pools:)` deals over the same
/// pools -- and that two draws for one `seedBase` are identical, which is
/// what lets a plan built at launch settle stand in for one built at open.
@ModelActor
actor FlowPoolProbe {
    func plan(_ request: FlowBatchRequest) -> FlowBatchPlan {
        Self.makePlan(in: modelContext, request)
    }

    /// The instant card and batch 0 together, for the warm cache. One trip
    /// to the actor, and the instant pick is recorded as shown BEFORE batch
    /// 0 draws (as `FlowView.onAppear` does with `recordShown`) so the
    /// batch's own demotion pass pushes it to the back rather than dealing
    /// it twice.
    func warmDeck(_ request: FlowBatchRequest) -> (instant: FlowInstantSnapshot?, plan: FlowBatchPlan) {
        var request = request
        let books = Self.sourceBooks(in: modelContext, excludedRaw: request.excludedRaw, includedRaw: request.includedRaw).books
        let instant = Self.drawInstant(in: modelContext, books: books, seedBase: request.seedBase,
                                       recentlyShownIDs: request.recentlyShownIDs,
                                       suppressedIDs: request.suppressedIDs)
        let snapshot = instant.map {
            FlowInstantSnapshot(rowID: FlowRowKey($0), highlightID: $0.id,
                                accentHex: $0.book?.coverColorHex ?? "#6366F1")
        }
        if let instant { request.recentlyShownIDs.insert(instant.id) }
        return (snapshot, Self.makePlan(in: modelContext, request))
    }

    // MARK: Static drawing -- one implementation for the probe and the tests

    /// How many books one batch's highlight pool is drawn from, and how many
    /// consecutive rows are read from each. 24 x 20 = 480 candidates for the
    /// ~24 highlight slots a batch has, spread across two dozen books.
    static let poolBooksPerBatch = 24
    static let poolWindow = 20
    /// The cloze slot's candidate window. The builder caps clozes at 6 per
    /// batch (2 at night) after its own shuffle, so 60 due candidates is ten
    /// times what any batch can deal.
    static let clozeWindow = 60
    /// Keeps the pool's offset stream separate from the builder's shuffle
    /// stream. The builder's draw order is load-bearing (a fixed `seedBase`
    /// must deal the same feed), so the pools must never consume from it.
    static let poolSeedSalt: UInt64 = 0x5EED_F10E_D00F_4A11

    /// Every highlight fetch goes through this predicate on purpose. Core Data
    /// (and so SwiftData) indexes every to-one foreign-key column, so
    /// `book?.id == X` resolves through `ZHIGHLIGHT.ZBOOK`'s index: a `COUNT`
    /// walks a few hundred index entries and `LIMIT n OFFSET k` skips k
    /// entries of the SAME index range before reading n rows. Proven form:
    /// `WisdomGraphView.swift` and `DiagnosticsView.swift` both count and
    /// fetch with exactly this predicate.
    static func highlightsDescriptor(in bookID: UUID) -> FetchDescriptor<Highlight> {
        FetchDescriptor<Highlight>(predicate: #Predicate<Highlight> { $0.book?.id == bookID })
    }

    /// The books a feed may draw from, in a FIXED order. `@Query` and an
    /// unsorted fetch both return store order, which is not a contract; the
    /// pool's seeded `shuffled(using:)` is only deterministic over a
    /// deterministic input, and a plan built at launch settle has to deal
    /// the same cards a plan built at open would. Sorted by `id`, a value
    /// that never changes for a row.
    static func sourceBooks(in context: ModelContext, excludedRaw: String, includedRaw: String)
        -> (books: [Book], excludedBookIDs: Set<UUID>, libraryIsEmpty: Bool) {
        let all = ((try? context.fetch(FetchDescriptor<Book>())) ?? [])
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let excluded = BookSourceFilter.effectiveExcludedIDs(books: all, excludedRaw: excludedRaw, includedRaw: includedRaw)
        let books = excluded.isEmpty ? all : all.filter { !excluded.contains($0.id) }
        return (books, excluded, all.isEmpty)
    }

    /// One highlight, cheaply, for the very first frame.
    ///
    /// Single-row draws, never a relationship fault: for each of at most six
    /// seeded books, one indexed `COUNT` and one `fetchLimit = 1` read at a
    /// seeded offset inside that book -- twelve tiny SELECTs at worst, no
    /// blob but the one row's. Honours the same rules the full builder does:
    /// `readsStandalone` keeps out fragments, `recentlyShownIDs` keeps the
    /// first card from repeating what he just saw, and a suppressed line is
    /// never the first thing he sees. A draw that fails moves on to the next
    /// book rather than re-drawing, so the work stays bounded.
    static func drawInstant(in context: ModelContext, books: [Book], seedBase: UInt64,
                            recentlyShownIDs: Set<UUID>, suppressedIDs: Set<UUID>) -> Highlight? {
        var rng = FlowQueueBuilder.SeededRandomNumberGenerator(seed: seedBase)
        for book in books.shuffled(using: &rng).prefix(6) {
            let bookID = book.id
            let total = (try? context.fetchCount(highlightsDescriptor(in: bookID))) ?? 0
            guard total > 0 else { continue }
            var draw = highlightsDescriptor(in: bookID)
            draw.fetchOffset = Int.random(in: 0..<total, using: &rng)
            draw.fetchLimit = 1
            guard let pick = try? context.fetch(draw).first else { continue }
            guard FlowQueueBuilder.readsStandalone(pick.text),
                  !recentlyShownIDs.contains(pick.id), !suppressedIDs.contains(pick.id) else { continue }
            return pick
        }
        return nil
    }

    /// One batch's highlight candidates: a seeded choice of books, and one
    /// seeded window of consecutive rows inside each. Deterministic per
    /// (seedBase, batch), like everything else the batch is built from.
    /// Sampling is per book, not per row, so a 580-highlight book and a
    /// 200-highlight one each contribute one window. A highlight can recur
    /// across batches (two batches may draw overlapping windows); the
    /// builder's `recentlyShownIDs` demotion is what handles that.
    static func drawHighlightPool(in context: ModelContext, books: [Book], seedBase: UInt64, batch: Int) -> [Highlight] {
        var rng = FlowQueueBuilder.SeededRandomNumberGenerator(
            seed: FlowQueueBuilder.seed(base: seedBase, forBatch: batch) ^ poolSeedSalt)
        var pool: [Highlight] = []
        pool.reserveCapacity(poolBooksPerBatch * poolWindow)
        for book in books.shuffled(using: &rng).prefix(poolBooksPerBatch) {
            let bookID = book.id
            let total = (try? context.fetchCount(highlightsDescriptor(in: bookID))) ?? 0
            guard total > 0 else { continue }
            var window = highlightsDescriptor(in: bookID)
            window.fetchLimit = poolWindow
            // A full window whenever the book can give one, so rows near the
            // end of a book are drawn as often as rows near the start.
            window.fetchOffset = total > poolWindow
                ? Int.random(in: 0...(total - poolWindow), using: &rng)
                : 0
            pool.append(contentsOf: (try? context.fetch(window)) ?? [])
        }
        return pool
    }

    /// Gradeable, due at `now`, attached to a chapter -- the cloze slot's
    /// candidates and the opener's due count share this predicate. Every
    /// form here is proven against SwiftData's SQL translation elsewhere in
    /// this app (`DiagnosticsView`'s dueNow count,
    /// `WatchSyncService.scheduledDueDates`). The 12 h re-review guard stays
    /// in Swift (the builder's `isGradeableAndDue`).
    static func dueDescriptor(now: Date) -> FetchDescriptor<QuizQuestion> {
        let distantFuture = Date.distantFuture
        return FetchDescriptor<QuizQuestion>(predicate: #Predicate<QuizQuestion> {
            !$0.isSuspended && $0.correctAnswerIndex != nil && $0.chapter != nil
                && ($0.dueDate ?? distantFuture) <= now
        })
    }

    /// Fills `FlowQueueBuilder.Pools` for one batch. Every read here is
    /// bounded by a predicate, a limit, or a column projection; none walks a
    /// `Book`'s relationships. Byte-for-byte the fetches `FlowView.fetchPools`
    /// made on the main actor, now callable on any context.
    static func drawPools(in context: ModelContext, books: [Book], seedBase: UInt64, batch: Int,
                          now: Date, wantsDueCount: Bool) -> FlowQueueBuilder.Pools {
        // A second seeded stream (`&+` where the highlight pool uses `^`) so
        // the cloze window's offset is independent of the highlight windows'.
        var rng = FlowQueueBuilder.SeededRandomNumberGenerator(
            seed: FlowQueueBuilder.seed(base: seedBase, forBatch: batch) &+ poolSeedSalt)

        // Chapters: one fetch of the chapter table. `book != nil` matches the
        // old `books.flatMap(\.chapters)`, which never held an orphan.
        let chapters = (try? context.fetch(
            FetchDescriptor<Chapter>(predicate: #Predicate<Chapter> { $0.book != nil }))) ?? []

        // Cloze candidates: a seeded window of `clozeWindow` full rows out of
        // everything due.
        let dueTotal = (try? context.fetchCount(dueDescriptor(now: now))) ?? 0
        var dueWindow = dueDescriptor(now: now)
        dueWindow.fetchLimit = clozeWindow
        dueWindow.fetchOffset = dueTotal > clozeWindow
            ? Int.random(in: 0...(dueTotal - clozeWindow), using: &rng)
            : 0
        let dueQuestions = dueTotal > 0 ? ((try? context.fetch(dueWindow)) ?? []) : []

        // The opener's number, only when an opener will be dealt: the same
        // predicate projected to the one column the 12 h guard needs.
        var dueCount = 0
        if wantsDueCount && dueTotal > 0 {
            var scheduled = dueDescriptor(now: now)
            scheduled.propertiesToFetch = [\.lastReviewedAt]
            let rows = (try? context.fetch(scheduled)) ?? []
            dueCount = rows.filter { row in
                guard let last = row.lastReviewedAt else { return true }
                return now.timeIntervalSince(last) >= FlowQueueBuilder.clozeReReviewGuard
            }.count
        }

        // "N cards ripen overnight": a COUNT, same terms as
        // `FlowQueueBuilder.ripeningCount`.
        let tomorrow = now.addingTimeInterval(24 * 60 * 60)
        let distantPast = Date.distantPast
        let ripening = FetchDescriptor<QuizQuestion>(predicate: #Predicate<QuizQuestion> {
            !$0.isSuspended && $0.chapter != nil
                && ($0.dueDate ?? distantPast) > now && ($0.dueDate ?? distantPast) <= tomorrow
        })
        let ripeningTomorrow = (try? context.fetchCount(ripening)) ?? 0

        // Weak topics: cards the scheduler has seen lapse twice or more --
        // a handful of rows by nature. Skipped at night, when the builder
        // deals none.
        let lapsedQuestions: [QuizQuestion]
        if FlowQueueBuilder.isNight(now) {
            lapsedQuestions = []
        } else {
            let lapsed = FetchDescriptor<QuizQuestion>(predicate: #Predicate<QuizQuestion> {
                $0.fsrsLapses >= 2 && $0.chapter != nil
            })
            lapsedQuestions = (try? context.fetch(lapsed)) ?? []
        }

        return FlowQueueBuilder.Pools(
            highlights: drawHighlightPool(in: context, books: books, seedBase: seedBase, batch: batch),
            chapters: chapters,
            dueQuestions: dueQuestions,
            lapsedQuestions: lapsedQuestions,
            dueCount: dueCount,
            ripeningTomorrow: ripeningTomorrow
        )
    }

    /// Pools, builder, snapshot -- the whole batch, on whichever context
    /// this is given. The builder's pattern, cursors, recap rhythm and RNG
    /// order are exactly what they were; this only decides where its inputs
    /// come from and what shape its output leaves in.
    static func makePlan(in context: ModelContext, _ request: FlowBatchRequest) -> FlowBatchPlan {
        let source = sourceBooks(in: context, excludedRaw: request.excludedRaw, includedRaw: request.includedRaw)
        let pools = drawPools(in: context, books: source.books, seedBase: request.seedBase,
                              batch: request.batch, now: request.now,
                              wantsDueCount: request.batch == 0 && request.includeDailyOpener)
        // The session's pairs, re-resolved on this context by primary key.
        let pairRows = FlowRowResolver.rows(
            Highlight.self,
            for: request.resonancePairIDs.flatMap { [$0.0, $0.1] },
            in: context)
        let pairs: [(Highlight, Highlight)] = request.resonancePairIDs.compactMap { a, b in
            guard let first = pairRows[a], let second = pairRows[b] else { return nil }
            return (first, second)
        }
        var continuation = request.continuation
        let cards = FlowQueueBuilder.buildBatch(
            pools: pools,
            batch: request.batch,
            seedBase: request.seedBase,
            resonancePairs: pairs,
            journalEcho: request.journalEcho,
            excludedBookIDs: source.excludedBookIDs,
            continuation: &continuation,
            now: request.now,
            recentlyShownIDs: request.recentlyShownIDs,
            suppressedIDs: request.suppressedIDs,
            includeDailyOpener: request.includeDailyOpener
        )
        return FlowBatchPlan(
            seedBase: request.seedBase,
            batch: request.batch,
            cards: cards.map(FlowCardSnapshot.init),
            continuation: continuation,
            excludedBookIDs: source.excludedBookIDs,
            includedDailyOpener: request.includeDailyOpener
        )
    }
}

/// Rows for identifiers, on a given context -- how a `FlowBatchPlan` becomes
/// `FlowCard`s on the main actor, and how the session's resonance pairs reach
/// the probe.
///
/// Three tiers, cheapest first: a row the context already has registered
/// costs nothing; the rest are asked for in ONE primary-key `IN` fetch; any
/// the batch fetch did not return are tried one at a time (belt and braces
/// against a predicate form SwiftData will not translate -- `try?` turns a
/// failed translation into an empty result, never a crash). A row that is
/// genuinely gone stays absent and its card is not dealt.
/// A row's address across actors: the stored `id: UUID` (what a predicate
/// can ask for) beside the `PersistentIdentifier` (what a registered row is
/// found by for free). Build 60 review: the resolver used to query by
/// `persistentModelID` -- a `#Predicate` shape this repo had never run on a
/// device, and 58 taught that SwiftData traps on shapes it cannot translate.
/// `ids.contains($0.id)` over a stored UUID is the proven form
/// (`SearchService.resolve`, `JournalListView`'s library sample).
struct FlowRowKey: Hashable, Sendable {
    let pid: PersistentIdentifier
    let uuid: UUID

    init<T: FlowStoredRow>(_ row: T) {
        pid = row.persistentModelID
        uuid = row.id
    }
}

/// The three tables Flow deals from, each with a stored `UUID` and a fetch
/// by a list of them in the one predicate shape that has shipped.
protocol FlowStoredRow: PersistentModel {
    var id: UUID { get }
    static func flowRows(ids: [UUID]) -> FetchDescriptor<Self>
}

extension Highlight: FlowStoredRow {
    static func flowRows(ids: [UUID]) -> FetchDescriptor<Highlight> {
        FetchDescriptor<Highlight>(predicate: #Predicate<Highlight> { ids.contains($0.id) })
    }
}
extension Chapter: FlowStoredRow {
    static func flowRows(ids: [UUID]) -> FetchDescriptor<Chapter> {
        FetchDescriptor<Chapter>(predicate: #Predicate<Chapter> { ids.contains($0.id) })
    }
}
extension QuizQuestion: FlowStoredRow {
    static func flowRows(ids: [UUID]) -> FetchDescriptor<QuizQuestion> {
        FetchDescriptor<QuizQuestion>(predicate: #Predicate<QuizQuestion> { ids.contains($0.id) })
    }
}

enum FlowRowResolver {
    static func rows<T: FlowStoredRow>(_ type: T.Type, for keys: [FlowRowKey],
                                       in context: ModelContext) -> [FlowRowKey: T] {
        var found: [FlowRowKey: T] = [:]
        var missing: [FlowRowKey] = []
        for key in keys where found[key] == nil && !missing.contains(key) {
            if let row: T = context.registeredModel(for: key.pid) {
                found[key] = row
            } else {
                missing.append(key)
            }
        }
        guard !missing.isEmpty else { return found }
        // One fetch by stored id for the rest. A row that is genuinely gone
        // stays absent and its card is not dealt.
        let wanted = missing.map(\.uuid)
        let byUUID = Dictionary(missing.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        for row in (try? context.fetch(T.flowRows(ids: wanted))) ?? [] {
            if let key = byUUID[row.id] { found[key] = row }
        }
        return found
    }
}

/// Today's journal echo -- his own writing, never mixed into the library.
///
/// An entry written on this calendar date in an earlier year, selected here
/// rather than in the builder so the builder stays pure. Uses the journal's
/// own guards: the 14-day floor (fresh writing is a wound), the
/// excluded-phrase list, and the same passage scoring, so a fragment that
/// could embarrass him can no more appear here than on the journal card.
/// Returns nil far more often than not, and that is correct -- most days
/// have no echo, and none of them should say so.
///
/// Bounded on purpose: a projection of two columns (`id`, `modifiedDate`)
/// decides on the date first, and `text` is touched only for the handful of
/// entries actually written on this calendar date. Main-actor because the
/// selector's helpers are, and because it reads his text: called once per
/// open (or once per warm pass), never per batch.
@MainActor
enum FlowJournalEcho {
    static func today(in context: ModelContext) -> (entryID: UUID, date: Date, passage: String)? {
        let calendar = Calendar.current
        let today = calendar.dateComponents([.month, .day], from: .now)
        guard let floor = calendar.date(byAdding: .day,
                                        value: -JournalHighlightSelector.minimumAgeDays,
                                        to: .now) else { return nil }
        var descriptor = FetchDescriptor<PersonalWritingEntry>()
        descriptor.propertiesToFetch = [\.id, \.modifiedDate]
        guard let entries = try? context.fetch(descriptor) else { return nil }
        // A permanently silenced entry may never resurface, on any surface.
        let suppressed = EbbSuppressionStore.suppressedIDs()
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

    /// Whether the journal is locked right now, read the way `FlowView`'s
    /// `@AppStorage` + `JournalLockStatus` pair reads it. Locked means no
    /// echo and no lookup: his text stays unread until the journal is open.
    static var isLocked: Bool {
        let enabled = (UserDefaults.standard.object(forKey: JournalLockStatus.enabledKey) as? Bool) ?? true
        return enabled && !JournalLockStatus.shared.isUnlocked
    }
}

/// Flow's first deck, built before he taps.
///
/// "It is fast but it's not right away." What was left between the tap and a
/// card he could swipe was batch 0's build: two dozen indexed fetches and the
/// builder, on the main actor, one turn after the instant card. This does
/// that work at launch settle instead -- about 1.5 s in, after the tab
/// shell's own warm-up (`PagingTabView.Coordinator.scheduleWarmUp`, 900 ms
/// after the shell is made, one tab per 150 ms pass), never while
/// `SeedingStatus.shared.isSeeding` and never in the background -- on
/// `FlowPoolProbe`'s executor, and keeps the result as VALUES: a
/// `FlowBatchPlan` of forty `FlowCardSnapshot`s and the instant card's
/// identifier. Never a `@Model` row: a row held across a store mutation is
/// the stale-object class, and a row crossing an actor is SE-0338.
///
/// The deck is built for a `seedBase` chosen here; `FlowView` adopts that
/// base when it consumes the deck, so a session is still deterministic per
/// open and batch 1 chains from batch 0 exactly as if the view had built
/// both. Consumed once, then rebuilt after Flow closes so the second open of
/// the session is instant too. Dropped whenever a save from any context
/// touches a table the deck was dealt from (`SemanticVectorCache`'s
/// `ModelContext.didSave` listener, same defensive reading of the payload),
/// and refused at consume time when anything the builder read outside the
/// store has since changed (`Fingerprint`) -- the cold path then runs, off
/// the main actor, and is still fast; it is just not free.
@MainActor
final class FlowWarmCache {
    static let shared = FlowWarmCache()

    /// The non-store inputs a deck was dealt under. A deck is only served
    /// when the open's fingerprint matches, so a card hidden since, a book
    /// switched off since, a day that rolled over, a night that fell, or a
    /// journal that locked all fall through to a fresh build. `Equatable`,
    /// compared whole: there is no partial match.
    struct Fingerprint: Equatable, Sendable {
        var day: DateComponents
        var night: Bool
        var excludedRaw: String
        var includedRaw: String
        var includeDailyOpener: Bool
        var suppressedIDs: Set<UUID>
        var recentlyShownIDs: Set<UUID>
        var journalLocked: Bool
        var ebbSuppressedIDs: Set<UUID>

        /// Read from the same stores `FlowView.appendBatch` reads, at `now`.
        // `@MainActor`: reads the journal lock through `JournalLockStatus.shared`.
        // Both callers (`FlowView.onAppear`, `FlowWarmCache`) are on the main actor.
        @MainActor
        static func current(excludedRaw: String, includedRaw: String, now: Date) -> Fingerprint {
            Fingerprint(
                day: Calendar.current.dateComponents([.year, .month, .day], from: now),
                night: FlowQueueBuilder.isNight(now),
                excludedRaw: excludedRaw,
                includedRaw: includedRaw,
                includeDailyOpener: !StreakTracker.hasShownDailyOpenerToday,
                suppressedIDs: FlowSuppression.suppressedHighlightIDs(),
                recentlyShownIDs: FlowRecentlyShownStore.recentIDs(),
                journalLocked: FlowJournalEcho.isLocked,
                ebbSuppressedIDs: EbbSuppressionStore.suppressedIDs()
            )
        }
    }

    struct Deck {
        let seedBase: UInt64
        let instant: FlowInstantSnapshot?
        let plan: FlowBatchPlan
        let journalEcho: (entryID: UUID, date: Date, passage: String)?
        let fingerprint: Fingerprint
        let containerID: ObjectIdentifier
    }

    /// How long after launch the first deck is built: after the launch tab's
    /// first frame, `ContentView`'s launch `.task` chain and the tab shell's
    /// warm-up passes, so nothing he is looking at waits behind it.
    nonisolated static let launchDelay: Duration = .milliseconds(1500)
    /// How long after Flow closes the next deck is built -- past the
    /// dismissal animation, so the rebuild never shares a frame with it.
    nonisolated static let redealDelay: Duration = .milliseconds(600)
    /// How long after a store save the deck is rebuilt. The embedding
    /// backfill and the seed merge save in bursts; this folds one into one.
    nonisolated static let saveDebounce: Duration = .seconds(2)

    private(set) var deck: Deck?
    private var container: ModelContainer?
    private var probe: FlowPoolProbe?
    private var warmTask: Task<Void, Never>?
    /// Set while a `FlowView` is on screen. No deck is built then: it would
    /// share SwiftData's coordinator with the feed's own fetches, and Flow's
    /// close schedules the rebuild anyway.
    private var flowIsPresented = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: nil
        ) { note in
            guard Self.touchesFlowTables(note) else { return }
            Task { @MainActor in
                FlowWarmCache.shared.invalidate(rebuildAfter: FlowWarmCache.saveDebounce)
            }
        })
    }

    /// The one probe for this container, created on first use -- so the
    /// probe's context keeps its row cache across a session's batches.
    func probe(for container: ModelContainer) -> FlowPoolProbe {
        if let probe, self.container === container { return probe }
        let probe = FlowPoolProbe(modelContainer: container)
        self.probe = probe
        self.container = container
        return probe
    }

    /// Builds a deck after `delay`, replacing any pending build. Idempotent
    /// and cheap to call; the call site that matters is the launch chain,
    /// then Flow's own close.
    func scheduleWarm(container: ModelContainer, after delay: Duration = FlowWarmCache.launchDelay) {
        if self.container !== container {
            // A different store: nothing built so far applies to it.
            deck = nil
            probe = nil
        }
        self.container = container
        warmTask?.cancel()
        warmTask = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            // Never while a seed/upgrade merge is writing (the Build-5 crash
            // class), never in the background, never under an open Flow.
            // Re-checked at the moment of use, not trusted from above.
            while SeedingStatus.shared.isSeeding || !Self.appIsActive || self.flowIsPresented {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
            }
            await self.warm(container: container)
        }
    }

    /// Consumes the deck for this store if it was dealt under exactly this
    /// fingerprint. Either way the cache is empty afterwards: a deck is a
    /// single deal, never served twice.
    func take(for container: ModelContainer, matching fingerprint: Fingerprint) -> Deck? {
        defer { deck = nil }
        guard let deck, deck.containerID == ObjectIdentifier(container),
              deck.fingerprint == fingerprint else { return nil }
        return deck
    }

    /// `FlowView` reports its presence so no deck is built beside a live feed.
    func flowDidAppear() {
        flowIsPresented = true
        warmTask?.cancel()
        warmTask = nil
    }

    func flowDidDisappear() {
        flowIsPresented = false
        if let container { scheduleWarm(container: container, after: Self.redealDelay) }
    }

    /// Drops the deck; rebuilds after `delay` when a store is known.
    func invalidate(rebuildAfter delay: Duration) {
        deck = nil
        guard let container, !flowIsPresented else { return }
        scheduleWarm(container: container, after: delay)
    }

    private func warm(container: ModelContainer) async {
        guard !flowIsPresented, !SeedingStatus.shared.isSeeding else { return }
        let now = Date.now
        let excludedRaw = UserDefaults.standard.string(forKey: BookSourceFilter.excludedKey) ?? ""
        let includedRaw = UserDefaults.standard.string(forKey: BookSourceFilter.includedKey) ?? ""
        let fingerprint = Fingerprint.current(excludedRaw: excludedRaw, includedRaw: includedRaw, now: now)
        // The echo is the one main-actor read here: a two-column projection
        // over the journal, his text touched only for today's date. One turn
        // of breathing room before it, so it never lands in the frame that
        // scheduled it.
        await Task.yield()
        guard !Task.isCancelled else { return }
        let echo = fingerprint.journalLocked ? nil : FlowJournalEcho.today(in: ModelContext(container))
        let seedBase = UInt64.random(in: UInt64.min...UInt64.max)
        let request = FlowBatchRequest(
            seedBase: seedBase,
            batch: 0,
            now: now,
            excludedRaw: excludedRaw,
            includedRaw: includedRaw,
            recentlyShownIDs: fingerprint.recentlyShownIDs,
            suppressedIDs: fingerprint.suppressedIDs,
            includeDailyOpener: fingerprint.includeDailyOpener,
            journalEcho: echo,
            continuation: FlowQueueBuilder.BatchContinuation()
        )
        let dealt = await probe(for: container).warmDeck(request)
        // The world may have moved while the probe worked: a save dropped
        // the deck (and scheduled another build), Flow opened, or this task
        // was superseded. Only a build whose inputs still hold is kept.
        guard !Task.isCancelled, !flowIsPresented, self.container === container else { return }
        deck = Deck(seedBase: seedBase, instant: dealt.instant, plan: dealt.plan,
                    journalEcho: echo, fingerprint: fingerprint,
                    containerID: ObjectIdentifier(container))
        // On a compact phone the probe's context -- and the few hundred
        // rows it registered building this deck, each carrying a 2 KB
        // vector -- does not stay resident between Flow sessions. The deck
        // itself is values and stays; the next open's `appendBatch` makes a
        // fresh probe (one `ModelContext`, a millisecond) and keeps it for
        // that session's batches as before. See `DeviceClass`.
        if DeviceClass.current.isCompact { probe = nil }
    }

    private static var appIsActive: Bool {
        #if canImport(UIKit)
        // Not `scenePhase`: a process-wide cache has no view to read it
        // from. `applicationState` is the same fact for a single-scene app.
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }

    /// Whether a `ModelContext.didSave` payload names a table the deck is
    /// dealt from. `SemanticVectorCache.touchesHighlights`' defensive
    /// reading: identifiers under the enum key or its raw string, as an
    /// array or a set; a payload with no identifier lists, or one that says
    /// everything was invalidated, counts as touching them. A needless
    /// rebuild costs background time; a stale deck deals a deleted row.
    nonisolated static let watchedEntities: Set<String> = [
        "Highlight", "QuizQuestion", "Chapter", "Book", "PersonalWritingEntry"
    ]

    nonisolated static func touchesFlowTables(_ note: Notification) -> Bool {
        guard let info = note.userInfo else { return true }
        if identifiers(in: info, for: .invalidatedAllIdentifiers) != nil { return true }
        var sawAnyKey = false
        for key in [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers] {
            guard let ids = identifiers(in: info, for: key) else { continue }
            sawAnyKey = true
            if ids.contains(where: { watchedEntities.contains($0.entityName) }) { return true }
        }
        return !sawAnyKey
    }

    private nonisolated static func identifiers(in info: [AnyHashable: Any],
                                                for key: ModelContext.NotificationKey) -> [PersistentIdentifier]? {
        let value = info[key] ?? info[key.rawValue]
        if let array = value as? [PersistentIdentifier] { return array }
        if let set = value as? Set<PersistentIdentifier> { return Array(set) }
        return nil
    }
}
