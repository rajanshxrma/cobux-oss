import SwiftUI
import SwiftData
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
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query private var books: [Book]
    @Query private var personalWritingEntries: [PersonalWritingEntry]

    /// Rajan explicitly asked for this feature (personal-writing context in
    /// chat), so this defaults to on — but the content itself (health,
    /// relationships, family, financial stress) is genuinely personal, so it
    /// stays an explicit, visible, always-reachable setting (see
    /// `SettingsView`'s matching toggle), not a buried flag with no UI. When
    /// off, `SearchService.buildSplitContext`/`buildSplitContextForBook` skip
    /// the retrieval step entirely — no query embedding, no ranking, nothing
    /// added to any prompt — not just a UI-level hide.
    @AppStorage("personalWritingContextEnabled") private var personalWritingContextEnabled: Bool = true
    /// Defaults ON as of 2.5.3. Rajan had reserved the decision on whether real
    /// names from journals may appear in replies; he has now made it. Must stay
    /// identical to `SettingsView`'s copy of this key, or the toggle and this
    /// retrieval gate would disagree. Existing installs are unaffected either
    /// way -- `@AppStorage` only applies a default when the key is absent, so
    /// anyone who already chose a value keeps it.
    @AppStorage("useRealNamesInLifeExamples") private var useRealNamesInLifeExamples: Bool = true

    @State private var messages: [(id: UUID, content: String, isUser: Bool, timestamp: Date, referencedBooks: [String], isError: Bool, isStreaming: Bool, referencedFigureID: UUID?)] = []
    @State private var inputText = ""
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
    @State private var pendingFinalize: [UUID: (userMessage: String, referencedTitles: [String], notice: String?, wasCancelled: Bool)] = [:]
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
                                .foregroundStyle(.primary)
                            HStack(spacing: 3) {
                                Text(currentThreadLabel)
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
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
            }
            .onAppear {
                validateRestoredThread()
                applyPendingDeepLinkBookID()
                checkAPIKey()
                loadChatHistory()
                monthlyEstimate = UsageTracker.currentMonthEstimate()
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
            }
            .onChange(of: pendingDeepLinkHighlightID) { _, _ in
                applyPendingDeepLinkBookID()
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
                Button("OK", role: .cancel) { }
            } message: {
                Text("Please configure your Anthropic API Key in Settings to use the chat.")
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
            .sheet(isPresented: $showingBookThreadPicker) {
                BookThreadPickerView(books: books, selectedBookID: $selectedBookID)
            }
            .fullScreenCover(isPresented: $showingVoiceMode, onDismiss: loadChatHistory) {
                VoiceModeView(
                    claudeService: claudeService,
                    selectedBookID: selectedBookID,
                    symposiumModeEnabled: symposiumModeEnabled,
                    initialConversationHistory: conversationHistory,
                    personalWritingEntries: personalWritingEntries
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
            if monthlyEstimate >= budgetWarningThreshold {
                budgetWarningBanner
            }

            ScrollViewReader { proxy in
                ScrollView {
                    // One step tighter (was 8) as the inter-bubble half of the
                    // chat-density fix — see `MessageBubbleView` for the rest.
                    LazyVStack(spacing: 6) {
                        if messages.isEmpty {
                            emptyStateView
                        } else {
                            ForEach(messages, id: \.id) { msg in
                                MessageBubbleView(
                                    content: msg.content,
                                    isUser: msg.isUser,
                                    timestamp: msg.timestamp,
                                    referencedBooks: msg.referencedBooks,
                                    isError: msg.isError,
                                    isStreaming: msg.isStreaming,
                                    accentColor: currentThreadAccent,
                                    referencedFigureID: msg.referencedFigureID
                                )
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

    private var inputBar: some View {
        HStack {
            TextField(isJournalThread ? "Ask about your journal..." : "Ask about your books...", text: $inputText, axis: .vertical)
                .focused($isInputFocused)
                .padding(12)
                .cobuxCard()
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
        .padding()
        .cobuxStructuralCell()
    }

    private var emptyStateView: some View {
        CobuxEmptyStateView(
            icon: isJournalThread ? "text.book.closed" : "book.pages",
            title: "How can I help?",
            message: isJournalThread ? "Ask about what you've been writing" : "Ask about the wisdom in your library"
        ) {
            VStack(spacing: 10) {
                let chips = suggestedPrompts()
                ForEach(chips, id: \.self) { chip in
                    Button(action: {
                        inputText = chip
                        sendMessage()
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
        var prompts = [
            "Apply book wisdom to a situation I'm facing...",
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
    private func bookScopedSuggestions(for book: Book) -> [String] {
        // This is called straight from `body` (via `emptyStateView`), so
        // unlike `sendMessage`'s alert-and-bail, it must degrade silently.
        // NEVER traverse `book.highlights` while the background seed/upgrade
        // merge is in flight -- the confirmed Build-5 crash class (see
        // `BookCard`'s doc comment). Skipping the tag scan during that window
        // just falls through to the topTag-less prompt variants below, which
        // every `contentProfile` case already handles.
        let topTag: String?
        if SeedingStatus.shared.isSeeding {
            topTag = nil
        } else {
            var tagCounts: [String: Int] = [:]
            for highlight in book.highlights {
                for tag in highlight.tags { tagCounts[tag, default: 0] += 1 }
            }
            topTag = tagCounts.max { $0.value < $1.value }?.key
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
        guard let selectedBookID, let book = books.first(where: { $0.id == selectedBookID }) else {
            return "General"
        }
        return book.title
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
        let fetchDescriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate<ChatMessage> { $0.bookID == targetID },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        if let savedMessages = try? modelContext.fetch(fetchDescriptor) {
            let loaded = savedMessages.map { (id: UUID(), content: $0.content, isUser: $0.isUser, timestamp: $0.timestamp, referencedBooks: $0.referencedBooks, isError: false, isStreaming: false, referencedFigureID: $0.referencedFigureID) }
            messages = loaded
            conversationHistory = savedMessages.map { AIMessage(role: $0.isUser ? "user" : "assistant", content: $0.content) }
            restoreScrollPosition(in: loaded, forThread: targetID)
        } else {
            messages = []
            conversationHistory = []
            hasRestoredScroll = true
        }
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
    private func restoreScrollPosition(in loaded: [(id: UUID, content: String, isUser: Bool, timestamp: Date, referencedBooks: [String], isError: Bool, isStreaming: Bool, referencedFigureID: UUID?)], forThread bookID: UUID?) {
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

    private func sendMessage() {
        guard !inputText.isEmpty else { return }
        if claudeService.apiKey.isEmpty {
            showNoAPIKeyAlert = true
            return
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
            return
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
        // Ordering matters: dismiss, then clear, then re-identify.
        let userMessage = inputText
        dismissKeyboard()
        inputText = ""
        composerGeneration &+= 1
        StreakTracker.recordActivityToday()

        let newMessage = (id: UUID(), content: userMessage, isUser: true, timestamp: Date(), referencedBooks: [String](), isError: false, isStreaming: false, referencedFigureID: nil as UUID?)
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
            messages.append(newMessage)
        }
        // Scroll just enough to bring the question on screen when it's sent —
        // a one-time nudge, not a continuous auto-follow. The reply then
        // streams in below and the user scrolls through it themselves.
        scrollTarget = newMessage.id

        let chatModel = ChatMessage(content: userMessage, isUser: true, timestamp: newMessage.timestamp, referencedBooks: [], bookID: selectedBookID)
        modelContext.insert(chatModel)

        isStreaming = true
        let streamingID = UUID()
        activeStreamID = streamingID
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
            messages.append((id: streamingID, content: "", isUser: false, timestamp: Date(), referencedBooks: [], isError: false, isStreaming: true, referencedFigureID: nil))
        }

        streamBuffers[streamingID] = ""
        startRevealTicker(for: streamingID)

        // The default chat path (`.general`) is the one that matters for
        // caching: it's where Utkarsh will actually rack up dozens of turns
        // per session.
        let referencedTitles: [String]
        let stream: AsyncThrowingStream<String, Error>
        let assembled = ChatPromptBuilder.assemble(
            userMessage: userMessage,
            books: books,
            selectedBookID: selectedBookID,
            symposiumModeEnabled: symposiumModeEnabled,
            personalWritingEntries: personalWritingEntries,
            personalWritingContextEnabled: personalWritingContextEnabled,
            useRealNamesInLifeExamples: useRealNamesInLifeExamples
        )
        switch assembled {
        case .journal(let systemPrompt):
            // Uncached like symposium -- see `Assembled.journal`'s doc comment.
            referencedTitles = []
            stream = claudeService.streamMessage(userMessage: userMessage, conversationHistory: conversationHistory, systemPrompt: systemPrompt)
        case .symposium(let systemPrompt, let titles):
            referencedTitles = titles
            stream = claudeService.streamMessage(userMessage: userMessage, conversationHistory: conversationHistory, systemPrompt: systemPrompt)
        case .bookScoped(let stableSystemPrompt, let dynamicContext):
            referencedTitles = []
            stream = claudeService.streamMessageCached(userMessage: userMessage, conversationHistory: conversationHistory, stableSystemPrompt: stableSystemPrompt, dynamicContext: dynamicContext)
        case .general(let stableSystemPrompt, let dynamicContext, let titles):
            referencedTitles = titles
            stream = claudeService.streamMessageCached(userMessage: userMessage, conversationHistory: conversationHistory, stableSystemPrompt: stableSystemPrompt, dynamicContext: dynamicContext)
        }

        streamTask = Task {
            do {
                for try await chunk in stream {
                    await MainActor.run {
                        streamBuffers[streamingID, default: ""] += chunk
                    }
                }
                let cancelled = Task.isCancelled
                await MainActor.run {
                    markNetworkDone(id: streamingID, userMessage: userMessage, referencedTitles: referencedTitles, notice: nil, wasCancelled: cancelled)
                }
            } catch is CancellationError {
                await MainActor.run {
                    markNetworkDone(id: streamingID, userMessage: userMessage, referencedTitles: referencedTitles, notice: nil, wasCancelled: true)
                }
            } catch let urlError as URLError where urlError.code == .cancelled {
                await MainActor.run {
                    markNetworkDone(id: streamingID, userMessage: userMessage, referencedTitles: referencedTitles, notice: nil, wasCancelled: true)
                }
            } catch {
                await MainActor.run {
                    markNetworkDone(id: streamingID, userMessage: userMessage, referencedTitles: referencedTitles, notice: error.localizedDescription, wasCancelled: false)
                }
            }
        }
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
    private func markNetworkDone(id: UUID, userMessage: String, referencedTitles: [String], notice: String?, wasCancelled: Bool) {
        pendingFinalize[id] = (userMessage, referencedTitles, notice, wasCancelled)
        streamNetworkDone.insert(id)
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

        if let idx = messages.firstIndex(where: { $0.id == id }) {
            let full = streamBuffers[id] ?? ""
            if messages[idx].content.count >= full.count {
                completeReveal(id: id)
            }
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
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                messages.append((id: UUID(), content: noticeText, isUser: false, timestamp: Date(), referencedBooks: [], isError: true, isStreaming: false, referencedFigureID: nil))
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
        try? modelContext.delete(model: ChatMessage.self, where: #Predicate { $0.bookID == targetID })
        messages = []
        conversationHistory = []
    }
}
