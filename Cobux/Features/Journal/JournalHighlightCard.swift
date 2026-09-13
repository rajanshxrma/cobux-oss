import SwiftData
import SwiftUI

/// One quiet card under the calendar, showing him something he wrote.
///
/// The voice is fixed by Fable's ruling and is the whole design: **kicker, his
/// words, the date.** No mood words, no "insight", no advice framing, no
/// prompt. The kicker states the algorithm outright — "ON THIS DAY ·
/// MARCH 2, 2025" — so he always knows why he is being shown this. A surface
/// that characterizes him is an invasion; one that only quotes and dates is a
/// mirror.
///
/// Deliberately absent, all vetoed: streak tie-ins, badges, notifications, any
/// "daily reflection" framing. It is there when he looks; it never calls him.
struct JournalHighlightCard: View {
    let entries: [PersonalWritingEntry]
    /// The library, for the pairing. Defaulted empty so every existing call
    /// site and preview keeps working and simply gets no resonance card.
    var highlights: [Highlight] = []
    /// Passages he chose to keep. Read-only here; only he creates one.
    var keeps: [JournalKeep] = []
    /// Reports the day's pick upward, so Ebb can open on the SAME passage
    /// rather than computing a second one. Two surfaces disagreeing about what
    /// today's passage is would make both of their kickers untrustworthy, and
    /// recomputing would also re-run a selector that records what it showed.
    ///
    /// Declared BEFORE `onOpen` deliberately: a trailing closure binds to the
    /// LAST parameter, so putting this after it would silently capture every
    /// call site's trailing closure. `JournalCalendarStrip` records the same
    /// trap for the same reason.
    var onPick: ((JournalHighlightSelector.Pick) -> Void)? = nil
    /// Opens Ebb from the deck's last card -- the threshold receding into the
    /// tide, and the first door into Ebb anyone would actually find.
    var onOpenEbb: (() -> Void)? = nil
    /// Write Back door -- forwarded up to the list's compose session.
    var onWriteBack: ((UUID) -> Void)? = nil
    @State private var slotIndex = 0
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext
    @State private var cachedDeck: [ThresholdDeckBuilder.Slot]?
    /// Which round of the deck is on screen. Rajan: *"it should be an automatic
    /// carousel, you know it should always keep moving and newer stuff coming
    /// in, maybe make it an infinite carousel."* A deck that wraps onto its own
    /// first card is a loop, not a carousel, so wrapping past the door deals the
    /// NEXT round instead -- see `ThresholdDeckBuilder`, which spends no
    /// cooldown to do it. Round 0 is always the day's own deck, so leaving the
    /// screen and coming back is unchanged.
    @State private var deckRound = 0
    /// Everything earlier rounds have already shown this sitting, so a later
    /// round brings new writing rather than reshuffling the same eight entries.
    /// Session-scoped `@State` on purpose: it dies with the screen, and round 0
    /// is dealt from the day's seed alone.
    @State private var dealtEntryIDs: Set<UUID> = []
    /// The most recent round that dealt a "From your chat" card, so the round
    /// after it is built without one. Never two in a row: the window is his
    /// writing first, and the chat card an occasional guest in it. Keyed to
    /// the ROUND rather than kept as a flag, so a same-round rebuild (a
    /// released keep, a suppression) is not mistaken for the next round.
    /// Session state like `dealtEntryIDs`, for the same reason -- round 0 is
    /// the day's seed alone.
    @State private var chatReflectionRound: Int?
    /// When he last touched this card. The auto-advance never moves the deck
    /// under his finger: any tap or swipe buys back a full interval.
    @State private var lastInteraction: Date = .distantPast
    /// Which way the deck is turning, so the outgoing page leaves the way
    /// the incoming one arrives from. Forward (advance, and every automatic
    /// turn) slides in from the trailing edge; a back-swipe reverses both.
    ///
    /// Set one runloop turn BEFORE `slotIndex` changes, deliberately -- see
    /// `turn(to:forward:)`. A removed view leaves with the transition it was
    /// last rendered with, so a direction set in the same transaction as the
    /// index would reach the incoming page and miss the outgoing one.
    @State private var turnsForward = true
    /// Bumped on every turn; the shimmer's keyframes fire off it. Not a count
    /// of anything -- it is never read, only changed.
    @State private var shimmerTick = 0
    /// The page dot's geometry namespace, so one accent dot glides between
    /// the grey ones rather than the accent jumping from dot to dot.
    @Namespace private var dotsNamespace
    /// Bumped whenever something invalidates the deck (a suppression, a
    /// released keep) so the build task re-fires for the same pick.
    @State private var deckRebuild = 0
    /// Bumped when the day's pick is let go of (a suppression), so the
    /// selection task -- keyed on it -- chooses again. Clearing `pick` alone
    /// left the task's key unchanged and the window at zero height for the
    /// rest of the view's life.
    @State private var selectionEpoch = 0
    /// The suppression store's change signal, folded into both task
    /// identities, so a "Never show this again" made inside Ebb reaches the
    /// card underneath it instead of leaving the banished entry on screen.
    @State private var suppression = EbbSuppressionSignal.shared
    var onOpen: (UUID) -> Void

    @Environment(\.colorScheme) private var colorScheme
    /// Reduce Motion is a hard gate (`CobuxMotion`), and this card had none of
    /// it: the pick arriving, a slot turning over under a tap or a swipe, the
    /// whole window folding away on Hide -- all six eased on regardless. It
    /// sits at the top of the Journal tab, so it was the first motion he saw
    /// on the screen the setting matters most on.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Folded into the auto-advance task's identity, so leaving the app CANCELS
    /// the timer outright rather than letting it wake on a schedule behind a
    /// guard. A carousel that keeps ticking in the background is exactly the
    /// "burns battery for nothing" shape.
    @Environment(\.scenePhase) private var scenePhase
    @State private var pick: JournalHighlightSelector.Pick?
    /// Dismissed for today only, and silently — no confirmation, no undo prompt.
    // `@AppStorage("cobux.journal.highlightDismissedOn")` removed with the ×.
    // The key is deliberately not migrated or cleared: nothing reads it any
    // more, and deleting a stored value nobody asked to lose is not this
    // change's business.
    /// The entry today's card settled on, and the day it settled.
    ///
    /// `pick` is `@State`, so it dies every time he leaves the Journal screen --
    /// and `selectPick` recorded what it showed on the way out. So every revisit
    /// recomputed, saw the previous choice inside the 60-day cooldown, chose a
    /// DIFFERENT entry, and burned that one too. Three visits a day would empty
    /// an eligible pool of ~100 entries within a month, and a genuine "on this
    /// day" match disappeared on the second visit. The day's choice is recorded
    /// here so it survives the view, and so exactly one entry per day is spent.
    /// The settled pick's RENDER fields, cached for the day.
    ///
    /// Why this exists: without it, every visit to the journal tab re-ran the
    /// entire selection pipeline just to redraw a card that was already decided
    /// -- a snapshot map over every entry he has ever written (faulting the
    /// whole table), a filter-and-sort over every library highlight, and a
    /// detached task at starved utility priority. "The from your archive
    /// feature loads very late" was that pipeline, every time, for a result
    /// that could not change until midnight.
    ///
    /// The cache stores only what the card draws. The gates are NOT cached:
    /// the fast path still re-checks quiet words against the full entry text
    /// and suppression against the live store, so quieting a word mid-day
    /// takes effect on the very next visit.
    @AppStorage("cobux.journal.pickRenderCache") private var pickRenderCache: String = ""

    /// `.reference` and the `words` it carried are both gone with the card kind
    /// (see `JournalHighlightSelector.Pick`). A cache written by an earlier build
    /// still spelling `"reference"` simply fails to decode, the `try?` below
    /// returns nil, and the day falls through to a fresh selection -- which is
    /// the correct outcome and needed no migration.
    private struct CachedPick: Codable {
        enum Kind: String, Codable { case onThisDay, fromArchive, resonance }
        var kind: Kind
        var entryID: UUID
        var date: Date
        var passage: String
        var highlight: String
        var bookTitle: String

        init(_ pick: JournalHighlightSelector.Pick) {
            switch pick {
            case let .onThisDay(id, date, passage):
                self = .init(kind: .onThisDay, entryID: id, date: date, passage: passage,
                             highlight: "", bookTitle: "")
            case let .fromArchive(id, date, passage):
                self = .init(kind: .fromArchive, entryID: id, date: date, passage: passage,
                             highlight: "", bookTitle: "")
            case let .resonance(id, date, passage, highlight, book):
                self = .init(kind: .resonance, entryID: id, date: date, passage: passage,
                             highlight: highlight, bookTitle: book)
            }
        }

        init(kind: Kind, entryID: UUID, date: Date, passage: String,
             highlight: String, bookTitle: String) {
            self.kind = kind; self.entryID = entryID; self.date = date
            self.passage = passage
            self.highlight = highlight; self.bookTitle = bookTitle
        }

        var pick: JournalHighlightSelector.Pick {
            switch kind {
            case .onThisDay: .onThisDay(entryID: entryID, date: date, passage: passage)
            case .fromArchive: .fromArchive(entryID: entryID, date: date, passage: passage)
            case .resonance: .resonance(entryID: entryID, date: date, passage: passage,
                                        highlight: highlight, bookTitle: bookTitle)
            }
        }
    }

    @AppStorage("cobux.journal.pickDay") private var pickDay: String = ""
    @AppStorage("cobux.journal.pickEntry") private var pickEntry: String = ""

    /// No `DateFormatter`, on purpose.
    ///
    /// This spells a PERSISTENCE KEY, not something a person reads, and a
    /// formatter is the wrong tool for that twice over. A fixed `"yyyy-MM-dd"`
    /// resolved against the device locale can emit a non-Gregorian year, so
    /// the key would mean different things on different devices. And a
    /// formatter hoisted to build it once -- which is what this was, and the
    /// hoist was right to want one, since `todayKey` is read four times in a
    /// single pass of the pick logic below -- freezes `TimeZone.current` at
    /// construction, so flying between zones without relaunching leaves
    /// "today" behind.
    ///
    /// An earlier version of this comment claimed a locale and calendar pin
    /// fixed both. It fixes the first only: nothing in that version set
    /// `timeZone`, and an explicit `Calendar` value snapshots the zone as
    /// well, so it arguably made the freeze firmer than leaving it unset.
    ///
    /// Components off `Calendar.current` have neither problem. It is re-read
    /// per call so it tracks the device, there is no locale surface because no
    /// text is being formatted, and it is cheaper than the formatter it
    /// replaces -- which is what the hoist was chasing in the first place.
    private var todayKey: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        return String(format: "%04d-%02d-%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    var body: some View {
        Group {
            if let pick {
                // The window, not a single card. Tapping turns it over rather
                // than re-selecting: re-selection is what emptied a ~100-entry
                // pool through the 60-day cooldown (see `pickDay` above), so an
                // unbounded refresh would rebuild that bug as a feature. The
                // deck is decided once for the day and cycled by hand.
                //
                // NOT CANCELABLE, on his instruction: *"the tips on top of
                // journal whatver those are plus the from your archive shit
                // sohuld not be crossable it should remain there forever."* The
                // × and the `dismissedOn != todayKey` gate it wrote are both
                // gone, and the stated reason is UI consistency -- a card that
                // can vanish gives this screen two different shapes.
                //
                // What is removed is the ability to close the CARD -- the × read
                // "Hide for today" and wrote `dismissedOn`, nothing more.
                // Suppressing a PASSAGE is untouched and is a different control
                // in a different place: "Never show this again", reached by
                // holding a card inside Ebb (`EbbView` -> `EbbSuppressionStore
                // .suppress`), which this card still honours through
                // `suppression.revision`. That one is how a painful passage is
                // buried, it is permanent, and it was never what he was
                // complaining about.
                //
                // A card and its page dots are one object, so they sit at the
                // head rhythm's tightest step.
                VStack(alignment: .leading, spacing: JournalFeedRhythm.withinObject) {
                    turningSlot(for: currentSlot(pick: pick))
                        // ONE height for every slot, whatever it carries. The
                        // deck used to resize per card -- a short reference
                        // after a four-line passage collapsed the window and
                        // moved the dots under his thumb mid-cycle. A steady
                        // frame makes tap, swipe and dots all live in fixed
                        // places: consistency IS the ux here. Scaled with
                        // Dynamic Type via the same limit the text uses.
                        //
                        // The frame now lives INSIDE the card builders, between
                        // their padding and their background -- which is the
                        // whole of the second half of his report: *"then space
                        // witht the from your archive elises too muc"*. Applied
                        // out here it sized a TRANSPARENT box around a card that
                        // still hugged its own content, so a one-line "ON THIS
                        // DAY" left up to a hundred points of empty nothing
                        // between the card and its dots. Inside the builders,
                        // the card's own wash fills the steady frame: the dots
                        // stay exactly where they were, and the hole is gone.
                        .onAppear { markSurfacedIfKeep(currentSlot(pick: pick)) }
                        .onChange(of: slotIndex) { _, _ in
                            markSurfacedIfKeep(currentSlot(pick: pick))
                        }
                    pageDots(count: deck(pick: pick).count)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    lastInteraction = .now
                    advance(pick: pick)
                }
                // Swipe as well as tap -- and back-swipe is itself new
                // capability, since tap could never revisit a slot. The
                // thresholds are deliberately anisotropic: horizontal must
                // clearly dominate before this fires, so the List's vertical
                // scroll is never contested.
                .gesture(
                    DragGesture(minimumDistance: 24)
                        // `onChanged` is here only to hold the auto-advance
                        // off: the deck must never turn over mid-swipe, and a
                        // drag he abandons still counts as him working the
                        // card. No new gesture was added for this -- a second
                        // recogniser on a List row is how a feed loses its
                        // scroll, and this screen's scroll is the one thing
                        // that must not break.
                        .onChanged { _ in lastInteraction = .now }
                        .onEnded { value in
                            lastInteraction = .now
                            let dx = value.translation.width
                            let dy = value.translation.height
                            guard abs(dx) > abs(dy) * 1.5, abs(dx) > 40 else { return }
                            if dx < 0 { advance(pick: pick) } else { retreat(pick: pick) }
                        }
                )
                .task(id: "\(pick.entryID.uuidString)-\(deckRebuild)-\(deckRound)-\(suppression.revision)") {
                    await buildDeck(pick: pick)
                }
                // The carousel's clock.
                //
                // A `.task` rather than a `Timer`, because its lifetime is the
                // view's: the row leaving the List cancels it, and there is no
                // retain cycle and nothing to invalidate by hand. Its identity
                // carries `scenePhase` and `reduceMotion`, so backgrounding the
                // app or turning Reduce Motion on does not leave a suppressed
                // timer ticking -- it cancels the task and the guard below
                // refuses to start a new one.
                //
                // Reduce Motion is a HARD gate, per `CobuxMotion`'s standing
                // rule: with it on, nothing here moves by itself at all. Tap and
                // swipe still work, so no capability is lost -- the window just
                // stops taking the initiative, which is the whole meaning of the
                // setting.
                .task(id: "advance-\(reduceMotion)-\(scenePhase)-\(pick.entryID.uuidString)") {
                    guard !reduceMotion, scenePhase == .active else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(Self.autoAdvanceSeconds))
                        guard !Task.isCancelled else { return }
                        // Never over his hand. One whole interval is bought
                        // back by any touch, which also covers the window in
                        // which a long press is opening the context menu.
                        guard Date.now.timeIntervalSince(lastInteraction)
                                >= Self.autoAdvanceSeconds else { continue }
                        // Nothing to turn over. One slot is the door alone.
                        guard deck(pick: pick).count > 1 else { continue }
                        advance(pick: pick)
                    }
                }
                // Air above and below, and it belongs HERE -- after the gestures,
                // and on the card rather than on the row in `JournalListView`.
                //
                // Rajan, on the flush edge: "it is tocuning the calendar above
                // right awy was it specifically design or misatke cause no
                // spacing ongested". It was a mistake, and a structural one: the
                // calendar's row and this one both set `.listRowInsets(EdgeInsets())`
                // -- every edge zero -- which removes the default row padding that
                // would otherwise have separated them, and neither put any vertical
                // spacing back. Two zero-inset rows abut exactly.
                //
                // Not on the row, because the `else` branch below is a deliberate
                // zero-height row: paying for the gap out there would open a 24pt
                // hole under the calendar on every day this card has nothing to
                // say. AFTER the gestures, so the new air is not tappable -- a tap
                // in the margin above the card must not turn the deck over.
                //
                // Both numbers now come from the head's one scale.
                // `betweenObjects` above, because the calendar and this card
                // are two objects; `betweenDays` below, because what follows is
                // the feed, and head-to-feed is the same kind of break as one
                // day to the next. The old pair (16 above, 8 below) is exactly
                // the asymmetry he named.
                .padding(.top, JournalFeedRhythm.betweenObjects)
                .padding(.bottom, JournalFeedRhythm.betweenDays)
            } else {
                // NOT an implicit EmptyView, and this is the whole bug.
                //
                // The body used to be `Group { if let pick { ... } }` with the
                // selection `.task` attached to it. With `pick` still nil the
                // Group resolves to EmptyView, and an empty row inside a `List`
                // section is not materialised -- so the task that SETS `pick`
                // never ran. Appearing was a precondition for the code that
                // makes it appear, so the card could never show, on any device,
                // for anybody. Rajan reported it missing twice: "i asked you for
                // like a journal specific smart highlights on the top below the
                // calendar that is also not here", then again on build 49,
                // "below calendar i dont see any highlight".
                //
                // A zero-height Color is real content, so the row materialises,
                // the task runs, and the card fades in when it has something to
                // say. It stays zero-height when it doesn't, which is why this
                // is not a spacer.
                Color.clear.frame(height: 0)
            }
        }
        .task(id: "\(entries.count)-\(selectionEpoch)-\(suppression.revision)") {
            // A suppression made ANYWHERE -- Ebb, this card's own menu, a
            // surface not yet written -- moves the store's revision, which is
            // part of this task's identity. So the banished entry is let go
            // of here and a new pick chosen, rather than the old one sitting
            // exactly where it was until midnight because Ebb had closed over
            // a card that never heard.
            if let current = pick, EbbSuppressionStore.suppressedIDs().contains(current.entryID) {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.35)) { clearPick() }
            }
            // Off the first paint deliberately: the feed renders, this fades in
            // when ready. Journal-tab launch work is exactly what the watchdog
            // killed the app for.
            // The `dismissedOn != todayKey` half of this guard is gone with the
            // × that wrote it. Leaving it would have been the bug in miniature:
            // anyone who had tapped Hide earlier on the day they install this
            // build would get a permanently-empty slot until midnight, on the
            // build whose whole point is that the slot is permanent.
            guard pick == nil else { return }

            // FAST PATH: the day's pick is already decided and its render
            // fields are cached -- draw it now, touching one row instead of
            // every row. The gates run live: a word quieted five minutes ago
            // still suppresses a card cached this morning.
            if pickDay == todayKey, !pickRenderCache.isEmpty,
               let data = pickRenderCache.data(using: .utf8),
               let cached = try? JSONDecoder().decode(CachedPick.self, from: data),
               !EbbSuppressionStore.suppressedIDs().contains(cached.entryID),
               let entry = entries.first(where: { $0.id == cached.entryID }),
               JournalHighlightSelector.maySurface(entry.text) {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.35)) { pick = cached.pick }
                onPick?(cached.pick)
                return
            }
            // Snapshot ON the main actor, then compute off it. `entries` are
            // SwiftData models; reading their properties inside the detached
            // task was a real cross-actor access of the main context -- the
            // same class of violation that caused the launch crash this
            // codebase already documents, just quieter here.
            let snapshots = entries.map(Snapshot.init)
            // Sampled on the main actor with the entries, for the same reason:
            // these are SwiftData models and reading them off it is the crash
            // class this codebase has already paid for twice. ~150 is enough
            // for a distribution to be meaningful and small enough that
            // embedding them costs a second, off-main, behind a card that is
            // already on screen.
            let library = Self.sampleLibrary(highlights)
            // Today's choice, if it has already been made. Reusing it is what
            // makes the card stable across visits and stops a second visit
            // spending a second entry's cooldown.
            let settled = (pickDay == todayKey) ? UUID(uuidString: pickEntry) : nil
            // `.userInitiated`, not `.utility`: he is looking at the screen
            // this fills. Utility priority is for work nobody is waiting on,
            // and it is exactly what let a busy launch starve this task into
            // "loads very late".
            let chosen = await Task.detached(priority: .userInitiated) {
                () -> JournalHighlightSelector.Pick? in
                guard let pick = Self.selectPick(from: snapshots, settledEntry: settled)
                else { return nil }
                return Self.upgradeToResonance(pick, library: library) ?? pick
            }.value
            if let chosen, pickDay != todayKey {
                // Recorded once per day, here rather than inside the selector,
                // so choosing is a pure function and only a settled choice is
                // spent from the cooldown.
                pickDay = todayKey
                pickEntry = chosen.entryID.uuidString
                if let data = try? JSONEncoder().encode(CachedPick(chosen)) {
                    pickRenderCache = String(decoding: data, as: UTF8.self)
                }
                JournalHighlightRecentStore.remember(chosen.entryID)
            }
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.35)) { pick = chosen }
            if let chosen { onPick?(chosen) }
        }
    }

    /// The day's deck. Read-only -- see `buildDeck` for where it is made.
    ///
    /// Until the deck exists this is the opener and the door, which is the
    /// honest minimum rather than a placeholder: the opener is already decided
    /// and the door always ends the deck.
    private func deck(pick: JournalHighlightSelector.Pick) -> [ThresholdDeckBuilder.Slot] {
        cachedDeck ?? [.card(Self.openerCard(pick)), .door]
    }

    /// Builds the day's deck once, in a task.
    ///
    /// This used to run inside `deck(pick:)` -- i.e. during body evaluation,
    /// mapping every entry into a snapshot on each pass and then writing
    /// `@State` from a `Task` to cache it. Mutating state during evaluation is
    /// the thing SwiftUI explicitly tells you not to do, and the snapshot map is
    /// O(entries) per evaluation on the journal feed's own render path, which is
    /// exactly the screen he called slow.
    ///
    /// The build itself runs OFF the main actor, exactly as `EbbView.build()`
    /// does the identical work thirty lines away. It used to be one synchronous
    /// call on the thread drawing the journal feed: `ThresholdDeckBuilder.build`
    /// runs the quiet-words scan over the full text of every entry, then
    /// candidate extraction on the cards it keeps -- all of it while the tab was
    /// trying to appear. That is the stall behind "make sure that my shit is
    /// actually fast as possible and responsive as possible".
    @MainActor
    private func buildDeck(pick: JournalHighlightSelector.Pick) async {
        // `entries` are SwiftData models: snapshotting stays on the main actor,
        // the same discipline the selection task above documents.
        // `words: 0`, and that is a real saving rather than a shortcut. The only
        // thing that ever read this field was the `.reference` card's "You wrote
        // N words here.", which no longer exists -- and computing it meant a
        // `stripStamp` plus a whitespace split over the FULL TEXT OF EVERY ENTRY
        // on the main actor, before any of the work moved off it. On the render
        // path of the screen he called slow, once per build, and now once per
        // carousel round as well: the cheapest way to keep the rounds free is
        // not to do the work at all.
        let snapshots = entries.map {
            EbbDeckBuilder.EntrySnapshot(
                id: $0.id, date: $0.modifiedDate ?? $0.dateImported,
                dateIsCertain: $0.modifiedDate != nil, text: $0.text,
                words: 0)
        }
        // Keeps are `@Model`s too and `isDue()` reads one, so they flatten here
        // beside the entries rather than inside the closure below.
        let keepSnapshots = keeps.map {
            ThresholdDeckBuilder.KeepSnapshot(
                id: $0.id, entryID: $0.entryID, passage: $0.passage,
                question: $0.question, sourceDate: $0.sourceDate,
                isDue: $0.isDue())
        }
        // Hoisted for the same reason: every argument the builder receives has
        // to be a value before the work leaves this actor. `openerCard` is a
        // member of a `View` and inherits its isolation, so it is called here.
        let opener = Self.openerCard(pick)
        let suppressed = EbbSuppressionStore.suppressedIDs()
        let recent = JournalHighlightRecentStore.recentIDs()
        // Round 0 is the day's seed exactly, so the day's first deck is the
        // same one every visit gets, all day. Later rounds perturb it -- a
        // different shuffle, not a different day.
        let round = deckRound
        let seed = EbbDeckBuilder.seed(for: .now) &+ UInt64(round)
        let dealt = dealtEntryIDs
        // His recent chat, for the "From your chat" card. Fetched HERE, on the
        // main context, bounded to forty rows and two properties -- the same
        // snapshot-then-detach discipline as the entries above, and never on
        // the first frame: this whole method runs from a `.task` keyed on a
        // pick that has already landed. The shape test and every gate run off
        // the main actor inside the builder.
        let chatMessages = Self.recentChatMessages(in: modelContext)
        let previousRoundDealtChat = chatReflectionRound == round - 1

        let built = await Task.detached(priority: .utility) { () -> [ThresholdDeckBuilder.Slot] in
            ThresholdDeckBuilder.build(todaysPick: opener,
                                       entries: snapshots,
                                       keeps: keepSnapshots,
                                       suppressed: suppressed,
                                       recentlyShown: recent,
                                       alreadyDealt: dealt,
                                       chatMessages: chatMessages,
                                       previousRoundDealtChatReflection: previousRoundDealtChat,
                                       daySeed: seed)
        }.value
        // A detached task outlives the `.task` that started it, so a deck built
        // for a pick or a suppression revision that has since been superseded
        // must not land on screen. Synchronous code had no such window; making
        // this async opens one, and this closes it.
        guard !Task.isCancelled else { return }
        cachedDeck = built
        // Remembered AFTER the deck lands, so a build that was cancelled or
        // superseded never marks its entries spent. Bounded by the archive.
        var dealtChat = false
        for slot in built {
            switch slot {
            case let .card(card): if let id = card.entryID { dealtEntryIDs.insert(id) }
            case let .chatReflection(reflection):
                dealtEntryIDs.insert(reflection.id)
                dealtChat = true
            case .door: break
            }
        }
        if dealtChat { chatReflectionRound = round }
    }

    /// His own messages from the last fortnight, newest first, forty at most.
    ///
    /// Not the journal thread: a message there is already about his writing
    /// and often IS a quoted passage of it, so reflecting on it here would be
    /// the window quoting itself. Two properties fetched rather than the row,
    /// because the row carries an embedding blob nobody here reads.
    ///
    /// `ChatMessage` has no relationships, so this is not the seeding-merge
    /// crash class `sampleLibrary` guards against; a failed fetch is an empty
    /// list, which is the card's ordinary absence.
    @MainActor
    private static func recentChatMessages(in context: ModelContext) -> [ThresholdDeckBuilder.ChatSnapshot] {
        guard let floor = Calendar.current.date(
            byAdding: .day, value: -ThresholdDeckBuilder.chatReflectionWindowDays, to: .now)
        else { return [] }
        let journalThread: UUID? = ChatPromptBuilder.journalThreadID
        var descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate<ChatMessage> {
                $0.isUser == true && $0.timestamp >= floor && $0.bookID != journalThread
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = 40
        descriptor.propertiesToFetch = [\.content, \.timestamp]
        return ((try? context.fetch(descriptor)) ?? []).map {
            ThresholdDeckBuilder.ChatSnapshot(date: $0.timestamp, text: $0.content)
        }
    }

    /// He chooses to write about something he told Cobux.
    ///
    /// Opens compose through the same door the widget uses
    /// (`cobux://journal/new`, presented from the root by `ContentView`), with
    /// the page seeded through the compose sheet's own crash-recovery slot:
    /// `JournalEntryComposeView.init` picks up a "new" draft that is longer
    /// than a bare stamp. So the sheet opens on a session stamp and one line
    /// -- "Earlier I told Cobux: “…”" -- and nothing else.
    ///
    /// Deletion-safe by construction, which is the whole reason this half of
    /// the instruction could ship: a draft is a file, not an entry. Cancel
    /// clears it, Save turns it into an entry only with whatever he actually
    /// wrote, and the entry is his -- not one the app wrote for him.
    ///
    /// A draft already sitting in that slot is a crashed session's writing
    /// and outranks this lead, exactly as a half-typed chat message outranks
    /// a prefill (`ChatView.applyPendingDeepLinkPrefill`): the door still
    /// opens, and it opens on HIS words.
    private func reflect(on reflection: ThresholdDeckBuilder.ChatReflection) {
        if JournalDraftStore.load(entryID: nil) == nil {
            let stamp = JournalSessionStamp.text(at: .now, previousSessionDate: nil,
                                                 ambient: AmbientContext.cached())
            JournalDraftStore.save(
                entryID: nil, title: "",
                text: stamp + "\n" + ThresholdDeckBuilder.reflectionLead(for: reflection) + "\n\n")
        }
        openURL(CobuxDeepLink.journalURL(newEntry: true))
    }

    private func currentSlot(pick: JournalHighlightSelector.Pick) -> ThresholdDeckBuilder.Slot {
        let d = deck(pick: pick)
        return d.indices.contains(slotIndex) ? d[slotIndex] : (d.first ?? .door)
    }

    /// Wraps rather than ending, so the window never becomes a thing he can
    /// exhaust or be "done" with.
    /// Advances a Keep's ladder when its card is genuinely reached.
    ///
    /// Driven by the slot CHANGING, not by `onAppear`. `onAppear` fires only on
    /// insertion, and slot 0 is always the day's pick, so a Keep -- which is
    /// always dealt at slot 1 or later -- was never marked at all. The rung
    /// stayed 0 and `lastSurfacedDate` stayed nil, which means it came back the
    /// next day, and the next, forever; and since only the FIRST due Keep is
    /// dealt, that one stuck Keep would have blocked every other he ever made.
    /// The exact opposite of "after a week, then longer".
    ///
    /// `onAppear` also over-fired in the other direction: the card lives in a
    /// `List`, so scrolling the row off and back re-inserts it, and each
    /// re-insertion advanced a rung -- two scroll-bys jumping 7 to 60.
    ///
    /// The same-day guard makes it idempotent either way.
    private func markSurfacedIfKeep(_ slot: ThresholdDeckBuilder.Slot) {
        guard case let .card(card) = slot else { return }
        let keepID: UUID?
        switch card {
        case let .kept(id, _, _, _), let .asked(id, _, _, _, _): keepID = id
        default: keepID = nil
        }
        guard let keepID, let keep = keeps.first(where: { $0.id == keepID }) else { return }
        // `markSurfaced` is itself idempotent within a day, so re-entering the
        // screen or scrolling the row back cannot advance a rung.
        keep.markSurfaced()
    }

    /// The passage a card may carry into chat. `.reference` returns nil by
    /// design: it points at an entry precisely because no passage cleared the
    /// quality guards, and nothing un-cleared may be quoted onward.
    private static func chatPassage(for card: EbbCard) -> String? {
        switch card {
        case let .passage(_, _, text, _), let .onThisDay(_, _, text),
             let .echo(_, _, text, _, _), let .kept(_, _, text, _): text
        case let .asked(_, _, question, passage, _): question + "\n\n" + passage
        case .reference, .eraDivider, .endCard: nil
        }
    }

    /// Whether the keep action applies: not already a keep, and carrying a
    /// guard-cleared passage.
    private static func canKeep(_ card: EbbCard) -> Bool {
        switch card {
        case .passage, .onThisDay, .echo: true
        case .kept, .asked, .reference, .eraDivider, .endCard: false
        }
    }

    /// He chooses to hold this -- the one way a keep is ever created, still.
    /// Skips silently if an unreleased keep of the same passage exists: a
    /// double-tap must not queue a double return.
    private func keepPassage(from card: EbbCard) {
        guard let entryID = card.entryID,
              let passage = Self.chatPassage(for: card) else { return }
        let existing = keeps.contains {
            $0.entryID == entryID && $0.passage == passage && $0.releasedDate == nil
        }
        guard !existing else { return }
        let sourceDate: Date = {
            switch card {
            case let .passage(_, date, _, _), let .onThisDay(_, date, _),
                 let .echo(_, date, _, _, _): date
            default: .now
            }
        }()
        modelContext.insert(JournalKeep(entryID: entryID, passage: passage,
                                        sourceDate: sourceDate))
    }

    /// How long a card holds the window before the next one arrives.
    ///
    /// Nine seconds, and the number is the feature. His words were *"it should
    /// always keep moving"*, not "it should flick past" -- these are sentences
    /// he wrote and has to actually read, often four lines of them, and a
    /// carousel that turns before he has finished reading is worse than one that
    /// never turns at all. Nine is a comfortable read of the longest card the
    /// window can hold, with room to look up from it.
    private static let autoAdvanceSeconds: Double = 9

    private func advance(pick: JournalHighlightSelector.Pick) {
        let count = max(1, deck(pick: pick).count)
        let next = (slotIndex + 1) % count
        // Wrapping past the door is where the deck refills. Bumping the round
        // re-fires the build task with a fresh seed and everything this sitting
        // has already dealt handed in, so what comes round is new writing --
        // "newer stuff coming in" -- rather than the same eight cards again.
        // The deck already on screen stays put until the new one lands, so the
        // dots never flicker down to two and back.
        //
        // `count > 1` matters: a one-slot deck (everything eligible quieted or
        // suppressed mid-day, leaving only the door) wraps on every single
        // advance, and without this each of those would deal a fresh round --
        // a rebuild every nine seconds, forever, for a window with nothing in
        // it. That is precisely the battery shape this feature must not have.
        if next == 0, count > 1 { deckRound += 1 }
        turn(to: next, forward: true)
    }

    /// The one place the deck turns, by hand or by the clock, either way.
    ///
    /// Two steps rather than one, and the order is the point. The outgoing
    /// page leaves with the transition it was LAST RENDERED with, so if the
    /// direction and the index changed in one transaction the new direction
    /// would reach only the incoming page and a back-swipe would arrive from
    /// the left while the old page also left to the left. Setting the
    /// direction first, without animation, and turning the index on the next
    /// runloop turn gives both pages the same direction. One turn of the loop
    /// is well under a frame.
    ///
    /// Reduce Motion: a 0.2 s crossfade, and no shimmer -- `shimmerTick` is
    /// left alone so the animator (which is not built anyway) has nothing to
    /// answer.
    private func turn(to index: Int, forward: Bool) {
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { turnsForward = forward }
        Task { @MainActor in
            guard !reduceMotion else {
                withAnimation(.easeOut(duration: 0.2)) { slotIndex = index }
                return
            }
            shimmerTick += 1
            withAnimation(Self.deckTurn) { slotIndex = index }
        }
    }

    /// Lets the day's pick go so the selection task chooses again, honestly.
    /// The deck goes with it: slot 0 is always the pick.
    private func clearPick() {
        pick = nil
        pickDay = ""
        pickEntry = ""
        pickRenderCache = ""
        cachedDeck = nil
        slotIndex = 0
        deckRound = 0
        dealtEntryIDs = []
        chatReflectionRound = nil
    }

    /// One slot backwards -- re-showing only cards already dealt today, so
    /// nothing here can touch cooldowns or the keep ladder
    /// (`markSurfaced` is idempotent within the day).
    private func retreat(pick: JournalHighlightSelector.Pick) {
        let count = max(1, deck(pick: pick).count)
        turn(to: (slotIndex - 1 + count) % count, forward: false)
    }

    /// The slot as a page that TURNS, not a label that changes.
    ///
    /// His words on 58: the deck *"should have a better animation so it moves
    /// and a user could peripherally see that it's changing -- a good
    /// animation."* Until now the card's text simply became the next card's
    /// text under a quarter-second ease, which from the corner of the eye is
    /// indistinguishable from nothing happening. Three things make a turn
    /// legible without asking to be looked at, and all three are one motion:
    ///
    /// 1. **Slide-and-settle.** The slot is keyed on its id, so a change is a
    ///    removal and an insertion: the outgoing page slides out and drops to
    ///    0.94 as it fades, the incoming one slides in from the trailing edge,
    ///    both on `deckTurn`'s soft ease. No spring here on purpose -- a page
    ///    of his own sentences must not bounce.
    /// 2. **The dot glides.** `pageDots` moves one accent dot across the row
    ///    with `matchedGeometryEffect`, in the same transaction.
    /// 3. **The shimmer.** A single hairline of the accent crosses the top
    ///    edge at the moment of the turn and is gone. A trace of light, not a
    ///    flash: `Color.cobuxAccent` at 55% on a one-point line.
    ///
    /// Manual swipes take the same motion, in the direction of the swipe.
    /// Under Reduce Motion the page crossfades, the dot changes colour in
    /// place, and the shimmer is not built: the hard gate, as everywhere.
    ///
    /// Clipped to the card's own shape, so the leaving page never draws over
    /// the calendar above or the feed below. `onAppear` and `onChange` stay on
    /// this container, not on the keyed page inside it, so `markSurfacedIfKeep`
    /// keeps firing exactly as often as it did.
    private func turningSlot(for slot: ThresholdDeckBuilder.Slot) -> some View {
        ZStack(alignment: .top) {
            slotView(for: slot)
                .id(slot.id)
                .transition(pageTransition)
            if !reduceMotion {
                turnShimmer
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: CobuxRadius.card, style: .continuous))
    }

    /// The page's own transition, read at the moment of the change. Reduce
    /// Motion: opacity only -- no offset, no scale.
    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let arriving: Edge = turnsForward ? .trailing : .leading
        let leaving: Edge = turnsForward ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: arriving).combined(with: .opacity),
            removal: .move(edge: leaving)
                .combined(with: .scale(scale: 0.94))
                .combined(with: .opacity))
    }

    /// Where the shimmer is in its crossing. `x` runs 0...1 across the card;
    /// `opacity` rises fast, holds, and is gone before the page has settled.
    private struct ShimmerState {
        var x: Double = 0
        var opacity: Double = 0
    }

    /// One hairline of the accent along the top edge, crossing once per turn.
    ///
    /// A `keyframeAnimator` off `shimmerTick` rather than a `repeatForever`:
    /// this is punctuation for a single moment, and a light that keeps
    /// crossing a card of his writing would be decoration on top of the
    /// sentences. Built only when motion is allowed (see `turningSlot`).
    private var turnShimmer: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let span = width * 0.42
            LinearGradient(colors: [.clear, Color.cobuxAccent.opacity(0.55), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: span, height: 1)
                .keyframeAnimator(initialValue: ShimmerState(), trigger: shimmerTick) { line, state in
                    line
                        .offset(x: -span + (width + span) * state.x)
                        .opacity(state.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.x) {
                        CubicKeyframe(1, duration: Self.deckTurnDuration)
                    }
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(1, duration: 0.10)
                        LinearKeyframe(1, duration: 0.25)
                        LinearKeyframe(0, duration: Self.deckTurnDuration - 0.35)
                    }
                }
        }
        .frame(height: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The turn's length and ease. ~0.55 s, his number, and a soft ease-out
    /// curve rather than a spring: the page decelerates into place and stops,
    /// with no overshoot to read as a bounce. Long enough to be caught
    /// peripherally, short enough that a swipe still feels answered.
    private static let deckTurnDuration: Double = 0.55
    private static let deckTurn = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: deckTurnDuration)

    @ViewBuilder
    private func slotView(for slot: ThresholdDeckBuilder.Slot) -> some View {
        switch slot {
        case let .card(card):
            thresholdCard(card)
        case let .chatReflection(reflection):
            chatReflectionCard(reflection)
        case .door:
            doorCard
        }
    }

    /// "From your chat": his own words from a recent conversation, and a
    /// quiet door to a blank page. The deck's card grammar exactly -- kicker,
    /// his words, the date -- and the door card's action grammar: a bare
    /// tinted Label, not a Button, because the whole window carries
    /// `.onTapGesture` and a tappable nested in a tappable is dead (the door
    /// card's own note). The Label's gesture wins over the window's by being
    /// inner, so tapping the words turns the deck and tapping the action
    /// opens compose.
    ///
    /// The app accent, not a month hue: this card is about no entry and so
    /// has no month, and chat is the accent's own surface. Nothing here asks a
    /// question or suggests what to write -- the words are his and the page
    /// is blank. Pull, never push.
    private func chatReflectionCard(_ reflection: ThresholdDeckBuilder.ChatReflection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("From your chat · \(Self.longDateFormatter.string(from: reflection.date))")
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .kerning(0.7)
                .foregroundStyle(Color.cobuxAccent)
                .padding(.trailing, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(reflection.excerpt)
                .font(CobuxTypography.passage(size: 17))
                .lineSpacing(4)
                .lineLimit(dynamicLineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
            Label("Reflect on this", systemImage: "square.and.pencil")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.cobuxAccent)
                .padding(.top, CobuxSpacing.xs)
                .contentShape(Rectangle())
                .onTapGesture {
                    lastInteraction = .now
                    reflect(on: reflection)
                }
                .accessibilityAddTraits(.isButton)
        }
        .padding(CobuxSpacing.cardPadding)
        // The steady slot height, before the background, so the wash fills
        // it -- see `body`'s note.
        .frame(maxWidth: .infinity, minHeight: slotMinHeight, alignment: .topLeading)
        .background(Color.cobuxAccent.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: CobuxRadius.card, style: .continuous))
        .contextMenu {
            Button { reflect(on: reflection) } label: {
                Label("Reflect on this", systemImage: "square.and.pencil")
            }
            // Suppression on the surface that shows it, same as every other
            // card here. The derived id lands in the same permanent set as
            // entry ids; the signal it bumps rebuilds this deck.
            Button(role: .destructive) {
                EbbSuppressionStore.suppress(reflection.id)
                cachedDeck = nil
                slotIndex = 0
                deckRebuild += 1
            } label: {
                Label("Never show this again", systemImage: "eye.slash")
            }
        }
    }

    /// Counts the cards, never him. Dots rather than "2 of 4", because a
    /// fraction of anything reads as progress toward finishing it.
    ///
    /// The accent dot GLIDES from its old place to its new one, part of the
    /// same turn as the page above it (`turningSlot`): the grey dots are the
    /// geometry sources and one accent dot matches whichever is current, so
    /// the turn's transaction carries it across the row. Under Reduce Motion
    /// the current dot changes colour in place, as it always did.
    private func pageDots(count: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<max(1, count), id: \.self) { index in
                Circle()
                    .fill(reduceMotion && index == slotIndex
                          ? Color.cobuxAccent : Color.secondary.opacity(0.25))
                    .frame(width: 5, height: 5)
                    .matchedGeometryEffect(id: index, in: dotsNamespace, isSource: true)
            }
        }
        .overlay {
            if !reduceMotion {
                Circle()
                    .fill(Color.cobuxAccent)
                    .frame(width: 5, height: 5)
                    .matchedGeometryEffect(id: slotIndex, in: dotsNamespace, isSource: false)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The last slot: an invitation into Ebb. This also fixes Ebb's real
    /// discoverability problem -- until now its only door was a toolbar glyph
    /// nobody would think to press.
    private var doorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EBB")
                .font(.caption2.weight(.bold))
                .kerning(2)
                // Ebb's own colour, the same one the toolbar door and the tip
                // use. Three doors in three hues was the defect; one token is
                // the fix, and the room's centered wordmark takes it too.
                .foregroundStyle(Color.cobuxEbb)
            Text("Walk further back through your own writing.")
                .font(CobuxTypography.display(colorScheme, size: 17, weight: .regular))
            // A door's action, in the grammar the app's OTHER door card already
            // uses -- `JournalListView.volumesDoor`, twenty lines of feed away,
            // draws "Bind a volume" as a bare tinted Label. Two door cards on
            // one screen were speaking two different control languages.
            //
            // This was `.cobuxPrimaryPill(tint: .cobuxAccent)`, and Rajan named
            // both things wrong with that: "the open ebb button is weriedly
            // sized also left indentation kidna lok weird".
            //
            // SIZE: the pill is the design system's ONE-PER-SURFACE filled
            // primary (`View+CobuxControls.swift`: "if a surface wants two
            // pills, one of them is actually a chip"). The journal feed already
            // spends its one saturation on the compose FAB, so a suggestion card
            // that appears only when it has something to say is a secondary
            // action by that doctrine, not a CTA. Stepping down a tier is the
            // token-clean answer; inventing a smaller pill would not have been.
            //
            // LEFT EDGE: inside a capsule the glyph starts one horizontal
            // padding in (20pt), so the kicker and the serif line began at the
            // card's content edge and the action's ink began 20pt right of it.
            // Aligning the capsule's BOX only moves the box. Dropping the
            // capsule puts the glyph on the same vertical as the two lines above
            // it, which is the one straight left edge he was missing -- and it
            // needs no negative-margin math, which this codebase bans outright.
            //
            // Tint is `cobuxEbb`, not `cobuxAccent`: the note above already says
            // three doors in three hues was the defect and one token is the fix.
            // That fix reached the kicker and stopped there, so this card was
            // still teal on top and violet at the bottom.
            //
            // Still not a Button, deliberately: the whole card carries
            // `.onTapGesture` below, so this is the affordance, not the target
            // -- and a tappable nested in a tappable is dead (see the dismiss
            // control's own note above).
            Label("Open Ebb", systemImage: "clock.arrow.circlepath")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.cobuxEbb)
                .padding(.top, CobuxSpacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CobuxSpacing.cardPadding)
        // The steady slot height, applied BEFORE the background so the wash
        // fills it. See `body`'s note: outside the background it drew a
        // transparent hole instead.
        .frame(minHeight: slotMinHeight, alignment: .topLeading)
        .background(Color.cobuxAccent.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: CobuxRadius.card, style: .continuous))
        .onTapGesture { onOpenEbb?() }
    }

    private func thresholdCard(_ card: EbbCard) -> some View {
        let hue = Color.cobuxMonthHue(card.month ?? Calendar.current.component(.month, from: .now),
                                      dark: colorScheme == .dark)
        return VStack(alignment: .leading, spacing: 8) {
            if let kicker = Self.kickerText(for: card) {
                Text(kicker)
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .kerning(0.7)
                    .foregroundStyle(hue)
                    .padding(.trailing, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(Self.bodyText(for: card))
                // The book face, both themes -- his writing is content, not
                // chrome. Size unchanged; only the face gains ceremony.
                .font(CobuxTypography.passage(size: 17))
                .lineSpacing(4)
                .lineLimit(dynamicLineLimit + 1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CobuxSpacing.cardPadding)
        // Both frames before the background, for the same reason: the wash has
        // to fill the steady slot, not hug the text inside it.
        .frame(maxWidth: .infinity, minHeight: slotMinHeight, alignment: .topLeading)
        // Washed in the month's own hue, so the window visibly looks INTO Ebb,
        // which uses the same atmosphere.
        .background(hue.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: CobuxRadius.card, style: .continuous))
        .contextMenu {
            // Releasing a keep is NOT deleting anything -- the entry and the
            // passage both stay exactly where they are. It only ends the
            // returning. Holding something you chose to hold, with no way to
            // set it down, is how a kindness becomes an obligation.
            if let keepID = card.keepID {
                Button {
                    if let keep = keeps.first(where: { $0.id == keepID }) {
                        keep.releasedDate = .now
                    }
                    cachedDeck = nil
                    deckRebuild += 1
                    slotIndex = 0
                } label: {
                    Label("Release this keep", systemImage: "hands.sparkles")
                }
            }
            if let id = card.entryID {
                Button { onOpen(id) } label: { Label("Open entry", systemImage: "chevron.up") }
                // The relational-counsel door: his own past words, one gesture
                // from principle-grounded counsel. Quoting cards only --
                // `.reference` carries no passage that cleared the guards, and
                // nothing un-cleared may reach chat.
                if let passage = Self.chatPassage(for: card) {
                    Button {
                        openURL(CobuxDeepLink.journalChatURL(prefill: passage))
                    } label: {
                        Label("Open in Chat", systemImage: "message")
                    }
                }
                // The Correspondence's ambient door: every entry-bearing card
                // here already cleared the gates to exist; tapping is pull,
                // and compose sits behind the lock. Available on .reference
                // too -- the card cleared the gates even when its passage
                // didn't, and answering needs no quote.
                Button { onWriteBack?(id) } label: {
                    Label("Write back", systemImage: "arrowshape.turn.up.left")
                }
                // The hold action, on the surface that returns his words --
                // closing the loop with the keep machinery. Only for cards
                // that are not already keeps.
                if Self.canKeep(card) {
                    Button {
                        keepPassage(from: card)
                    } label: {
                        Label("Keep this passage", systemImage: "bookmark")
                    }
                }
                // Suppression reachable from the surface that shows it. Ebb's
                // law is that this ships WITH amplification, not after.
                Button(role: .destructive) {
                    EbbSuppressionStore.suppress(id)
                    // `pick` too, not just the deck. The deck re-appends
                    // `todaysPick` as slot 0, so clearing only the cache left
                    // the card he had just banished sitting exactly where it
                    // was. And the epoch with it: the selection task is keyed
                    // on it, and a cleared pick under an unchanged key was a
                    // window collapsed to nothing until he left the screen.
                    if pick?.entryID == id {
                        clearPick()
                        selectionEpoch += 1
                    } else {
                        cachedDeck = nil
                        slotIndex = 0
                    }
                    deckRebuild += 1
                } label: {
                    Label("Never show this again", systemImage: "eye.slash")
                }
            }
        }
    }

    /// Built once. This runs from the card's `body`, so it used to construct a
    /// `DateFormatter` every time the card re-evaluated.
    private static let longDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    private static func kickerText(for card: EbbCard) -> String? {
        let f = longDateFormatter
        switch card {
        case let .onThisDay(_, date, _): return "On this day · \(f.string(from: date))"
        case let .passage(_, date, _, certain):
            return certain ? "From your archive · \(f.string(from: date))"
                           : "From your archive · imported \(f.string(from: date))"
        case let .echo(_, date, _, _, _): return "Your words × your books · \(f.string(from: date))"
        case let .kept(_, _, _, date): return "You kept this · \(f.string(from: date))"
        case let .asked(_, _, _, _, date): return "You asked yourself · \(f.string(from: date))"
        // Never dealt into this window: `ThresholdDeckBuilder.carriesAPassage`
        // rejects `.reference` on both the dealt path and the handed-in one.
        // The cases stay only because `EbbCard` is Ebb's vocabulary, not this
        // window's, and a switch over it has to be exhaustive.
        case .reference, .eraDivider, .endCard: return nil
        }
    }

    private static func bodyText(for card: EbbCard) -> String {
        switch card {
        case let .passage(_, _, text, _), let .onThisDay(_, _, text),
             let .echo(_, _, text, _, _): return text
        case let .kept(_, _, passage, _): return passage
        case let .asked(_, _, question, _, _): return question
        // "You wrote N words here." lived here, and Rajan named it exactly:
        // *"that's a useless information"*. Unreachable now rather than
        // reworded -- nothing in the journal builds a `.reference` card at all.
        case .reference, .eraDivider, .endCard: return ""
        }
    }

    private static func openerCard(_ pick: JournalHighlightSelector.Pick) -> EbbCard {
        switch pick {
        case let .onThisDay(id, date, passage): .onThisDay(entryID: id, date: date, text: passage)
        case let .fromArchive(id, date, passage): .passage(entryID: id, date: date, text: passage)
        case let .resonance(id, date, passage, highlight, book):
            .echo(entryID: id, date: date, passage: passage, highlight: highlight, bookTitle: book)
        }
    }

    // -------------------------------------------------------------- metrics

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var dynamicLineLimit: Int { dynamicTypeSize >= .accessibility1 ? 4 : 3 }

    /// The steady slot height: kicker line + the passage's full line budget
    /// at the passage face's metrics, plus the card's own padding. Derived
    /// from the same numbers the text uses, so a Dynamic Type change moves
    /// both together.
    private var slotMinHeight: CGFloat {
        let lineHeight: CGFloat = 17 * 1.35 + 4   // passage size + lineSpacing
        let lines = CGFloat(dynamicLineLimit + 1)
        return 16 + 8 + lines * lineHeight + 32   // kicker + gap + text + padding
    }

    // ------------------------------------------------------------ selection

    /// A value copy, so selection can run off the main actor without touching
    /// SwiftData models from another thread.
    private struct Snapshot: Sendable {
        let id: UUID
        let date: Date
        /// `modifiedDate` nil means the date is genuinely unknown -- an import
        /// with no parsable date collapses onto `dateImported`. Such an entry
        /// may never make a calendar claim, which without this flag it did:
        /// tier 1 could announce "On this day" on an import-date coincidence.
        let dateIsCertain: Bool
        let text: String
        init(_ entry: PersonalWritingEntry) {
            id = entry.id
            date = entry.modifiedDate ?? entry.dateImported
            dateIsCertain = entry.modifiedDate != nil
            text = entry.text
        }
    }

    /// A day-stable sample of standalone highlights, flattened off SwiftData.
    ///
    /// Day-seeded rather than random so the card does not change its mind if
    /// the view rebuilds, and `readsStandalone` because a fragment that cannot
    /// be understood on its own is a bad thing to set beside his writing --
    /// the same filter Flow already applies for the same reason.
    @MainActor
    private static func sampleLibrary(_ highlights: [Highlight]) -> [JournalPairFinder.HighlightSnapshot] {
        // NEVER traverse a book relationship while the seed/upgrade merge is in
        // flight. This reads `highlight.book` for up to 150 rows, which is the
        // documented Build-5 crash class, and an update launch always seeds --
        // so opening the Journal tab promptly after updating is exactly when it
        // would fire. Every comparable surface in the app guards this; this one
        // did not. No pairing today is a card without a resonance, which is its
        // ordinary state anyway.
        guard !SeedingStatus.shared.isSeeding else { return [] }
        guard !highlights.isEmpty else { return [] }
        let seed = Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
        // Sorted before striding: `@Query` order is not guaranteed, so an
        // unsorted stride sampled a different 150 highlights per launch and the
        // settled entry could pair with a different book line each time.
        let standalone = highlights
            .filter { FlowQueueBuilder.readsStandalone($0.text) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        guard !standalone.isEmpty else { return [] }
        let stride = max(1, standalone.count / 150)
        var sampled: [JournalPairFinder.HighlightSnapshot] = []
        var index = seed % max(1, stride)
        while index < standalone.count, sampled.count < 150 {
            let highlight = standalone[index]
            if let book = highlight.book {
                sampled.append(.init(id: highlight.id,
                                     text: highlight.text,
                                     bookTitle: book.title,
                                     tradition: book.tradition))
            }
            index += stride
        }
        return sampled
    }

    /// Turns a passage pick into a resonance pick when a book line genuinely
    /// stands out against it. Returns nil to leave the pick exactly as it was.
    ///
    /// Both sides are embedded HERE, in one pass, moments apart. That is not an
    /// optimisation -- it is what makes the claim on the card true. The stored
    /// entry vectors embed the whole entry including its timestamp stamp, so
    /// pairing on them while quoting a scored passage would put a sentence on
    /// screen next to a book line chosen for different text entirely.
    private nonisolated static func upgradeToResonance(_ pick: JournalHighlightSelector.Pick,
                                           library: [JournalPairFinder.HighlightSnapshot])
    -> JournalHighlightSelector.Pick? {
        guard !library.isEmpty else { return nil }
        let passage: String
        let entryID: UUID
        let date: Date
        switch pick {
        case let .onThisDay(id, when, text), let .fromArchive(id, when, text):
            passage = text; entryID = id; date = when
        // Already an echo. Re-pairing one would only swap the book line.
        case .resonance:
            return nil
        }

        guard let passageVector = EmbeddingService.embed(passage) else { return nil }
        var vectors: [(snapshot: JournalPairFinder.HighlightSnapshot, vector: [Float])] = []
        vectors.reserveCapacity(library.count)
        for snapshot in library {
            guard let vector = EmbeddingService.embed(snapshot.text) else { continue }
            vectors.append((snapshot, vector))
        }

        guard let pairing = JournalPairFinder.bestPairing(
            passage: passage,
            passageVector: passageVector,
            candidates: vectors,
            similarity: EmbeddingService.cosineSimilarity
        ) else { return nil }

        // Calibration before trust: the pairing is logged with its sigma so real
        // pairs from his real corpus can be read by a human before this is
        // believed. Never shown on the card.
        DiagnosticLog.log(String(format: "journal: resonance σ=%.2f | %@ ⇄ %@ (%@)",
                                 pairing.sigma,
                                 String(passage.prefix(60)),
                                 String(pairing.highlightText.prefix(60)),
                                 pairing.bookTitle))

        return .resonance(entryID: entryID, date: date, passage: passage,
                          highlight: pairing.highlightText, bookTitle: pairing.bookTitle)
    }

    /// Picks the day's entry, in three tiers.
    ///
    /// The first version only matched the EXACT calendar date in a past year,
    /// and that is a card he would see a handful of times a year: checked
    /// against his real archive on 2 September, there were zero prior entries
    /// on that date, so it rendered nothing at all. "On this day" is the best
    /// tier when it has material; it cannot be the only one.
    ///
    /// Each tier gets its own kicker, so the rule that fired is always stated
    /// on the card. That is the part of Fable's ruling that must not bend: he
    /// always knows WHY he is being shown something.
    private nonisolated static func selectPick(from snapshots: [Snapshot],
                                   settledEntry: UUID? = nil) -> JournalHighlightSelector.Pick? {
        // Already chosen today: rebuild the same card from the same entry
        // rather than running the tiers again against a moved cooldown.
        //
        // But it must still clear every gate. This path used to reconstruct the
        // pick with none of them, which broke the quiet-words promise in
        // precisely the flow the feature exists for: he sees a passage naming
        // his ex (the honest "once"), goes to Settings and quiets the name,
        // comes back -- and the settled path resurrected it, on the card, at the
        // head of the threshold deck, and as Ebb's opening card. Twice, for the
        // rest of the day, immediately after he used the control.
        //
        // Falling through to fresh selection when it fails is what makes the
        // choke point genuinely single.
        if let settledEntry, let entry = snapshots.first(where: { $0.id == settledEntry }),
           JournalHighlightSelector.maySurface(entry.text),
           !EbbSuppressionStore.suppressedIDs().contains(entry.id) {
            // The certainty gate applies here too: an import whose date is a
            // guess may not claim a calendar correspondence just because it was
            // today's settled pick.
            let sameCalendarDay = entry.dateIsCertain
                && Calendar.current.isDate(entry.date, equalTo: .now, toGranularity: .day) == false
                && Calendar.current.dateComponents([.month, .day], from: entry.date)
                    == Calendar.current.dateComponents([.month, .day], from: .now)
            // Falls THROUGH on nil rather than returning it. `pick(for:)` is
            // now optional, and a settled entry that yields no passage (an
            // entry edited down since this morning, a build that settled one
            // before the guards tightened) must be re-chosen, not answered
            // with an empty window for the rest of the day.
            if let settled = pick(for: entry, isOnThisDay: sameCalendarDay) { return settled }
        }
        let calendar = Calendar.current
        let now = Date.now
        guard let floor = calendar.date(byAdding: .day,
                                        value: -JournalHighlightSelector.minimumAgeDays,
                                        to: now) else { return nil }
        let today = calendar.dateComponents([.month, .day], from: now)
        let recent = JournalHighlightRecentStore.recentIDs()

        // Everything old enough, not shown recently, and not permanently
        // silenced. "Never show this again" has to mean never on every surface,
        // not only inside Ebb where the control happens to live.
        let suppressed = EbbSuppressionStore.suppressedIDs()
        let eligible = snapshots.filter {
            $0.date < floor && !recent.contains($0.id) && !suppressed.contains($0.id)
                && JournalHighlightSelector.maySurface($0.text)
        }
        guard !eligible.isEmpty else { return nil }

        // Each tier now hands back an ORDERED list rather than a single entry,
        // and the first one that actually yields a passage wins.
        //
        // This is the second half of removing `.reference`. Each tier used to
        // choose exactly one entry and `pick(for:)` degraded it to a word count
        // when its passages could not clear the quality guards -- so an entry
        // with nothing quotable in it did not merely produce a poor card, it
        // consumed the whole day's slot and blocked every entry behind it. The
        // tiers are unchanged in meaning and order; they simply keep walking.
        //
        // Lazily, and that matters: `pick(for:)` runs candidate extraction over
        // one entry's full text, so evaluating the whole archive to find one
        // card would be the launch stall this file has already paid for twice.
        // Almost every entry answers on the first try.

        // Tier 1: this exact calendar date in an earlier year.
        let onThisDay = eligible
            .filter {
                guard $0.dateIsCertain else { return false }
                let p = calendar.dateComponents([.month, .day], from: $0.date)
                return p.month == today.month && p.day == today.day
            }
            .sorted { $0.date > $1.date }
        // Only tier 1 earns the "On this day" claim. Tiers 2 and 3 are looser
        // correspondences, so they fall through as `.fromArchive` -- the card
        // must never assert a date connection it does not actually have.
        for entry in onThisDay {
            if let chosen = pick(for: entry, isOnThisDay: true) { return chosen }
        }

        // Tier 2: the same day OF THE MONTH, any earlier month. Still a real
        // correspondence he can see in the date, just a looser one.
        let sameDayOfMonth = eligible
            .filter { calendar.component(.day, from: $0.date) == (today.day ?? -1) }
            .sorted { $0.date > $1.date }
        for entry in sameDayOfMonth {
            if let chosen = pick(for: entry, isOnThisDay: false) { return chosen }
        }

        // Tier 3: anything from the archive. Started at a day-seeded index so it
        // is stable for the whole day rather than changing on every appearance,
        // which would make the surface feel like a slot machine, and walked
        // from there rather than giving up on one unlucky entry.
        let sorted = eligible.sorted { $0.date < $1.date }
        let start = (calendar.ordinality(of: .day, in: .era, for: now) ?? 0) % sorted.count
        for offset in 0..<sorted.count {
            let entry = sorted[(start + offset) % sorted.count]
            if let chosen = pick(for: entry, isOnThisDay: false) { return chosen }
        }

        // Nothing in the whole eligible archive holds a quotable passage. The
        // window stays empty, which is the honest state -- it is exactly the
        // state the `.reference` card existed to paper over.
        //
        // No `remember` anywhere in here. Choosing is a pure function; spending
        // an entry from the cooldown is the caller's decision, made once a day.
        return nil
    }

    /// One entry becomes the most specific card it honestly supports, or none.
    ///
    /// `nil` where this used to degrade to `.reference(words:)`. See
    /// `JournalHighlightSelector.Pick` for his report on that card and why the
    /// answer is the next entry rather than a better-worded word count.
    private nonisolated static func pick(for entry: Snapshot,
                             isOnThisDay: Bool) -> JournalHighlightSelector.Pick? {
        let body = JournalHighlightSelector.stripStamp(entry.text)
        let standalone = Set(body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) })
        let candidates = JournalHighlightSelector.candidates(in: entry.text)
        guard let passage = JournalHighlightSelector.best(from: candidates,
                                                          standaloneLines: standalone)
        else { return nil }
        return isOnThisDay
            ? .onThisDay(entryID: entry.id, date: entry.date, passage: passage)
            : .fromArchive(entryID: entry.id, date: entry.date, passage: passage)
    }
}

/// Which entries have been surfaced lately, so the same one cannot come back
/// for 60 days. Same idea as `FlowRecentlyShownStore`, scoped to the journal.
enum JournalHighlightRecentStore {
    private static let key = "cobux.journal.highlightRecent"

    static func recentIDs() -> Set<UUID> {
        guard let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Double]
        else { return [] }
        let cutoff = Date.now.timeIntervalSince1970
            - Double(JournalHighlightSelector.reshowCooldownDays) * 86_400
        return Set(stored.filter { $0.value > cutoff }.keys.compactMap(UUID.init(uuidString:)))
    }

    static func remember(_ id: UUID) {
        var stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        stored[id.uuidString] = Date.now.timeIntervalSince1970
        // Prune as we go so this cannot grow without bound.
        let cutoff = Date.now.timeIntervalSince1970
            - Double(JournalHighlightSelector.reshowCooldownDays) * 86_400
        stored = stored.filter { $0.value > cutoff }
        UserDefaults.standard.set(stored, forKey: key)
    }
}
