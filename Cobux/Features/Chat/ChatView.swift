import SwiftUI
import SwiftData
import PhotosUI
import UIKit
import CobuxCore

struct ChatView: View {
    @Bindable var claudeService: ClaudeService
    /// Set by `ContentView.onOpenURL` when the iPhone home-screen/Lock-Screen
    /// widget is tapped -- the widget always shows a highlight from a specific
    /// book, but until now tapping it only ever opened the generic Chat tab
    /// (`cobux://chat`), never the book that quote actually came from. Consumed
    /// once (applied to `selectedBookID`, then cleared) rather than a persistent
    /// binding this view keeps reading from.
    @Binding var pendingDeepLinkBookID: UUID?
    /// The specific highlight the tapped widget was showing, when the deep link
    /// carried one. Consumed by pre-filling the composer with that quote so the
    /// user lands ready to discuss it — pre-filled, never auto-sent, so they can
    /// edit or add context before sending.
    @Binding var pendingDeepLinkHighlightID: UUID?
    @Binding var pendingDeepLinkPrefill: String?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    /// For the "Open Settings" action on the API-key alert (`cobux://settings`).
    @Environment(\.openURL) private var openURL
    @Query private var books: [Book]
    /// Situation threads, so a thread selected here can carry its own name and
    /// pinned note. Read-only: nothing in chat ever creates or edits one.
    @Query private var situations: [SituationThread]
    @State private var showingSituations = false
    /// An EXISTENCE PROBE, not the journal.
    ///
    /// This used to be `@Query private var personalWritingEntries:
    /// [PersonalWritingEntry]` -- an unbounded query holding every journal
    /// entry he has ever written, full text, permanently resident on the tab
    /// the app launches into. Two things made that indefensible. First, the
    /// render path never reads a single entry: its one consumer
    /// (`journalWeaveNotice`) asks only `.isEmpty`. Second, journal entries are
    /// by design never deletable, so that array only ever grows -- the cost of
    /// opening the app rises every time he writes.
    ///
    /// `fetchLimit = 1` answers the only question `body` actually asks, at a
    /// fixed cost of one row forever. It stays a `@Query` rather than becoming
    /// a count captured in `.task` because the answer must stay LIVE: write a
    /// first journal entry in the Journal tab, come back to chat, and the
    /// journal-context line above the composer has to appear. A
    /// `.task`-captured count would not (a `TabView` keeps this view mounted,
    /// so neither `.task` nor `.onAppear` re-runs on a tab switch), and the
    /// failure would be silent -- his writing feeding replies with the app
    /// never once saying so, and no way to switch it off from here.
    ///
    /// The real rows are fetched, on the main actor, at the two moments that
    /// genuinely need them -- see `journalEntriesForPrompt()`.
    @Query(ChatView.journalProbeDescriptor) private var journalProbe: [PersonalWritingEntry]

    private static var journalProbeDescriptor: FetchDescriptor<PersonalWritingEntry> {
        var descriptor = FetchDescriptor<PersonalWritingEntry>()
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// Whether he has written anything at all. The only journal fact `body` needs.
    private var hasPersonalWriting: Bool { !journalProbe.isEmpty }

    /// The journal, fetched at the moment a prompt is actually being built.
    ///
    /// Main actor, always: these are `@Model` rows, and moving them across an
    /// actor hop is this app's known crash class. This makes the fetch LATE --
    /// it happens behind the typing indicator, or as Voice Mode is opening --
    /// never in front of a frame the user is waiting on.
    ///
    /// Unbounded on purpose. The retrieval step ranks across the whole journal;
    /// capping it here would silently narrow what the model can draw on, and a
    /// prompt built from a sample of his writing while presenting itself as
    /// grounded in his writing is worse than a slower send.
    private func journalEntriesForPrompt() -> [PersonalWritingEntry] {
        (try? modelContext.fetch(FetchDescriptor<PersonalWritingEntry>())) ?? []
    }

    /// Whether book-thread replies may draw on his journal.
    ///
    /// Defaults OFF as of build 58, and is switched on by Face ID, not by a
    /// tap. Rajan's ruling: *"when the user first installs the app and goes
    /// to the Journal section it uses Face ID and that gives the chat the
    /// journal context … if the user uses the chat first and does not have
    /// the Journal context on, it's gonna show off, and when he clicks Turn
    /// on it's gonna [ask Face ID] … until it's turned off it's gonna always
    /// stay on."* So: the first successful journal unlock
    /// (`JournalLockStatus.grantChatContextIfNeverRefused`) sets this true; "Turn off" below is
    /// free and also records `personalWritingContextExplicitlyOff`, which a
    /// later journal unlock respects; "Turn on" asks Face ID first. The
    /// content (health, relationships, family, financial stress) is genuinely
    /// personal, so the switch stays explicit, visible and always reachable
    /// (see `SettingsView`'s matching toggle), never a buried flag. When off,
    /// `SearchService.buildSplitContext`/`buildSplitContextForBook` skip the
    /// retrieval step entirely — no query embedding, no ranking, nothing
    /// added to any prompt — not just a UI-level hide.
    ///
    /// Must stay byte-identical to `SettingsView`'s copy of this line, or the
    /// toggle there and the gate here would disagree on a fresh install.
    @AppStorage(JournalLockStatus.contextEnabledKey) private var personalWritingContextEnabled: Bool = false
    /// Set by "Turn off" (here or in Settings) and cleared by a successful
    /// "Turn on". Read by `JournalLockStatus.grantChatContextIfNeverRefused`, so that a journal
    /// unlock after he has deliberately turned the context off does not
    /// silently turn it back on -- "until it's turned off it's gonna always
    /// stay on" cuts both ways.
    @AppStorage(JournalLockStatus.contextExplicitlyOffKey) private var personalWritingContextExplicitlyOff: Bool = false
    /// The same shared lock the journal thread's `JournalLocked` wrapper
    /// reads, so a "Turn on" here and a journal unlock are one Face ID state,
    /// not two.
    @State private var lockStatus = JournalLockStatus.shared
    @State private var isAuthenticatingJournalContext = false
    /// Defaults ON as of 2.5.3. Rajan had reserved the decision on whether real
    /// names from journals may appear in replies; he has now made it. Must stay
    /// identical to `SettingsView`'s copy of this key, or the toggle and this
    /// retrieval gate would disagree. Existing installs are unaffected either
    /// way -- `@AppStorage` only applies a default when the key is absent, so
    /// anyone who already chose a value keeps it.
    @AppStorage("useRealNamesInLifeExamples") private var useRealNamesInLifeExamples: Bool = true
    /// Whether one conversation may draw on the others.
    ///
    /// Default ON: this is his own chat content resurfacing inside the same
    /// chat product, a lower privacy tier than journal-into-books. The switch
    /// exists so the behaviour is legible and revocable, not because it should
    /// start off.
    @AppStorage("crossChatMemoryEnabled") private var crossChatMemoryEnabled: Bool = true

    /// One transcript row. `retry` is set only on a transient error bubble:
    /// the words (and photos) of the turn that failed, so "Try again" can
    /// resend exactly what he sent without him retyping it -- see
    /// `completeReveal` and `retryFailedTurn`.
    private typealias ChatRow = (id: UUID, content: String, isUser: Bool, timestamp: Date, referencedBooks: [String], isError: Bool, isStreaming: Bool, referencedFigureID: UUID?, imageIDs: [UUID], retry: (text: String, imageIDs: [UUID])?)
    @State private var messages: [ChatRow] = []
    /// False for exactly the launch frame, until `.task`'s deferred
    /// `loadChatHistory` lands.
    ///
    /// It exists so that frame can be HONEST. `messages` is empty both before
    /// the history is read and when there genuinely is none, and without this
    /// flag the deferral would flash "How can I help?" and its prompt chips at
    /// someone who has a thread full of messages -- trading a stall for a lie,
    /// which is not the trade. While this is false the transcript area says it
    /// is loading instead.
    @State private var hasLoadedHistory = false
    /// The thread as the store held it when `messages` was last loaded from
    /// it -- see `.task` for what this is compared against and why.
    @State private var loadedHistoryFingerprint: ChatHistoryFingerprint?
    @State private var inputText = ""
    /// Images staged for the next send -- already downscaled and stored, so a
    /// chip is cheap and cancelling just removes files.
    @State private var attachedImageIDs: [UUID] = []
    @State private var photoPickerItems: [PhotosPickerItem] = []
    /// Drives `.photosPicker(isPresented:)` on the composer row.
    ///
    /// The picker is presented by a MODIFIER on a stable host, not by a
    /// `PhotosPicker` view sitting in the composer -- which is what shipped in
    /// 52 and what he reported again from his phone: *"the photo selection in
    /// chat still not working not getting attachte to the cobux chat just
    /// shows top right buffering"*, with the system sheet's Add control
    /// replaced by a spinner. A `PhotosPicker` view IS its own presentation
    /// source, and that one carried `.disabled(...)`, an `.onChange` and an
    /// `.alert` on the very same node -- a second presentation on a node that
    /// already owns one, plus a `maxSelectionCount` recomputed from state the
    /// load itself mutates. The journal's picker (which works) has none of
    /// that: a constant selection count, and its `.onChange`/`.alert` on a
    /// container. This is the same separation, done with Apple's own modifier
    /// form: a plain `Button` opens it, the composer row hosts it, and the
    /// alert lives on a different node entirely.
    @State private var showingPhotoPicker = false
    /// The selection cap, FROZEN when the picker is opened rather than
    /// recomputed from `attachedImageIDs`. A presented picker whose
    /// configuration changes underneath it (which it did, the moment the first
    /// photo landed) is reconfiguring a sheet the user is standing in.
    @State private var photoPickerLimit = ChatImageStore.maxImagesPerMessage
    /// How many picks are still loading -- drives placeholder tiles in the
    /// strip. Chat had no such state at all, so a slow iCloud original showed
    /// LITERALLY NOTHING for up to twenty seconds: no chip, no tile, no
    /// spinner. The journal has had these tiles since the loader shipped
    /// (`JournalEntryComposeView.photosLoading`); this is the same idiom.
    @State private var photosStaging = 0
    /// Set when a picked photo could not be read in time (an iCloud original
    /// still downloading, most often). The journal shows the same alert for
    /// the same loader; a pick that yields nothing must never just vanish.
    @State private var photoLoadFailed = false
    /// Bumped on every successful send purely to change the composer
    /// `TextField`'s SwiftUI identity — see `sendMessage`.
    @State private var composerGeneration = 0
    @State private var isStreaming = false
    @State private var conversationHistory: [AIMessage] = []
    @State private var streamTask: Task<Void, Never>?
    /// The one stream `isStreaming`/`streamTask` are currently allowed to
    /// speak for. Set the instant a new stream starts; only `markNetworkDone`
    /// for THIS id may flip `isStreaming`/`streamTask` back — see its own
    /// comment for the race this closes (switching threads mid-reply, which
    /// cancels the old stream, then sending a new message before the old
    /// stream's async cancellation handler actually lands).
    @State private var activeStreamID: UUID?

    /// Raw text received so far per active stream — the network can deliver
    /// chunks in bursty batches, so what's actually *displayed* is paced out
    /// from this buffer by `revealTickers` instead of being dumped instantly.
    @State private var streamBuffers: [UUID: String] = [:]
    @State private var streamNetworkDone: Set<UUID> = []
    @State private var pendingFinalize: [UUID: (userMessage: String, referencedTitles: [String], notice: String?, wasCancelled: Bool, imageIDs: [UUID])] = [:]
    @State private var revealTickers: [UUID: Task<Void, Never>] = [:]
    @State private var showNoAPIKeyAlert = false
    @State private var showLibrarySyncingAlert = false
    @State private var showClearChatAlert = false
    @State private var symposiumModeEnabled = false
    @State private var showingDecisionConsultation = false
    @State private var showingVoiceMode = false
    @State private var scrollTarget: UUID?
    @FocusState private var isInputFocused: Bool
    @State private var monthlyEstimate: Double = 0
    /// nil = the general "Cobux" thread; a Book's id = that book's own
    /// persistent, scoped thread (see `ChatMessage.bookID`).
    ///
    /// Restored from the last thread he was in, not reset to General on every launch.
    /// Plain `@State` meant relaunching always landed on General and then restored
    /// GENERAL's scroll position -- so the careful per-thread scroll restore below was
    /// doing precise work on the wrong thread. His ask: "fix the coming in the chat
    /// Cobux it should open to wherever the user last left the Cobux chat reading."
    @State private var selectedBookID: UUID? = {
        guard let stored = UserDefaults.standard.string(forKey: lastThreadKey) else { return nil }
        return stored.isEmpty ? nil : UUID(uuidString: stored)
    }()

    /// "" encodes the General thread, distinct from an absent key (never chosen).
    fileprivate static let lastThreadKey = "cobux.chat.lastThreadID"
    @State private var showSymposiumExplanation = false
    @State private var showingBookThreadPicker = false
    @AppStorage("hasSeenSymposiumExplanation") private var hasSeenSymposiumExplanation = false

    /// Tracks which messages are currently on screen (rows add themselves on
    /// `.onAppear`, remove on `.onDisappear`) so the topmost visible one's
    /// `timestamp` can be persisted as the resume point on `.onDisappear` of the
    /// whole view. `loadChatHistory` had zero scroll-position persistence before
    /// this -- chat always rendered from the natural top of history (oldest
    /// message) with no memory of where the user last left off, however deep
    /// they'd scrolled into a long thread. `timestamp`, not `msg.id`, is what's
    /// persisted: `loadChatHistory` regenerates a fresh random `id` for every
    /// message on every single load (see its own comment), so an `id` saved in
    /// one session can never match anything in a later one -- `timestamp` comes
    /// from the underlying `ChatMessage` model and is the one value that's
    /// actually stable across reloads.
    @State private var visibleMessageTimestamps: Set<Date> = []

    /// Gates every scroll-position write until the initial restore for the
    /// current thread has actually landed. Without this, the reactive persist
    /// on `visibleMessageTimestamps` fires while the list is still rendering
    /// at its natural top -- rows' own `.onAppear` can even run BEFORE this
    /// view's `.onAppear` reads the saved value -- so the position being
    /// restored was overwritten with "top of thread" in the exact window the
    /// restore needed it. Set true either when `restoreScrollPosition`
    /// declines (nothing saved -- the natural top IS the truth) or once the
    /// restore's `scrollTo` has been issued; reset on every thread switch.
    @State private var hasRestoredScroll = false

    /// Soft warning threshold — Rajan's brother's key is capped around $5/mo;
    /// this isn't fetched from anywhere (Anthropic doesn't expose the cap
    /// itself to the app), it's just a reasonable default matching that
    /// convention so a warning shows before a confusing hard stop rather than
    /// never at all. See `UsageTracker` for how the estimate itself is built.
    private let budgetWarningThreshold: Double = 4.0

    private var isJournalThread: Bool {
        selectedBookID == ChatPromptBuilder.journalThreadID
    }

    var body: some View {
        NavigationStack {
            // The journal thread's content (its history quotes journal
            // entries back verbatim) sits behind the same Face ID gate as
            // every Journal screen -- one shared `JournalLocked`, not a
            // reimplementation. Wrapping only the chat body keeps the toolbar
            // thread picker reachable, so a locked user can still switch to
            // any other thread without authenticating.
            Group {
                if isJournalThread {
                    JournalLocked { chatBody }
                } else {
                    chatBody
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // THE OVERFLOW SITS ON THE LEADING SIDE, and that placement is
                // the whole fix for a wordmark that shipped hard left.
                //
                // A `.principal` title is centred in the BAR, but only while the
                // centred rectangle clears both side groups; the instant it
                // would overlap one, the bar shoves it aside instead of
                // truncating. Measured with CoreText at the exact faces used
                // here: COBUX is 85.1pt (19pt New York Black + 2.5 tracking --
                // the light theme, the wider of the two `CobuxTypography.display`
                // faces), the SITUATIONS pill 81.5pt of content, the overflow
                // glyph 20pt. Under pre-26 bar arithmetic those two trailing
                // items still left the title ~124pt on a 375pt phone, which is
                // why this centred when it was written. iOS 26 wraps EVERY bar
                // item in its own glass capsule -- the same congestion
                // `JournalEntryComposeView` had to solve by evicting two items
                // from its bar -- and that padding is the one number this code
                // cannot measure from here. At a plausible 12pt a side the two
                // items plus their spacing and the bar margin come to ~174pt,
                // against a budget of 137.5pt for a 100pt title on a 375pt bar.
                // Over budget by more than the wordmark is wide, on every
                // shipping iPhone. That is his screenshot.
                //
                // Splitting the two doors one per side is what buys the budget
                // back, and it buys enough of it that the unmeasurable number
                // stops mattering: one trailing item lands near 121pt of the
                // 137.5 available, and the centring does not break until iOS
                // spends more than 20pt a SIDE on that capsule. Situations
                // stays on the RIGHT because that is where he asked for it
                // ("it should be up on the top right"); the overflow is chrome
                // and does not care which side it lives on. Nothing can collide
                // with it here -- this is a `NavigationStack` root with no
                // pushes anywhere in the chat, so the leading slot is empty and
                // no back button ever claims it.
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            if symposiumModeEnabled {
                                symposiumModeEnabled = false
                            } else if hasSeenSymposiumExplanation {
                                symposiumModeEnabled = true
                            } else {
                                showSymposiumExplanation = true
                            }
                        } label: {
                            if symposiumModeEnabled {
                                Label("Symposium Mode", systemImage: "checkmark")
                            } else {
                                Label("Symposium Mode", systemImage: "person.3.fill")
                            }
                        }

                        Button {
                            showingDecisionConsultation = true
                        } label: {
                            Label("Decision Consultation", systemImage: "scale.3d")
                        }

                        Button(role: .destructive) {
                            showClearChatAlert = true
                        } label: {
                            Label("Clear Chat", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }

                ToolbarItem(placement: .principal) {
                    // A sheet-presented `List`, not a `Menu` -- a flat `Menu`
                    // with 15+ books (the real current library size) doesn't
                    // scroll reliably on device (confirmed live: "the scroll
                    // of this dropdown is cooked"). A `List` uses the same
                    // scrolling machinery as every other list in the app.
                    Button {
                        showingBookThreadPicker = true
                    } label: {
                        // The wordmark itself is the identity; the thread
                        // picker is a clearly subordinate row beneath it --
                        // fixes the old single-line "Cobux" toolbar title
                        // that was too small (14pt) to read as a wordmark at
                        // all, and conflated brand with navigation in one row.
                        VStack(spacing: 1) {
                            Text("COBUX")
                                .font(chatWordmarkFont)
                                .tracking(2.5)
                                // Ink into crimson by the X -- a fill, so the
                                // 85.1pt budget above is untouched. See
                                // `ShapeStyle.cobuxWordmark`.
                                .foregroundStyle(.cobuxWordmark)
                            HStack(spacing: 3) {
                                Text(currentThreadLabel)
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(.secondary)
                        }
                        // CAPPED, because on a book thread the widest thing in
                        // this stack is not the wordmark. The thread row
                        // measures 225.5pt on "The 7 Habits of Highly Effective
                        // People" and 142.4pt on "Thinking, Fast and Slow"
                        // against the wordmark's 85.1 -- an uncapped title view
                        // that wide walks straight back into the trailing group
                        // and shoves the wordmark off centre again, for some
                        // threads and not others, which is the worst version of
                        // this bug to be told about.
                        //
                        // The cap is on the STACK, not on the label: a `VStack`
                        // centres its rows, so a short thread name keeps its
                        // chevron beside it instead of being padded out to the
                        // cap, while a long one truncates and the title view's
                        // width stays the same 100pt no matter which thread is
                        // open. Every font in here is a fixed point size and the
                        // pill below is capped at `.large`, so this whole bar's
                        // geometry is invariant under Dynamic Type -- the
                        // centring holds at the largest accessibility size for
                        // the same reason it holds on a 375pt phone.
                        .frame(maxWidth: 100)
                    }
                }

                // Situations, given its own entrance in the top bar.
                //
                // It shipped as a section inside the thread-picker sheet, which
                // means nobody would ever find it -- Rajan's own read: "it's
                // hidden up in the chat really simply... I don't think a user is
                // gonna ever find it. It should be up on the top right with a
                // special icon, something not regular, so they're curious: oh
                // what's this icon here — and then they click it and find out."
                //
                // That is exactly how Flow became something people use, so it
                // gets the same treatment: its own glyph, its own colour, and a
                // subtle count so an existing situation is visibly waiting.
                //
                // The non-empty badge is a CLOCK, not a checkmark. It shipped as
                // `person.crop.circle.badge.checkmark`, which meant that having a
                // situation at all made the door wear a tick -- a completion
                // state, on a surface where nothing is ever completed. Rajan's
                // standing ruling: "this shows a tick thats bad... that doesn't
                // mean it is supposed to be a work or task." A clock says the
                // one true thing the paragraph above already claims for this
                // badge -- something is waiting -- without grading him for it.
                ToolbarItem(placement: .topBarTrailing) {
                    // THE NAME, not a glyph -- the half of his reminder that
                    // was missed. He grouped the two doors in one sentence:
                    // "like that we have like situation and EBB, they should
                    // actually be much more visible, rather than having like
                    // an icon to it, there it should mention something like
                    // EBB." Ebb's door was rebuilt as a wordmark and this one
                    // was left as a tinted glyph, so the fix landed for one of
                    // the two features he named together. A tinted glyph still
                    // reads as chrome; the registry says so in as many words
                    // for Ebb -- "the name only existed in the accessibility
                    // label, never on screen" -- and that was equally true
                    // here. Same pill grammar as the EBB door, in Situations'
                    // own colour, so the two doors are visibly siblings.
                    //
                    // NO COUNT, and the width is not a matter of taste.
                    //
                    // This is now the ONLY trailing item (see the overflow's
                    // note at the top of this toolbar for why it moved), so the
                    // budget it has to stay inside is: bar margin 16pt, plus
                    // this item, must clear the 100pt title view's centred
                    // rectangle -- 137.5pt on the narrowest shipping iPhone,
                    // more on every other one. Measured with CoreText, this
                    // label is 69.5pt and the pill 81.5pt with its padding,
                    // leaving 40pt for iOS 26's glass capsule to spend on it
                    // before the wordmark moves. The first attempt at this
                    // button cost 101.5pt empty and 124.3pt reading
                    // "SITUATIONS - 1", which is over that budget with or
                    // without the overflow beside it -- and because the count is
                    // a `@Query`, the identity would have MOVED as situations
                    // were created. Over budget does not truncate; it slides the
                    // wordmark off centre.
                    //
                    // So: no kerning (10 characters x 1.4 = 14pt of pure
                    // cost), 6pt side padding rather than 9. The label is the
                    // same width forever, and the count stays in the
                    // accessibility label, where it was always correct. The
                    // comment above once promised a visible count; the honest
                    // version is that a count does not fit beside the wordmark,
                    // and the wordmark wins.
                    //
                    // The Dynamic Type cap is not cosmetic either: `.caption2`
                    // scales and `chatWordmarkFont` is a fixed 19pt that does
                    // not, so at accessibility sizes an uncapped pill runs
                    // wider than the whole bar and truncates to "SITUAT...",
                    // which is less legible than the glyph it replaced. Capped,
                    // it is also what makes the centring above invariant under
                    // text size rather than merely correct at Large.
                    Button { CobuxTip.situations.markUsed(); showingSituations = true } label: {
                        Text("SITUATIONS")
                            .font(.caption2.weight(.bold))
                            .lineLimit(1)
                            .foregroundStyle(Color.cobuxSituation)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .background(Color.cobuxSituation.opacity(0.14), in: Capsule())
                            .dynamicTypeSize(...DynamicTypeSize.large)
                    }
                    .accessibilityLabel(situations.isEmpty
                                        ? "Situations, none yet"
                                        : "Situations, \(situations.count)")
                }
            }
            // What is left here is pure in-memory state: three functions that
            // read `books` (already resident) and write `@State`. Nothing in
            // this closure touches the keychain or the store, so it cannot
            // delay the frame it runs in front of.
            .onAppear {
                validateRestoredThread()
                applyPendingDeepLinkBookID()
                applyPendingDeepLinkPrefill()
                // No `checkAPIKey()` here any more, on a re-appear or
                // otherwise. It ran a blocking keychain read in the frame of
                // every tap back to Chat. `.task` below shares this
                // modifier's trigger exactly -- under the UIKit tab shell
                // both fire on every switch to this tab -- and already calls
                // it behind a `Task.yield()`, so a key added or removed in
                // Settings is still reflected on the way back, one turn later.
            }
            // THE LAUNCH FRAME. Chat is the tab the app opens into, so
            // everything in this closure used to run BEFORE the app's very
            // first frame existed: a blocking keychain `SecItemCopyMatching`
            // (the first keychain access of the process, which is where the
            // service actually unlocks and pages in), then a 400-row
            // `ChatMessage` fetch, then a map over all 400, then
            // `alternatingHistory` over all 400 again. All of it under his
            // thumb, all of it in front of the first pixel.
            //
            // One `Task.yield()` is the whole fix. `.task` starts in the same
            // main-actor turn as the first render pass; yielding puts the rest
            // of this behind that turn, so the frame goes up -- toolbar,
            // atmosphere, composer, and a transcript area that SAYS it is
            // loading -- and the store read happens on the next turn.
            //
            // Nothing here moves off the main actor: `loadChatHistory` reads
            // `@Model` rows and that is main-actor-only in this codebase, by
            // hard rule. This makes it LATE, not concurrent.
            .task {
                await Task.yield()
                checkAPIKey()
                if !hasLoadedHistory {
                    loadChatHistory()
                    hasLoadedHistory = true
                } else if !isStreaming, historyFingerprint(for: selectedBookID) != loadedHistoryFingerprint {
                    // A RE-APPEAR, and the store has moved since the last load.
                    //
                    // Under the UIKit tab shell this `.task` restarts on every
                    // switch back to Chat, and it used to call
                    // `loadChatHistory()` unconditionally: a 400-row fetch, a
                    // map over all 400, `alternatingHistory` over them again,
                    // then `messages` replaced wholesale -- every row under a
                    // FRESH `UUID`, so the transcript's entire identity
                    // changed, every bubble was rebuilt and the scroll
                    // position jumped and was restored, all in the moment
                    // after the tap. That is "whenever I click it still
                    // loads", on the tab he taps most.
                    //
                    // Now the reload happens only when it can change anything:
                    // when the thread's row count or newest timestamp in the
                    // store differs from what was loaded. Two indexed queries,
                    // one row at most. Glancing at Library and coming back
                    // costs nothing; a restore, an import or a save from any
                    // other surface still shows up on the way back exactly as
                    // it did before. Never mid-stream: while a reply is
                    // arriving the in-memory transcript is the truth and the
                    // store is behind it, and a reload here dropped the
                    // streaming bubble on the floor.
                    loadChatHistory()
                }
                // A single `UserDefaults` double read -- kept here rather than
                // in `.onAppear` only so the whole launch sequence reads in
                // one place.
                monthlyEstimate = UsageTracker.currentMonthEstimate()
                schedulePhotoPrune()
            }
            .onDisappear {
                persistScrollPosition(forThread: selectedBookID)
            }
            // The `.onDisappear` above is not enough on its own -- confirmed real
            // bug, not a stale-build issue. `ContentView`'s `TabView` keeps every
            // tab's content alive in the view hierarchy; switching away from the
            // Chat tab does NOT reliably fire `.onDisappear` on it (well-documented
            // SwiftUI TabView behavior), which is exactly how a user naturally
            // leaves chat to go read a book or take a quiz. So in the most common
            // real-world path, position was never actually being persisted at all.
            // Persisting reactively on every change to the visible set, not just at
            // a terminal disappear event, makes this correct regardless of whether
            // the view ever actually disappears.
            .onChange(of: visibleMessageTimestamps) { _, _ in
                persistScrollPosition(forThread: selectedBookID)
            }
            .onChange(of: selectedBookID) { oldValue, newValue in
                // Switching threads mid-stream: cancel rather than let a
                // response keep streaming into a thread the user has left.
                // v1 deliberately keeps this simple — one active stream at a
                // time, tied to whichever thread is open (see design notes).
                stopStreaming()
                // Staged photos belong to the thread they were staged in. Left
                // alone they rode silently into the next thread's first send --
                // a photo of one person attached to a message about another.
                // Claude and ChatGPT both drop attachments on a conversation
                // switch; the honest default is the same here, and the files
                // go with the chips (nothing references them yet).
                ChatImageStore.remove(attachedImageIDs)
                attachedImageIDs = []
                // Tiles for a batch still in flight belong to the thread it
                // was picked in; the load's own thread check (see
                // `stagePickedPhotos`) already refuses to stage the result
                // here, so the placeholders must go with the chips.
                photosStaging = 0
                // Persist the OUTGOING thread's scroll position before loading
                // the new one -- `selectedBookID` has already changed by the
                // time this closure runs, so `persistScrollPosition` needs the
                // thread being LEFT passed explicitly rather than reading the
                // now-stale-for-this-purpose `selectedBookID` itself.
                persistScrollPosition(forThread: oldValue)
                // Record the INCOMING thread as the resume thread right away --
                // `persistScrollPosition` above just wrote the outgoing one, and
                // the next gated persist may be a while off (the new thread's
                // own restore has to land first), so without this a kill right
                // after switching reopened on the thread just left.
                UserDefaults.standard.set(newValue?.uuidString ?? "", forKey: Self.lastThreadKey)
                hasRestoredScroll = false
                visibleMessageTimestamps = []
                loadChatHistory()
            }
            .onChange(of: pendingDeepLinkBookID) { _, _ in
                // Covers the widget-tap-while-already-on-the-Chat-tab case --
                // `.onAppear` only fires when this view (re)mounts, not when a new
                // URL arrives while it's already on screen.
                applyPendingDeepLinkBookID()
                applyPendingDeepLinkPrefill()
            }
            .onChange(of: pendingDeepLinkHighlightID) { _, _ in
                applyPendingDeepLinkBookID()
                applyPendingDeepLinkPrefill()
            }
            .onChange(of: books.count) { _, _ in
                // The retry that closes the cold-launch race for the highlight
                // prefill: the deep link can land before the store has
                // populated, and this is the moment it has (see
                // `applyPendingDeepLinkHighlightID`). A no-op unless a pending
                // highlight ID is still waiting.
                applyPendingDeepLinkHighlightID()
                // Same cold-launch reasoning for the restored thread: the store
                // can be empty when `.onAppear`'s validation ran, and this is
                // the moment it has data to validate against.
                validateRestoredThread()
            }
            .alert("API Key Required", isPresented: $showNoAPIKeyAlert) {
                Button("Open Settings") {
                    if let url = URL(string: "cobux://settings") { openURL(url) }
                }
                Button("Not Now", role: .cancel) { }
            } message: {
                Text("Chat runs on Claude with your own Anthropic API key. Add it under More → Settings to start a conversation.")
            }
            // Guards `sendMessage`/the mic button below against the confirmed
            // Build-5 crash class: SwiftData asserts if a book's relationships
            // (highlights/chapters) are faulted while the background
            // seed/upgrade merge is still writing to them, and every retrieval
            // path here (`SearchService.buildContext`/`buildSplitContext`/
            // `buildSplitContextForBook`) does exactly that fault. This banner
            // is the same "still syncing" message `BookDetailView`/
            // `QuizHomeView` show for the same reason.
            .alert("Still Syncing", isPresented: $showLibrarySyncingAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Your library is still setting up. Try again in a moment.")
            }
            .alert("Clear Chat?", isPresented: $showClearChatAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) { clearChat() }
            } message: {
                Text("This will permanently delete your chat history. Your books and highlights are not affected.")
            }
            .alert("What is Symposium Mode?", isPresented: $showSymposiumExplanation) {
                Button("Cancel", role: .cancel) { }
                Button("Turn On") {
                    hasSeenSymposiumExplanation = true
                    symposiumModeEnabled = true
                }
            } message: {
                Text("Instead of one answer, Cobux replies as EACH relevant book's author separately, then highlights where they'd actually disagree with each other. Good for exploring different perspectives on the same question across your library.")
            }
            .sheet(isPresented: $showingDecisionConsultation) {
                DecisionConsultationView(claudeService: claudeService)
            }
            .sheet(isPresented: $showingSituations) {
            SituationsView(selectedBookID: $selectedBookID)
        }
        .sheet(isPresented: $showingBookThreadPicker) {
                BookThreadPickerView(books: books, selectedBookID: $selectedBookID)
            }
            .fullScreenCover(isPresented: $showingVoiceMode, onDismiss: loadChatHistory) {
                VoiceModeView(
                    claudeService: claudeService,
                    selectedBookID: selectedBookID,
                    symposiumModeEnabled: symposiumModeEnabled,
                    initialConversationHistory: conversationHistory,
                    // Fetched HERE, as the cover presents, and only for the
                    // thread that can use it. `VoiceSessionController` calls
                    // `ChatPromptBuilder.assemble` without
                    // `personalWritingContextEnabled`, so the only branch that
                    // ever reads these is the journal thread's -- on every
                    // other thread the old code handed over the entire journal
                    // for the assembler to ignore. Held on the main actor: the
                    // controller is main-actor and never crosses these rows.
                    personalWritingEntries: isJournalThread ? journalEntriesForPrompt() : []
                )
            }
        }
    }

    /// The actual conversation surface -- extracted from `body` so the
    /// journal thread can wrap exactly this (and not the toolbar/sheets) in
    /// `JournalLocked`.
    private var chatBody: some View {
        VStack(spacing: 0) {
            if symposiumModeEnabled {
                symposiumBadge
            }
            // 61: no spend line in the chat. His words: "the estimated spend
            // should not be shown in the chat, it kinda looks weird. It could
            // be shown in the settings." Settings and Diagnostics carry it.

            ScrollViewReader { proxy in
                ScrollView {
                    // One step tighter (was 8) as the inter-bubble half of the
                    // chat-density fix — see `MessageBubbleView` for the rest.
                    // Spacing 0: each row supplies its own, so the feed has
                    // rhythm. A uniform gap made a four-message burst from one
                    // speaker look identical to four turn changes, which is
                    // what a conversation is actually made of.
                    LazyVStack(spacing: 0) {
                        if !hasLoadedHistory {
                            historyLoadingView
                        } else if messages.isEmpty {
                            // One tip per visit, through the registry: photos
                            // first; Situations on a later empty chat, and only
                            // while none exist yet (the door in the top bar
                            // already shows a count once they do).
                            emptyStateView
                                .cobuxTip(firstOf: chatTips)
                        } else {
                            // Computed ONCE per body evaluation, not once per
                            // row: the old per-row `messages.last(where:)` was
                            // O(n) inside a ForEach over up to 400 rows -- O(n²)
                            // on every reveal tick. And it excludes error
                            // bubbles: a failed send is not a reply, so it must
                            // not steal the last real reply's refinement chips.
                            let newestReplyID = messages.last(where: { !$0.isUser && !$0.isError })?.id
                            // Resolved once for the whole transcript, for the
                            // same reason as the line above it.
                            // `currentThreadAccent` scans the ENTIRE `@Query`
                            // book library with `first(where:)` to find the
                            // thread's book, and it was being read from inside
                            // the row -- so every message bubble realised while
                            // scrolling a long thread re-scanned every book in
                            // the library. The answer cannot differ between two
                            // rows of the same thread.
                            let threadAccent = currentThreadAccent
                            ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                                // The time, once per real pause, instead of a
                                // caption under every message.
                                if let mark = timeMark(at: index) {
                                    Text(mark)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, CobuxSpacing.md)
                                }
                                MessageBubbleView(
                                    content: msg.content,
                                    isUser: msg.isUser,
                                    timestamp: msg.timestamp,
                                    referencedBooks: msg.referencedBooks,
                                    isError: msg.isError,
                                    isStreaming: msg.isStreaming,
                                    accentColor: threadAccent,
                                    referencedFigureID: msg.referencedFigureID,
                                    isNewestAssistantMessage: msg.id == newestReplyID,
                                    imageIDs: msg.imageIDs,
                                    onRefine: { refinement, quote in
                                        // A visible, ordinary user message --
                                        // the transcript stays an honest record
                                        // of what was asked. Sent DIRECTLY, not
                                        // by writing the composer: routing it
                                        // through `inputText` destroyed a
                                        // half-typed draft, and `sendMessage`
                                        // then captured every staged photo too
                                        // -- a vision request billed on a turn
                                        // that had nothing to do with them.
                                        send(text: ReplyRefinement.message(refinement, quoting: quote),
                                             imageIDs: [])
                                    },
                                    onRetry: retryAction(for: msg)
                                )
                                .padding(.top, index == 0 ? 0
                                         : (messages[index - 1].isUser == msg.isUser
                                            ? CobuxSpacing.xs : CobuxSpacing.lg))
                                .id(msg.id)
                                .onAppear { visibleMessageTimestamps.insert(msg.timestamp) }
                                .onDisappear { visibleMessageTimestamps.remove(msg.timestamp) }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                // Flow's own architecture -- content on a living gradient keyed
                // to the thread -- at reading strength. Flow uses 0.22/0.08,
                // which behind paragraphs would fight the text; 0.10/0.04 gives
                // the room a colour temperature owned by the book without
                // touching legibility. Switching from an orange book's thread to
                // a blue one now melts, exactly like Flow's card transitions.
                //
                // In dark the room leans toward crimson (P9): the thread's hue
                // is blended, not replaced -- a blue book still reads blue --
                // at `.room`, the strength measured for exactly this blend
                // (see `CobuxAtmosphere`). Light keeps `.reading` untouched.
                .background {
                    CobuxAtmosphere(accent: atmosphereAccent, strength: atmosphereStrength)
                }
                .onTapGesture {
                    isInputFocused = false
                }
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    // The initial restore's scroll has been issued -- from
                    // here on, what's visible reflects where the user
                    // actually is, so persisting becomes safe. Also runs
                    // for send-message nudges, where it's a no-op.
                    hasRestoredScroll = true
                }
            }

            inputBar
        }
    }

    private var symposiumBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.3.fill")
                .font(.caption2)
            Text("Symposium Mode")
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(Color.cobuxAccent)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.cobuxAccent.opacity(0.12))
        .clipShape(Capsule())
        .padding(.top, 8)
        .transition(.opacity.combined(with: .move(edge: .top)).animation(.easeOut(duration: 0.25)))
    }

    private var budgetWarningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
            Text("~$\(String(format: "%.2f", monthlyEstimate)) estimated spend this month — check Settings")
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(Color.cobuxWarning)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.cobuxWarning.opacity(0.12))
        .transition(.opacity.animation(.easeOut(duration: 0.25)))
    }

    /// The journal weave's switch, and its standing disclosure.
    ///
    /// This line used to describe the Face ID lock and offer an unlock. His
    /// ruling replaced both: *"I want the journal context to be unlocked by
    /// default at all times... most of the users are gonna keep their context
    /// on at all times, but if they actually want to turn it off... by default
    /// it should be on."* So the weave no longer waits on the lock (see
    /// `journalWeaveAvailable`) and this control offers the one thing left to
    /// decide -- whether his writing feeds the next reply at all.
    ///
    /// It stays on screen in BOTH states, which is the part that is not
    /// cosmetic. With the lock no longer sealing the weave, this line is the
    /// only place the app ever says that a chat reply can draw on his journal;
    /// and a control that shows up only in the state you are trying to leave is
    /// a control nobody finds. Quiet in both, never alarming -- his words on
    /// the alternative: *"it's not necessary because red's gonna pop out the
    /// whole time."* Same secondary caption grammar as every other ambient
    /// line above this composer.
    ///
    /// It writes the same key `SettingsView`'s "Use my personal writing in chat
    /// replies" toggle writes, deliberately: one preference with two doors, not
    /// a chat-local shadow of it that could disagree with Settings.
    ///
    /// The two directions are not symmetric, by his ruling (see the key's
    /// declaration): off is one tap, on is Face ID. Through
    /// `JournalUnlockCoordinator`, never `authenticate()` directly -- a chat
    /// unlock racing a journal gate's prompt is the exact bug that coordinator
    /// exists to close, and this notice was its named offender once already.
    @ViewBuilder
    private var journalWeaveNotice: some View {
        if !isJournalThread, hasPersonalWriting {
            Button {
                if personalWritingContextEnabled {
                    withAnimation(.easeOut(duration: 0.2)) {
                        personalWritingContextEnabled = false
                    }
                    personalWritingContextExplicitlyOff = true
                } else {
                    guard !isAuthenticatingJournalContext else { return }
                    isAuthenticatingJournalContext = true
                    Task {
                        let unlocked = await JournalUnlockCoordinator.authenticate(lockStatus)
                        if unlocked {
                            withAnimation(.easeOut(duration: 0.2)) {
                                personalWritingContextEnabled = true
                            }
                            personalWritingContextExplicitlyOff = false
                        }
                        isAuthenticatingJournalContext = false
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    // His own writing's glyph everywhere else in the app
                    // (`MoreView`'s journal card, the journal's own compose
                    // button). Not a lock: nothing here is sealed any more, and
                    // a padlock over a control that no longer locks anything is
                    // the invisible-honesty problem in reverse.
                    Image(systemName: "square.and.pencil")
                        .font(.caption2)
                    // State first, then the move it offers. The old line used
                    // the same two-part grammar for a reason worth keeping: it
                    // says both what the next Send will do and what the tap
                    // will change, so the control can never quietly mean
                    // something other than what it reads.
                    Text(personalWritingContextEnabled
                         ? "Journal context is on · Turn off"
                         : "Journal context is off · Turn on")
                        .font(.caption)
                        .contentTransition(.opacity)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isAuthenticatingJournalContext)
            .accessibilityHint(personalWritingContextEnabled
                               ? "Stops chat replies drawing on your journal"
                               : "Asks Face ID, then lets chat replies draw on your journal again")
            .transition(.opacity.animation(.easeOut(duration: 0.25)))
        }
    }

    /// Staged images above the composer -- the Claude/ChatGPT idiom: small
    /// rounded thumbnails, an x on each, gone on send.
    /// One tile per pick still in flight, at the strip's own size. The same
    /// shape as the journal's `loadingTile`, so a photo that is still coming
    /// down from iCloud reads as arriving rather than as nothing happening.
    private var stagingTile: some View {
        ProgressView()
            .frame(width: 56, height: 56)
            .background(Color.cobuxSurface2)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel("Loading photo")
    }

    @ViewBuilder
    private var attachmentStrip: some View {
        // `photosStaging` counts too: the strip must exist while the FIRST
        // photo of a message is still loading, which is exactly when there is
        // nothing in `attachedImageIDs` yet and exactly the moment he
        // screenshotted with nothing on screen.
        if !attachedImageIDs.isEmpty || photosStaging > 0 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachedImageIDs, id: \.self) { id in
                        ZStack(alignment: .topTrailing) {
                            if let image = ChatImageStore.image(for: id) {
                                Image(uiImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            Button {
                                ChatImageStore.remove(id)
                                attachedImageIDs.removeAll { $0 == id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.55))
                                    .padding(3)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove image")
                        }
                    }
                    ForEach(0..<photosStaging, id: \.self) { _ in
                        stagingTile
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            journalWeaveNotice
            attachmentStrip
        HStack {
            // Attach an image -- vision requests cost more, so the store
            // downscales at attach time (1024 long edge, jpeg 0.72) and the
            // cap is three per message.
            // A plain Button, not a `PhotosPicker` view: see
            // `showingPhotoPicker`. Nothing about this control presents
            // anything, so disabling it -- which the load itself causes --
            // can no longer reach a sheet the user is standing in.
            Button {
                // Frozen here, once, for the whole life of this presentation.
                photoPickerLimit = max(1, ChatImageStore.maxImagesPerMessage - attachedImageIDs.count)
                showingPhotoPicker = true
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(attachedImageIDs.count >= ChatImageStore.maxImagesPerMessage
                                     ? Color.secondary.opacity(0.4) : Color.secondary)
            }
            // Off while a batch is still arriving, exactly as the journal's
            // picker is: a second pick during a slow iCloud download used to
            // append BOTH batches.
            .disabled(attachedImageIDs.count >= ChatImageStore.maxImagesPerMessage || photosStaging > 0)
            .accessibilityLabel("Attach a photo")

            TextField(isJournalThread ? "Ask about your journal..." : "Ask Cobux anything...", text: $inputText, axis: .vertical)
                .focused($isInputFocused)
                .padding(12)
                // The field keeps its hairline -- it is an input control, and
                // the one place on this screen where an outline earns its keep.
                // The BAR around it loses its slab (below).
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.cobuxSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.cobuxLine, lineWidth: 1)
                )
                .lineLimit(1...5)
                // Identity, not styling: bumping this on each successful send
                // makes SwiftUI tear down and rebuild the underlying text view
                // rather than reconciling it, which is what guarantees the
                // field is visually empty afterwards. See `sendMessage`.
                .id(composerGeneration)

            if isStreaming {
                Button(action: stopStreaming) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(currentThreadAccent)
                }
            } else if inputText.isEmpty {
                // Right next to the text field, not the top-right toolbar --
                // reported live as effectively undiscovered up there despite
                // an earlier pass already making it a filled accent circle
                // (see that button's own doc comment below). This is the
                // Claude/ChatGPT convention Rajan pointed to directly: a mic
                // where the send arrow would go, swapping to the arrow the
                // instant there's text to send.
                Button {
                    if SeedingStatus.shared.isSeeding {
                        showLibrarySyncingAlert = true
                    } else {
                        showingVoiceMode = true
                    }
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.cobuxAccent))
                }
            } else {
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(inputText.isEmpty ? Color.secondary : currentThreadAccent)
                }
                .disabled(inputText.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // No `cobuxStructuralCell` -- that treatment is a square-cornered grey
        // slab meant for stat grids, per its own doc comment, and it sat a
        // utility panel under a conversation. The bar floats on the thread's
        // atmosphere instead.
        // The picker rides the composer ROW, and the failure alert rides the
        // bar around it -- two different view nodes, never one node owning two
        // presentations. That is the whole difference from the shape that
        // shipped in 52 (see `showingPhotoPicker`), and it matches the journal
        // composer, whose picker and alert have always lived apart.
        .photosPicker(isPresented: $showingPhotoPicker,
                      selection: $photoPickerItems,
                      maxSelectionCount: photoPickerLimit,
                      matching: .images)
        }
        .onChange(of: photoPickerItems) { _, items in
            guard !items.isEmpty else { return }
            stagePickedPhotos(items)
        }
        .alert("That photo couldn't be added", isPresented: $photoLoadFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Cobux couldn't read it from your library in time. If it's stored in iCloud, it may still be downloading — try again in a moment, or pick a different photo.")
        }
    }

    /// Turns a picker selection into staged chips.
    ///
    /// An UNSTRUCTURED `Task`, deliberately, and a plain function rather than
    /// a `.task` modifier: the sheet is already dismissing when this starts,
    /// and a load owned by the view's lifetime would be cancelled by the very
    /// dismissal that triggers it. Nothing here is tied to the picker
    /// surviving -- his report includes selecting and getting out immediately.
    ///
    /// The selection binding is cleared AFTER the load, never before -- the
    /// exact shape the journal composer had to fix
    /// (`R-2026-09-journal-photos-cannot-be-added`): a `PhotosPickerItem` is
    /// tied to the picker session it came from, so resetting the binding first
    /// can invalidate the items before `loadTransferable` runs, and every load
    /// quietly returns nil. The failure count is kept, not discarded, for the
    /// same reason: a timed-out iCloud original must produce an alert, never
    /// nothing.
    private func stagePickedPhotos(_ items: [PhotosPickerItem]) {
        let itemsToLoad = items
        let thread = selectedBookID
        // A tile per pick, from this instant -- set BEFORE the task, so the
        // strip is on screen in the same frame the selection lands rather than
        // a runloop later, and a slow photo reads as arriving.
        photosStaging = itemsToLoad.count
        Task {
            // Same loader rules as the journal: concurrent, per-item timeout,
            // never a silent hang on an iCloud original.
            let (loaded, failures) = await PhotoLoader.load(itemsToLoad)
            // Room under the cap, measured here on the main actor; the
            // transcode below runs detached because a SwiftUI `Task {}`
            // inherits @MainActor -- and decoding a 48MP original under
            // his thumb was the audit's finding.
            let room = max(0, ChatImageStore.maxImagesPerMessage - attachedImageIDs.count)
            let batch = Array(loaded.prefix(room))
            let saved = await Task.detached(priority: .userInitiated) {
                batch.compactMap { ChatImageStore.save($0) }
            }.value
            if thread == selectedBookID {
                // Cleared HERE, not unconditionally: the thread `.onChange`
                // already zeroed this for a batch he walked away from, and a
                // stale batch finishing afterwards must not clear the tiles of
                // a newer one picked in the thread he moved to.
                photosStaging = 0
                attachedImageIDs.append(contentsOf: saved)
                if !saved.isEmpty { CobuxTip.chatImages.markUsed() }
            } else {
                // He switched threads while these were still loading;
                // they must not land in a thread he never staged them
                // in (see the `selectedBookID` `.onChange`).
                ChatImageStore.remove(saved)
            }
            photoPickerItems = []
            let unreadable = failures + (batch.count - saved.count)
            if unreadable > 0 {
                DiagnosticLog.log("chat: \(unreadable) photo(s) failed or timed out loading")
                photoLoadFailed = true
            }
        }
    }

    /// This screen's walkthrough hints, in priority order -- one per visit.
    private var chatTips: [CobuxTip] {
        situations.isEmpty ? [.chatImages, .situations] : [.chatImages]
    }

    /// The one frame between the tab appearing and its history arriving.
    ///
    /// Deliberately quiet -- a small spinner and one line, on the thread's own
    /// atmosphere, with no card and no chrome. It is on screen for a single
    /// main-actor turn in the ordinary case, and anything more emphatic would
    /// read as a stall rather than as the app already being up.
    private var historyLoadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading your conversation…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .accessibilityElement(children: .combine)
    }

    private var emptyStateView: some View {
        CobuxEmptyStateView(
            icon: isJournalThread ? "text.book.closed" : "book.pages",
            title: "How can I help?",
            // Not "Ask about the wisdom in your library". His reading of that
            // framing: *"in chat it shoulndt say ask about books cause a user
            // is not neccarsliy use case is that they talking to cobux about
            // really else right"*. The books stay named first -- they are the
            // grounding, and the citations under a reply are real -- but the
            // sentence stops telling him books are the only thing he may
            // bring. Same door the Situations feature was built for.
            message: isJournalThread
                ? "Ask about what you've been writing"
                : "Ask about a book, or about whatever you're working through"
        ) {
            VStack(spacing: 10) {
                let chips = suggestedPrompts()
                ForEach(chips, id: \.self) { chip in
                    Button(action: {
                        // Direct, never via the composer -- see `onRefine`
                        // above for why writing `inputText` was the bug.
                        send(text: chip, imageIDs: [])
                    }) {
                        Text(chip)
                            .font(.subheadline)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cobuxCard()
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 20)
        }
    }

    /// A book chosen deterministically (not `.randomElement()`, which
    /// re-rolled on every re-render and could visibly flicker between
    /// re-renders while the empty state was showing) and rotated daily
    /// rather than fixed, so the general thread still surfaces different
    /// books over time without the instability.
    private var featuredBook: Book? {
        guard !books.isEmpty else { return nil }
        let sorted = books.sorted { $0.id.uuidString < $1.id.uuidString }
        let dayIndex = Calendar.current.ordinality(of: .day, in: .year, for: .now) ?? 0
        return sorted[dayIndex % sorted.count]
    }

    private func suggestedPrompts() -> [String] {
        if isJournalThread {
            return [
                "What was I writing about last month?",
                "What themes keep coming up in my journal?",
                "How have I been doing lately?"
            ]
        }
        if let selectedBookID, let book = books.first(where: { $0.id == selectedBookID }) {
            return bookScopedSuggestions(for: book)
        }
        // A chip is SENT verbatim (see `emptyStateView`), not prefilled, so
        // each one has to work as an opening line on its own. The first is
        // no longer book-framed: "Apply book wisdom to a situation I'm
        // facing..." made a real situation welcome only as a vehicle for a
        // book, which is the narrowing he objected to. The library question
        // stays -- books are still the grounding, just not the only door.
        var prompts = [
            "I want to talk through something I'm dealing with...",
            "What are the most common themes in my library?"
        ]
        if let book = featuredBook {
            prompts.insert(contentsOf: bookScopedSuggestions(for: book).prefix(2), at: 0)
        }
        return Array(prompts.prefix(4))
    }

    /// Templated per `BookContentProfile` rather than one generic shape --
    /// the fix for the old bug where a random book got paired with a
    /// hardcoded self-help-shaped prompt regardless of what kind of book it
    /// actually was (e.g. asking a pathology textbook's author "what did
    /// they say about responsibility").
    /// Top tag per book, computed once per thread visit rather than on every
    /// body evaluation -- the audit measured this scan re-walking the whole
    /// highlight/tag set of the scoped book PER COMPOSER KEYSTROKE, since the
    /// empty state re-renders with the field.
    @State private var cachedTopTag: [UUID: String?] = [:]

    private func bookScopedSuggestions(for book: Book) -> [String] {
        // This is called straight from `body` (via `emptyStateView`), so
        // unlike `sendMessage`'s alert-and-bail, it must degrade silently.
        // NEVER traverse `book.highlights` while the background seed/upgrade
        // merge is in flight -- the confirmed Build-5 crash class (see
        // `BookCard`'s doc comment). Skipping the tag scan during that window
        // just falls through to the topTag-less prompt variants below, which
        // every `contentProfile` case already handles.
        let topTag: String?
        if let cached = cachedTopTag[book.id] {
            topTag = cached
        } else if SeedingStatus.shared.isSeeding {
            // Not cached: a nil computed during the merge window is a
            // degraded answer, and caching it would freeze the degradation.
            topTag = nil
        } else {
            var tagCounts: [String: Int] = [:]
            for highlight in book.highlights {
                for tag in highlight.tags { tagCounts[tag, default: 0] += 1 }
            }
            let best = tagCounts.max { $0.value < $1.value }?.key
            // Written from a task, not during body evaluation -- mutating
            // @State mid-evaluation is the documented-UB pattern even when it
            // happens to work.
            let id = book.id
            Task { @MainActor in cachedTopTag[id] = best }
            topTag = best
        }

        switch book.contentProfile {
        case .academicReference:
            var prompts = ["Quiz me on the key facts from \(book.title)."]
            if let topTag { prompts.append("What's the highest-yield thing to know about \(topTag) in \(book.title)?") }
            return prompts
        case .narrative:
            var prompts = ["What's a moment from \(book.title) worth remembering?"]
            if !book.author.isEmpty { prompts.append("What did \(book.author) go through in \(book.title)?") }
            return prompts
        case .densePhilosophy, .doctrine:
            var prompts = ["What's the central argument of \(book.title)?"]
            if let topTag { prompts.append("How does \(book.title) think about \(topTag)?") }
            return prompts
        case .propositional:
            var prompts = ["What are the key takeaways from \(book.title)?"]
            if let topTag {
                prompts.append("What does \(book.title) say about \(topTag)?")
            } else if !book.author.isEmpty {
                prompts.append("What's \(book.author)'s core idea in \(book.title)?")
            }
            return prompts
        }
    }

    private var currentThreadLabel: String {
        if isJournalThread { return "My Journal" }
        if let situation = currentSituation { return situation.name }
        guard let selectedBookID, let book = books.first(where: { $0.id == selectedBookID }) else {
            return "General"
        }
        return book.title
    }

    /// The situation this thread is about, when it is one.
    private var currentSituation: SituationThread? {
        guard let selectedBookID else { return nil }
        return situations.first { $0.id == selectedBookID }
    }

    /// The book's own living color for a scoped thread, falling back to the app-wide
    /// accent for the general thread -- Phase 2 promised `coverColorHex` as "the dynamic
    /// accent for that book's detail, chat thread, quiz session, and mastery ring," but
    /// it only ever reached Library/BookDetail.
    private var currentThreadAccent: Color {
        guard let selectedBookID, let book = books.first(where: { $0.id == selectedBookID }) else {
            return .cobuxAccent
        }
        return Color(hex: book.coverColorHex)
    }

    /// The atmosphere's hue: the thread's own colour in light; in dark, that
    /// colour half-way to crimson, so every room in the app shares the
    /// red-black presence while the thread still owns its temperature.
    private var atmosphereAccent: Color {
        colorScheme == .dark ? currentThreadAccent.mix(with: .cobuxCrimson, by: 0.5) : currentThreadAccent
    }

    private var atmosphereStrength: CobuxAtmosphere.Strength {
        colorScheme == .dark ? .room : .reading
    }

    private var chatWordmarkFont: Font {
        CobuxTypography.display(colorScheme, size: 19, weight: .black)
    }

    private func checkAPIKey() {
        // Reflect the current keychain state, including key removal in Settings.
        claudeService.apiKey = KeychainManager.load(key: KeychainManager.anthropicAPIKey) ?? ""
    }

    private func applyPendingDeepLinkBookID() {
        if let target = pendingDeepLinkBookID {
            selectedBookID = target
            pendingDeepLinkBookID = nil
        }
        applyPendingDeepLinkHighlightID()
    }

    /// Pre-fills the composer with the quote the tapped widget was showing.
    ///
    /// This has to survive the same cold-launch race `pendingDeepLinkBookID`
    /// already had to solve: a widget tap launches the app, `onOpenURL` fires
    /// once with no retry, and the SwiftData store may not have anything in it
    /// yet at that instant. The book ID could simply be trusted without a
    /// lookup; a highlight's TEXT cannot, so this one genuinely has to read the
    /// store and therefore genuinely can arrive too early.
    ///
    /// The fix is to distinguish "not loaded yet" from "really gone" instead of
    /// treating an empty fetch as either. An empty result while the library
    /// itself is still empty means the store hasn't populated — the pending ID
    /// is KEPT and the `books` `.onChange` below retries once it does. An empty
    /// result once the library is loaded means the highlight was genuinely
    /// deleted since the widget last refreshed: clear the pending ID and
    /// degrade to a plain book-scoped thread with an empty composer, which is
    /// exactly the pre-existing behavior rather than an error.
    ///
    /// A non-empty composer is never overwritten — a half-typed message the
    /// user cared about outranks a prefill they can trigger again by tapping
    /// the widget a second time.
    /// Text prefill, for sources with no `Highlight` to look up. Same
    /// never-overwrite rule as the highlight path: a half-typed message the
    /// user cared about outranks a prefill they can trigger again.
    private func applyPendingDeepLinkPrefill() {
        guard let prefill = pendingDeepLinkPrefill else { return }
        if inputText.isEmpty {
            inputText = "\"\(prefill)\"\n\n"
        }
        pendingDeepLinkPrefill = nil
    }

    private func applyPendingDeepLinkHighlightID() {
        guard let highlightID = pendingDeepLinkHighlightID else { return }

        var descriptor = FetchDescriptor<Highlight>(
            predicate: #Predicate<Highlight> { $0.id == highlightID }
        )
        descriptor.fetchLimit = 1

        if let highlight = try? modelContext.fetch(descriptor).first {
            if inputText.isEmpty {
                inputText = "\"\(highlight.text)\"\n\n"
            }
            pendingDeepLinkHighlightID = nil
        } else if !books.isEmpty {
            pendingDeepLinkHighlightID = nil
        }
    }

    /// Loads the currently-selected thread's own history — a plain `bookID`
    /// filter, not a join or a separate table, since `ChatMessage.bookID` is
    /// the entire thread model (see its own doc comment). Switching threads
    /// just calls this again with a different id; existing messages from
    /// before threads existed all have `bookID == nil`, so they become the
    /// general thread's history automatically, no migration needed.
    private func loadChatHistory() {
        let targetID = selectedBookID
        // Taken BEFORE the rows are read, so a save that lands between the two
        // reads makes the next re-appear reload rather than skip.
        loadedHistoryFingerprint = historyFingerprint(for: targetID)
        // Newest 400, then reversed to chronological. The old ascending
        // unbounded fetch materialised a whole thread's history -- thousands
        // of rows after months of use -- to show a screen that renders the
        // tail. 400 is ~10x the deepest anyone scrolls back in practice and
        // 20x the model's own history window.
        var fetchDescriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate<ChatMessage> { $0.bookID == targetID },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        fetchDescriptor.fetchLimit = 400
        if let savedMessages = (try? modelContext.fetch(fetchDescriptor)).map({ Array($0.reversed()) }) {
            let loaded: [ChatRow] = savedMessages.map { (id: UUID(), content: $0.content, isUser: $0.isUser, timestamp: $0.timestamp, referencedBooks: $0.referencedBooks, isError: false, isStreaming: false, referencedFigureID: $0.referencedFigureID, imageIDs: $0.imageIDs ?? [], retry: nil) }
            messages = loaded
            conversationHistory = Self.alternatingHistory(from: savedMessages)
            restoreScrollPosition(in: loaded, forThread: targetID)
        } else {
            messages = []
            conversationHistory = []
            hasRestoredScroll = true
        }
    }

    /// The thread as the store holds it right now: how many rows, and the
    /// newest timestamp. Two bounded queries -- a COUNT and a one-row,
    /// one-column fetch -- against the same `bookID` predicate
    /// `loadChatHistory` uses, so it answers "would a reload change anything?"
    /// at roughly a thousandth of the reload's cost. Main actor, like every
    /// other read of `ChatMessage` in this file.
    private func historyFingerprint(for threadID: UUID?) -> ChatHistoryFingerprint {
        let inThread = #Predicate<ChatMessage> { $0.bookID == threadID }
        let count = (try? modelContext.fetchCount(FetchDescriptor<ChatMessage>(predicate: inThread))) ?? 0
        var newest = FetchDescriptor<ChatMessage>(
            predicate: inThread,
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        newest.fetchLimit = 1
        newest.propertiesToFetch = [\.timestamp]
        let newestTimestamp = (try? modelContext.fetch(newest))?.first?.timestamp
        return ChatHistoryFingerprint(count: count, newest: newestTimestamp)
    }

    /// The persisted thread id can point at a book that has since been
    /// deleted. Left alone, that half-worked in the worst way: the toolbar
    /// fell back to saying "General" while messages actually loaded (and new
    /// ones saved into) the dead book's thread. Falls back to the real
    /// General thread instead -- but only once the library has data, because
    /// on a cold launch an empty `books` means "not loaded yet," not "gone"
    /// (the same not-loaded-vs-really-gone distinction
    /// `applyPendingDeepLinkHighlightID` already draws); the `books.count`
    /// `.onChange` retries the validation once the store populates.
    private func validateRestoredThread() {
        guard let restoredID = selectedBookID,
              // The journal thread's sentinel id is never a real book -- it
              // is always valid to restore.
              restoredID != ChatPromptBuilder.journalThreadID,
              !books.isEmpty,
              !books.contains(where: { $0.id == restoredID }) else { return }
        selectedBookID = nil
    }

    /// Gathers his past messages for cross-conversation memory.
    ///
    /// Fetched and used entirely on the main actor: these are SwiftData models
    /// and reading them off it is the crash class this codebase has already
    /// paid for twice. Bounded by `fetchLimit` so a device with years of
    /// history costs the same as one with a month.
    ///
    /// The `recentWindowCutoff` is what stops this quoting the conversation
    /// back at itself: the last stretch of THIS thread is already in
    /// `conversationHistory` verbatim, so retrieving it again would spend
    /// budget repeating what the model can already see.
    /// Captures the cross-chat pool as value snapshots, on the main actor.
    ///
    /// The capture is a single cheap pass (bounded by `fetchLimit`); the
    /// expensive parts -- embedding the query and ranking two thousand
    /// vectors -- happen OFF main, on the snapshots, inside the stream task.
    /// Models never cross actors; values do.
    /// Whether journal excerpts may enter the prompt right now.
    ///
    /// The Face ID lock used to gate this, and no longer does: journal context
    /// is on by default and stays available whether or not the journal itself
    /// has been unlocked this session (see `journalWeaveNotice` for his ruling
    /// and for the disclosure that replaced the lock notice). What remains is
    /// the switch itself -- and the journal THREAD's exception to it, which is
    /// not an oversight: that thread is grounded in his entries by definition
    /// (`ChatPromptBuilder` reads them there regardless of this preference,
    /// since the toggle exists to keep journal asides out of BOOK answers), and
    /// it is the one surface still sealed behind `JournalLocked` as a whole.
    /// Letting the preference empty it would break the thread whose whole
    /// subject it is.
    private var journalWeaveAvailable: Bool {
        isJournalThread || personalWritingContextEnabled
    }

    private func crossChatSnapshots() -> (pool: [CrossChatMemory.Snapshot],
                                          currentThreadID: UUID?,
                                          recentWindowCutoff: Date?,
                                          threadLabels: [UUID: CrossChatMemory.ThreadLabel])? {
        guard crossChatMemoryEnabled else { return nil }
        var descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate<ChatMessage> { $0.isUser == true },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 2000
        // Explicit, because the cutoff below relies on it: the turn being sent
        // was inserted moments ago and not yet saved, and it must be the
        // newest row this fetch sees.
        descriptor.includePendingChanges = true
        let rows = (try? modelContext.fetch(descriptor)) ?? []

        // Derived from what ClaudeService actually SENDS, so "already visible
        // to the model" and "excluded from retrieval" are the same set. The
        // old constant here counted 20 USER rows while the service sends 20
        // ALTERNATING messages -- ten of his turns, not twenty -- so his turns
        // 11-20 back were in neither the history nor retrieval, and "what did
        // I say earlier about my brother?" failed on a message fourteen turns
        // back. `CrossChatMemory` owns the arithmetic; the harness proves it.
        let visibleTurns = CrossChatMemory.visibleUserTurns(
            historyRoles: conversationHistory.map(\.role),
            maxMessages: ClaudeService.maxHistoryMessages)
        let cutoff = CrossChatMemory.recentWindowCutoff(
            userTimestampsNewestFirst: rows.filter { $0.bookID == selectedBookID }.map(\.timestamp),
            visibleUserTurns: visibleTurns)

        let pool = rows.map {
            CrossChatMemory.Snapshot(content: $0.content, isUser: $0.isUser,
                                     bookID: $0.bookID, timestamp: $0.timestamp,
                                     embedding: $0.embedding)
        }
        // Structured labels, not strings: a situation's name is his label for
        // a real person, and whether the attribution line may say it is the
        // names-closed rule -- which lives in `CrossChatMemory.contextBlock`,
        // next to the sentence that states it, rather than here where a
        // finished string would already have decided.
        var labels: [UUID: CrossChatMemory.ThreadLabel] = [:]
        for book in books { labels[book.id] = .book(title: book.title) }
        for situation in situations { labels[situation.id] = .situation(name: situation.name) }
        return (pool, selectedBookID, cutoff, labels)
    }

    /// Persists the topmost currently-visible message's `timestamp` as this
    /// thread's resume point. Called on view disappear and on leaving a thread
    /// (see the `selectedBookID` `.onChange`) -- a no-op if nothing is tracked
    /// as visible yet (e.g. the view never actually rendered any rows).
    private func persistScrollPosition(forThread bookID: UUID?) {
        // Record WHICH thread too, not just where in it. Persisting the position of a
        // thread we won't reopen is what made the restore look broken.
        UserDefaults.standard.set(bookID?.uuidString ?? "", forKey: Self.lastThreadKey)
        // Inert until the initial restore lands -- see `hasRestoredScroll`.
        guard hasRestoredScroll, let earliestVisible = visibleMessageTimestamps.min() else { return }
        UserDefaults.standard.set(earliestVisible.timeIntervalSince1970, forKey: scrollPositionKey(for: bookID))
    }

    /// `id` can't be the persisted key (see `visibleMessageTimestamps`'s own
    /// comment — a fresh random one is assigned on every load), so this finds
    /// the loaded message whose `timestamp` is closest to what was persisted
    /// and scrolls to ITS freshly-generated `id` instead. No stored position
    /// (a new thread, or one that predates this fix) leaves `scrollTarget` untouched,
    /// which keeps today's default (natural top-of-content) behavior.
    /// Rebuilds the API conversation as strictly alternating turns.
    ///
    /// A user message is persisted the instant it is sent; its reply is
    /// persisted only when the stream finishes. So every stopped, failed,
    /// backgrounded or crashed reply leaves an ORPHANED user message in the
    /// store -- a question with no answer beside it. Mapping saved messages
    /// straight onto API turns then produced two consecutive `user` roles, and
    /// a model handed two user turns answers both of them.
    ///
    /// That is the defect Rajan reported: "when in chat a user puts two prompts
    /// it answers both which should not be the case that is weird." He never
    /// sent two prompts. One of his earlier questions had simply never been
    /// answered, and it came back to be answered alongside the next one,
    /// possibly days later.
    ///
    /// An orphan is dropped from the API history, NOT from the transcript --
    /// `messages` still shows every word he wrote, because that is his record
    /// and deleting from it would be a lie about what he said. It just stops
    /// being a question the model is still on the hook for.
    static func alternatingHistory(from saved: [ChatMessage]) -> [AIMessage] {
        var history: [AIMessage] = []
        var pendingUser: ChatMessage?
        for message in saved {
            if message.isUser {
                // A second user message in a row means the first never got an
                // answer. The newer one is the live question; the older one is
                // the orphan.
                pendingUser = message
            } else if let user = pendingUser {
                history.append(AIMessage(role: "user", content: user.content))
                history.append(AIMessage(role: "assistant", content: message.content))
                pendingUser = nil
            }
            // An assistant message with no user before it cannot open a
            // conversation, so it is skipped rather than sent as a lone
            // assistant turn.
        }
        return history
    }

    private func restoreScrollPosition(in loaded: [ChatRow], forThread bookID: UUID?) {
        let key = scrollPositionKey(for: bookID)
        guard UserDefaults.standard.object(forKey: key) != nil else {
            // Nothing saved -- the natural top IS the position; persisting is safe now.
            hasRestoredScroll = true
            return
        }
        let savedInterval = UserDefaults.standard.double(forKey: key)
        let savedDate = Date(timeIntervalSince1970: savedInterval)
        guard let closest = loaded.min(by: { abs($0.timestamp.timeIntervalSince(savedDate)) < abs($1.timestamp.timeIntervalSince(savedDate)) }) else {
            hasRestoredScroll = true
            return
        }
        // NOT setting `hasRestoredScroll` here -- the `.onChange(of: scrollTarget)`
        // handler flips it once this target's `scrollTo` is actually issued.
        scrollTarget = closest.id
    }

    private func scrollPositionKey(for bookID: UUID?) -> String {
        "chatLastReadTimestamp.\(bookID?.uuidString ?? "general")"
    }

    /// `isInputFocused = false` alone can be flaky about actually resigning
    /// the keyboard for a multi-line `TextField(axis: .vertical)`, so force it
    /// through UIKit as well.
    private func dismissKeyboard() {
        isInputFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// The time, shown only where a real pause happened.
    ///
    /// Replaces the caption that sat under every single message. Fifteen
    /// minutes is the threshold where "still talking" becomes "came back
    /// later", which is the only thing a timestamp in a chat actually tells
    /// you. Always shown for the first message so a thread is dated.
    private func timeMark(at index: Int) -> String? {
        guard messages.indices.contains(index) else { return nil }
        let stamp = messages[index].timestamp
        if index == 0 {
            return Self.timeMarkFormatter(for: stamp).string(from: stamp)
        }
        let previous = messages[index - 1].timestamp
        guard stamp.timeIntervalSince(previous) > 15 * 60 else { return nil }
        return Self.timeMarkFormatter(for: stamp).string(from: stamp)
    }

    /// Two formatters, built once, instead of one built per time mark.
    ///
    /// `DateFormatter`'s initialiser is genuinely expensive -- it resolves the
    /// locale's calendar and date symbols -- and this was allocating a fresh
    /// one inside `timeMark(at:)`, which `body` calls for every row in the
    /// `ForEach`, on every reveal tick of a streaming reply. The two only ever
    /// differed by `dateStyle`, so there was never anything per-call about
    /// them; `for date:` picks between them instead of configuring one.
    ///
    /// Safe to share: neither is mutated after construction (the documented
    /// condition for `DateFormatter` reuse), and every caller is on the main
    /// actor. Same shape as `JournalSessionStamp`'s pair.
    private static let todayTimeMarkFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let datedTimeMarkFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .medium
        return formatter
    }()

    private static func timeMarkFormatter(for date: Date) -> DateFormatter {
        Calendar.current.isDateInToday(date) ? todayTimeMarkFormatter : datedTimeMarkFormatter
    }

    /// The composer's send: hands the field and the staged photos to `send`,
    /// then clears both -- only if the send actually started, so a blocked
    /// send (no key, library syncing) never eats a draft. The keyboard is
    /// dismissed inside `send` BEFORE this clears: see the ordering note there.
    ///
    /// This used to open with a journal-lock trap -- a draft written for the
    /// journal held back until Face ID unlocked it, rather than spending one of
    /// his paid turns on a prompt with its whole subject silently stripped out
    /// (*"they would be pissed into trying to do it again also would use more
    /// usage if they copy and paste"*). The trap is gone because the thing it
    /// trapped is gone: the weave no longer waits on the lock at all, so a send
    /// can no longer quietly lose the journal it was written for. The one way
    /// to send without journal context now is to have switched it off
    /// deliberately, one tap above this button, on a line that says so.
    private func sendMessage() {
        let text = inputText
        guard !text.isEmpty else { return }
        let images = attachedImageIDs
        guard send(text: text, imageIDs: images) else { return }
        inputText = ""
        composerGeneration &+= 1
        // The chips clear on send; the files stay (the message owns them now).
        attachedImageIDs = []
    }

    /// "Try again" on a failed turn: resend his words and his photos, without
    /// re-inserting them -- the user row from the first attempt is already in
    /// the transcript and the store, exactly as Claude and ChatGPT regenerate
    /// in place rather than echoing the question twice. The error bubble goes
    /// once the new stream has started, so a blocked retry leaves it (and its
    /// button) in place.
    private func retryFailedTurn(errorID: UUID, text: String, imageIDs: [UUID]) {
        guard send(text: text, imageIDs: imageIDs, resending: true) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            messages.removeAll { $0.id == errorID }
        }
    }

    private func retryAction(for row: ChatRow) -> (() -> Void)? {
        guard let retry = row.retry else { return nil }
        return { retryFailedTurn(errorID: row.id, text: retry.text, imageIDs: retry.imageIDs) }
    }

    /// The one send path. Everything that sends a turn -- the composer, the
    /// suggested-prompt chips, the refinement chips, Try again -- comes
    /// through here with EXACTLY the text and photos that turn should carry.
    /// It never reads `inputText` or `attachedImageIDs` itself: the old shape
    /// (chips wrote the composer and called `sendMessage`) meant tapping
    /// "Warmer" destroyed a half-typed draft and shipped every staged photo
    /// with the refinement -- billed as a vision request on a turn that had
    /// nothing to do with them, and recorded on that message for good.
    ///
    /// Returns false when nothing was sent (no API key, library still
    /// syncing), so callers that own composer state can leave it intact.
    @discardableResult
    private func send(text userMessage: String, imageIDs sendingImageIDs: [UUID], resending: Bool = false) -> Bool {
        guard !userMessage.isEmpty else { return false }
        if claudeService.apiKey.isEmpty {
            showNoAPIKeyAlert = true
            return false
        }
        // NEVER traverse a Book's relationships (highlights, chapters) while
        // a background seed/upgrade merge is in flight -- the confirmed
        // Build-5 crash class (see `BookCard`'s doc comment). Every branch of
        // `ChatPromptBuilder.assemble` below routes into
        // `SearchService.buildContext`/`buildSplitContext`/
        // `buildSplitContextForBook`, all of which fault every relevant
        // book's `highlights`/`chapters` synchronously on this thread. A
        // returning user (whose `@Query`-backed `books` already has data from
        // last session) can reach the Chat tab and tap send within seconds of
        // a cold launch -- precisely the mutating-merge window a same-day
        // book seed or repair pass runs on every launch, same as `FlowView`.
        if SeedingStatus.shared.isSeeding {
            showLibrarySyncingAlert = true
            return false
        }

        // Rajan reported the composer intermittently keeping its text after a
        // send. Setting the bound `@State` to "" is logically correct and was
        // already happening, so the bug is not in the state — it is in the
        // UIKit text view behind `TextField(axis: .vertical)` not always
        // reflecting that write. Two known mechanisms, addressed in order:
        //
        // 1. Uncommitted input. While autocorrect/predictive text or dictation
        //    has marked (composing) text pending, the text view still owns
        //    edits that haven't reached the binding. If it commits them AFTER
        //    the clear, the committed string is written back into `inputText`
        //    and the field repopulates. Resigning first responder BEFORE
        //    clearing forces that commit to happen first, so the clear is last
        //    write rather than first. `userMessage` is captured beforehand, so
        //    a late commit can't change what actually gets sent.
        //
        // 2. Reconciliation not reaching the text view. Even with the binding
        //    correctly "", SwiftUI diffing an existing multi-line text view can
        //    leave the rendered text in place. Bumping `composerGeneration`
        //    changes the field's identity, so SwiftUI builds a NEW text view
        //    with no inherited editing state instead of updating the old one.
        //
        // Ordering matters: dismiss here, then `sendMessage` clears and
        // re-identifies the moment this returns -- the same dismiss → clear →
        // re-identify order as before, split across the two functions.
        dismissKeyboard()
        StreakTracker.recordActivityToday()

        // A retry re-sends a turn whose user row is already in the transcript
        // and the store (see `retryFailedTurn`), so it gets no second bubble
        // and no second row -- and no fresh model to write an embedding onto.
        let chatModel: ChatMessage?
        if resending {
            chatModel = nil
        } else {
            let newMessage: ChatRow = (id: UUID(), content: userMessage, isUser: true, timestamp: Date(), referencedBooks: [String](), isError: false, isStreaming: false, referencedFigureID: nil as UUID?, imageIDs: sendingImageIDs, retry: nil)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                messages.append(newMessage)
            }
            // Scroll just enough to bring the question on screen when it's sent —
            // a one-time nudge, not a continuous auto-follow. The reply then
            // streams in below and the user scrolls through it themselves.
            scrollTarget = newMessage.id

            let inserted = ChatMessage(content: userMessage, isUser: true, timestamp: newMessage.timestamp, referencedBooks: [], bookID: selectedBookID)
            // The message owns the files from here on (see `ChatImageStore`).
            inserted.imageIDs = sendingImageIDs.isEmpty ? nil : sendingImageIDs
            modelContext.insert(inserted)
            chatModel = inserted
        }
        // So the picker lists the situations he is actually in, most recent
        // first, rather than in creation order forever.
        currentSituation?.lastActivityDate = .now

        isStreaming = true
        let streamingID = UUID()
        activeStreamID = streamingID
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
            messages.append((id: streamingID, content: "", isUser: false, timestamp: Date(), referencedBooks: [], isError: false, isStreaming: true, referencedFigureID: nil, imageIDs: [], retry: nil))
        }
        if resending {
            // His message is already on screen; bring the new indicator in.
            scrollTarget = streamingID
        }

        streamBuffers[streamingID] = ""
        startRevealTicker(for: streamingID)

        // Everything below the bubble is DEFERRED off the send tap. The tap
        // handler now ends here: the user's bubble and the typing indicator
        // are on screen the same frame the button was pressed. Assembly --
        // which faults books, ranks vectors, and builds the prompt -- happens
        // inside the task, behind the indicator, before the first network
        // call. "Chat send runs the entire retrieval pipeline synchronously
        // on the main actor" was the audit's finding; this is the seam that
        // closes it.
        //
        // Captured as plain values so the detached closure touches nothing of
        // the view's -- property-wrapper reads belong on the main actor.
        let useRealNames = useRealNamesInLifeExamples
        streamTask = Task {
            // Let the tap's frame commit before any heavy work.
            await Task.yield()

            // The cross-chat capture -- a 2,000-row fetch whose every row
            // decodes a `[Float]` from its embedding blob -- was the one piece
            // of the pipeline still AHEAD of that yield, i.e. still under his
            // thumb, while the comment above claimed otherwise. It stays on
            // the main actor (SwiftData models), but behind the indicator now.
            let crossChatCapture = crossChatSnapshots()

            // The value-only work runs OFF the main actor: embedding the
            // message he just sent, and the cross-chat gate + ranking over
            // the snapshot pool. Models stay behind; values travel. The
            // direct-question asymmetry lives inside `contextBlock` itself,
            // where the harness proves it.
            let offMain = await Task.detached(priority: .userInitiated) {
                () -> (messageVector: [Float]?, memoryBlock: String, images: [Data]) in
                let images = sendingImageIDs.compactMap { ChatImageStore.imageData(for: $0) }
                let vector = EmbeddingService.embed(userMessage)
                guard let capture = crossChatCapture else { return (vector, "", images) }
                let block = CrossChatMemory.contextBlock(
                    query: userMessage,
                    userMessages: capture.pool,
                    currentThreadID: capture.currentThreadID,
                    recentWindowCutoff: capture.recentWindowCutoff,
                    journalThreadID: ChatPromptBuilder.journalThreadID,
                    threadLabel: { id in
                        guard let id else { return .general }
                        return capture.threadLabels[id] ?? .unknown
                    },
                    useRealNames: useRealNames)
                return (vector, block, images)
            }.value

            // Back on the main actor: write the vector onto the inserted row
            // (the message never changes, so a late set is safe), then
            // assemble. Assembly still faults models and so still belongs to
            // the main actor -- but it now runs behind the typing indicator
            // rather than under his thumb.
            chatModel?.embedding = offMain.messageVector

            let referencedTitles: [String]
            let stream: AsyncThrowingStream<String, Error>
            let assembled = ChatPromptBuilder.assemble(
                userMessage: userMessage,
                books: books,
                selectedBookID: selectedBookID,
                symposiumModeEnabled: symposiumModeEnabled,
                // Fetched only when the weave is actually switched on -- main
                // actor, behind the typing indicator, on the same turn that
                // faults `books` for retrieval anyway. With it off this is
                // literally zero work instead of a whole journal held resident
                // for the ternary to discard.
                //
                // The Face ID lock no longer stands between his journal and a
                // reply (see `journalWeaveAvailable`), so what reaches this line
                // is his stated preference and nothing else. Flow's echo still
                // applies the lock gate; that surface is not ours to change,
                // and the two now differ deliberately rather than by accident.
                personalWritingEntries: journalWeaveAvailable ? journalEntriesForPrompt() : [],
                personalWritingContextEnabled: personalWritingContextEnabled,
                useRealNamesInLifeExamples: useRealNamesInLifeExamples,
                situation: currentSituation,
                crossChat: .init(prebuiltBlock: offMain.memoryBlock,
                                 enabled: crossChatMemoryEnabled)
            )
            switch assembled {
            case .journal(let systemPrompt):
                // Uncached like symposium -- see `Assembled.journal`'s doc comment.
                referencedTitles = []
                stream = claudeService.streamMessage(userMessage: userMessage, conversationHistory: conversationHistory, systemPrompt: systemPrompt, options: .default, userImages: offMain.images)
            case .symposium(let systemPrompt, let titles):
                referencedTitles = titles
                stream = claudeService.streamMessage(userMessage: userMessage, conversationHistory: conversationHistory, systemPrompt: systemPrompt, options: .default, userImages: offMain.images)
            case .bookScoped(let stableSystemPrompt, let dynamicContext):
                referencedTitles = []
                stream = claudeService.streamMessageCached(userMessage: userMessage, conversationHistory: conversationHistory, stableSystemPrompt: stableSystemPrompt, dynamicContext: dynamicContext, userImages: offMain.images)
            case .general(let stableSystemPrompt, let dynamicContext, let titles):
                referencedTitles = titles
                stream = claudeService.streamMessageCached(userMessage: userMessage, conversationHistory: conversationHistory, stableSystemPrompt: stableSystemPrompt, dynamicContext: dynamicContext, userImages: offMain.images)
            }

            do {
                for try await chunk in stream {
                    await MainActor.run {
                        // Same liveness rule as `markNetworkDone`: a chunk
                        // that lands after `cleanupStream` must not recreate
                        // the buffer for a dead id.
                        if let buffered = streamBuffers[streamingID] {
                            streamBuffers[streamingID] = buffered + chunk
                        }
                    }
                }
                let cancelled = Task.isCancelled
                await MainActor.run {
                    markNetworkDone(id: streamingID, userMessage: userMessage, imageIDs: sendingImageIDs, referencedTitles: referencedTitles, notice: nil, wasCancelled: cancelled)
                }
            } catch is CancellationError {
                await MainActor.run {
                    markNetworkDone(id: streamingID, userMessage: userMessage, imageIDs: sendingImageIDs, referencedTitles: referencedTitles, notice: nil, wasCancelled: true)
                }
            } catch let urlError as URLError where urlError.code == .cancelled {
                await MainActor.run {
                    markNetworkDone(id: streamingID, userMessage: userMessage, imageIDs: sendingImageIDs, referencedTitles: referencedTitles, notice: nil, wasCancelled: true)
                }
            } catch {
                // The raw failure is kept, just not shown: it goes to the
                // diagnostic log a tester can export and send (Settings >
                // Diagnostics), which is the only place it was ever any use.
                // The bubble gets `userFacingMessage` instead -- this line used
                // to pass `error.localizedDescription` straight through, so
                // "API error (429): ..." and "Network error: The request timed
                // out." were rendered verbatim at `completeReveal`.
                //
                // Both statements deliberately sit OUTSIDE `MainActor.run`:
                // `DiagnosticLog.log` is a synchronous file write, and the main
                // actor's only job on this path is the one UI update below.
                DiagnosticLog.log("chat: stream failed -- \(error.localizedDescription)")
                let notice = (error as? ClaudeError)?.userFacingMessage
                    ?? "Something went wrong. Try again."
                await MainActor.run {
                    markNetworkDone(id: streamingID, userMessage: userMessage, imageIDs: sendingImageIDs, referencedTitles: referencedTitles, notice: notice, wasCancelled: false)
                }
            }
        }

        // Accepted: the row is persisted and the stream is running. The three
        // `return false` paths above all bail BEFORE anything is persisted,
        // which is what lets `sendMessage` clear the composer and the image
        // strip only on success -- a rejected send must leave his draft and
        // his attachments exactly where they were.
        return true
    }

    /// Paces the visible bubble text out of `streamBuffers[id]` instead of
    /// slamming whatever the network just delivered onto screen — chunks
    /// arrive in bursty batches, and revealing them instantly read as jumpy
    /// rather than the smooth, steady typing feel of ChatGPT/Claude's own UI.
    /// Reveals faster when a big backlog has piled up so long replies don't
    /// crawl, settling to a smooth few-characters-a-tick pace once caught up.
    private func startRevealTicker(for id: UUID) {
        revealTickers[id] = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 80_000_000) // 12.5 ticks/sec
                let done = await MainActor.run { revealTick(id: id) }
                if done { break }
            }
        }
    }

    @MainActor
    @discardableResult
    private func revealTick(id: UUID) -> Bool {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else {
            // The thread was switched away from mid-stream (see
            // `selectedBookID`'s `.onChange`) -- `loadChatHistory` replaced
            // `messages` wholesale, so this id's row is gone for good.
            // `completeReveal` is normally the only place that cleans up
            // `streamBuffers`/`streamNetworkDone`/`pendingFinalize`/this
            // ticker's own `Task`, but it's only ever reached by way of THIS
            // guard passing -- so without cleaning up here directly, all of
            // that state (and this ticker's `Task`) leaked forever every time
            // a user switched threads before a reply finished.
            cleanupStream(id: id)
            return true
        }
        let full = streamBuffers[id] ?? ""
        // Never type out the trailing `<sources>...</sources>` tag character by
        // character — it's citation metadata, not part of the visible reply.
        // `completeReveal` strips it for good once the stream finishes; capping
        // the typing animation here is what keeps it from ever flashing on
        // screen while the model is still streaming.
        let visibleFull: String
        if let tagStart = full.range(of: "<sources>") {
            visibleFull = String(full[..<tagStart.lowerBound])
        } else {
            visibleFull = full
        }

        let revealedCount = messages[idx].content.count
        let backlog = visibleFull.count - revealedCount
        if backlog > 0 {
            // ~12 chars/sec at steady state (1 char/tick) — slow, deliberate,
            // readable typing pace. Ramps up to at most 8 chars/tick when a
            // big backlog piles up so long replies don't crawl, then settles
            // back down as the backlog shrinks.
            let charsThisTick = max(1, min(8, backlog / 16))
            let nextCount = min(visibleFull.count, revealedCount + charsThisTick)
            messages[idx].content = String(visibleFull.prefix(nextCount))
        }

        let caughtUp = messages[idx].content.count >= visibleFull.count
        if caughtUp && streamNetworkDone.contains(id) {
            completeReveal(id: id)
            return true
        }
        return false
    }

    /// Marks a stream's network activity as finished. The reveal ticker keeps
    /// running independently until it's caught up to the full buffered text,
    /// then calls `completeReveal` itself — so a fast reply that arrived in
    /// one burst still gets its short typing animation instead of popping in.
    @MainActor
    private func markNetworkDone(id: UUID, userMessage: String, imageIDs: [UUID], referencedTitles: [String], notice: String?, wasCancelled: Bool) {
        // Only a stream whose per-stream state still exists may write it.
        // Switching threads mid-reply cancels the stream, `revealTick` finds
        // its row gone and runs `cleanupStream` -- and THEN this late arrival
        // used to insert fresh `pendingFinalize`/`streamNetworkDone` entries
        // for a dead id, which nothing would ever read or remove. The
        // `activeStreamID` bookkeeping below still runs regardless: the Stop
        // button must never stay lit for a stream that has ended.
        let live = streamBuffers[id] != nil
        if live {
            pendingFinalize[id] = (userMessage, referencedTitles, notice, wasCancelled, imageIDs)
            streamNetworkDone.insert(id)
        }
        // Only the stream `activeStreamID` currently names may flip
        // `isStreaming`/`streamTask` -- switching threads mid-reply cancels
        // the old stream via `stopStreaming()`, but that cancellation is
        // cooperative: this completion handler can still land AFTER a brand
        // new stream has already started (`sendMessage` in the newly-opened
        // thread). Without this guard, the old stream's late arrival here
        // would incorrectly declare the NEW stream finished -- the Stop
        // button would vanish mid-reply, and a later tap of it would be a
        // no-op because `streamTask` had already been nilled out from under
        // the stream actually still running.
        if id == activeStreamID {
            isStreaming = false
            streamTask = nil
            activeStreamID = nil
        }
        // `ClaudeService` already persisted this turn's usage before its
        // stream finished; just re-read the running total so the banner
        // above reflects it without needing its own separate plumbing.
        monthlyEstimate = UsageTracker.currentMonthEstimate()

        guard live, let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        let full = streamBuffers[id] ?? ""
        if messages[idx].content.count >= full.count {
            completeReveal(id: id)
        }
    }

    /// Wraps up a stream once its text is fully revealed: persists the
    /// assistant's reply, surfaces an error/notice bubble when needed, and
    /// cleans up per-stream state. The streaming bubble keeps its identity
    /// throughout (see `sendMessage`), so finishing a stream never swaps one
    /// bubble view for another.
    ///
    /// Citation chips come from parsing the model's own `<sources>` declaration
    /// out of the raw reply (`CitationResolver`) — ground truth about what it
    /// actually used — not from `pending.referencedTitles` (the old retrieval-
    /// derived guess, which could diverge from the answer once prompt caching
    /// made every book's chapter summaries always available; that was the
    /// wrong-citation-chip bug).
    ///
    /// Book-scoped threads now request that declaration too, because a
    /// book-scoped reply can genuinely draw on a second book (see
    /// `SearchService.buildSplitContextForBook`). The thread's OWN book is
    /// filtered out of the resulting chips: labelling every reply in the
    /// "12 Rules for Life" thread with a "12 Rules for Life" chip is noise —
    /// the user picked that thread. What's left is a chip only when the reply
    /// actually reached beyond this thread's book, which is exactly the case
    /// worth surfacing, so `Assembled.bookScoped`'s old "never needs citation
    /// chips" premise now holds for the ordinary turn and correctly stops
    /// holding for a cross-book one.
    @MainActor
    private func completeReveal(id: UUID) {
        defer { cleanupStream(id: id) }

        guard let idx = messages.firstIndex(where: { $0.id == id }),
              let pending = pendingFinalize[id] else { return }

        let rawText = streamBuffers[id] ?? messages[idx].content
        let parsed = CitationResolver.parse(rawReply: rawText)
        let finalText = parsed.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitles = ChatPromptBuilder.displayableCitations(
            resolvedTitles: CitationResolver.resolve(declaredTitles: parsed.declaredTitles, libraryTitles: books.map(\.title)),
            selectedBookID: selectedBookID,
            books: books
        )

        if !finalText.isEmpty {
            messages[idx].content = finalText
            messages[idx].referencedBooks = resolvedTitles
            messages[idx].isStreaming = false

            let aiChatModel = ChatMessage(content: finalText, isUser: false, timestamp: messages[idx].timestamp, referencedBooks: resolvedTitles, bookID: selectedBookID)
            modelContext.insert(aiChatModel)

            // Figure lookup is a completely separate, ADDITIVE step that only
            // runs now — after this reply has already streamed back and been
            // finalized — never as part of `ChatPromptBuilder`/`buildContext`/
            // `buildSplitContext`/`CitationResolver` above. See
            // `SearchService.relevantFigure`'s own doc comment.
            if !resolvedTitles.isEmpty {
                let citedBookObjects = books.filter { resolvedTitles.contains($0.title) }
                if let figure = SearchService.relevantFigure(query: pending.userMessage, citedBooks: citedBookObjects, modelContext: modelContext) {
                    aiChatModel.referencedFigureID = figure.id
                    messages[idx].referencedFigureID = figure.id
                }
            }

            conversationHistory.append(AIMessage(role: "user", content: pending.userMessage))
            conversationHistory.append(AIMessage(role: "assistant", content: finalText))

            // Re-nudge the scroll position now that the reply is actually
            // done — if the user switched tabs mid-stream and came back, the
            // one-time nudge from `sendMessage` is long past, so without
            // this the finished reply can sit below the visible area with
            // nothing indicating it arrived.
            scrollTarget = id
        } else {
            // Nothing came back (e.g. cancelled before any text arrived) — drop the empty placeholder bubble.
            withAnimation(.easeOut(duration: 0.2)) {
                messages.remove(at: idx)
            }
        }

        var noticeText = pending.notice
        if finalText.isEmpty && noticeText == nil && !pending.wasCancelled {
            noticeText = "No response received. Please try again."
        }
        if let noticeText {
            // Error/notice bubbles are transient — shown now, not persisted.
            // Each carries the failed turn's words and photos so "Try again"
            // can resend them: his message is already persisted and the
            // composer already cleared by the time this shows, so without it
            // the only way to try again was to retype. A Stop never reaches
            // here with a notice, so cancelling grows no button.
            let retry = (text: pending.userMessage, imageIDs: pending.imageIDs)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                messages.append((id: UUID(), content: noticeText, isUser: false, timestamp: Date(), referencedBooks: [], isError: true, isStreaming: false, referencedFigureID: nil, imageIDs: [], retry: retry))
            }
        }
    }

    @MainActor
    private func cleanupStream(id: UUID) {
        streamBuffers.removeValue(forKey: id)
        streamNetworkDone.remove(id)
        pendingFinalize.removeValue(forKey: id)
        revealTickers[id]?.cancel()
        revealTickers.removeValue(forKey: id)
    }

    private func stopStreaming() {
        streamTask?.cancel()
    }

    /// Clears only the CURRENTLY OPEN thread's history — a predicate delete
    /// scoped to `selectedBookID`, not the old unconditional wipe. Clearing
    /// the Microbiology thread must never be able to nuke the Robbins or
    /// general threads too.
    private func clearChat() {
        streamTask?.cancel()
        for (_, task) in revealTickers { task.cancel() }
        revealTickers.removeAll()
        streamBuffers.removeAll()
        streamNetworkDone.removeAll()
        pendingFinalize.removeAll()
        let targetID = selectedBookID
        // Files FIRST, while the rows still exist to say which files are this
        // thread's -- see `ChatImageStore`. The rows alone used to go, and
        // every photo attached in the thread stayed on disk forever.
        ChatImageStore.removeImages(inThread: targetID, context: modelContext)
        try? modelContext.delete(model: ChatMessage.self, where: #Predicate { $0.bookID == targetID })
        messages = []
        conversationHistory = []
    }

    /// Once per launch, a few seconds after chat first appears: sweep image
    /// files no message references -- the backstop behind the per-thread
    /// sweep every delete path runs first (see `ChatImageStore.pruneOrphans`).
    /// Deferred so it never competes with the first render; guarded inside
    /// the store so re-mounts of this view do not repeat it. Chat is where
    /// images enter and leave, so chat's first appearance is where the sweep
    /// is reachable without touching the launch path.
    private func schedulePhotoPrune() {
        Task {
            try? await Task.sleep(for: .seconds(4))
            ChatImageStore.pruneOrphans(context: modelContext, keeping: attachedImageIDs)
        }
    }
}

/// What `ChatView` compares on a re-appear to decide whether the transcript
/// in memory is already what the store holds -- see its `.task`. Row count
/// and newest timestamp of one thread: two values, both from bounded queries,
/// and together they move on every insert, delete, clear and restore that
/// could change what a reload would show.
struct ChatHistoryFingerprint: Equatable {
    var count: Int
    var newest: Date?
}
