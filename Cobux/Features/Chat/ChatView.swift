import SwiftUI
import SwiftData
import UIKit
import CobuxCore

struct ChatView: View {
    @Bindable var claudeService: ClaudeService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query private var books: [Book]

    @State private var messages: [(id: UUID, content: String, isUser: Bool, timestamp: Date, referencedBooks: [String], isError: Bool, isStreaming: Bool)] = []
    @State private var inputText = ""
    @State private var isStreaming = false
    @State private var conversationHistory: [AIMessage] = []
    @State private var streamTask: Task<Void, Never>?

    /// Raw text received so far per active stream — the network can deliver
    /// chunks in bursty batches, so what's actually *displayed* is paced out
    /// from this buffer by `revealTickers` instead of being dumped instantly.
    @State private var streamBuffers: [UUID: String] = [:]
    @State private var streamNetworkDone: Set<UUID> = []
    @State private var pendingFinalize: [UUID: (userMessage: String, referencedTitles: [String], notice: String?, wasCancelled: Bool)] = [:]
    @State private var revealTickers: [UUID: Task<Void, Never>] = [:]
    @State private var showNoAPIKeyAlert = false
    @State private var showClearChatAlert = false
    @State private var symposiumModeEnabled = false
    @State private var showingDecisionConsultation = false
    @State private var showingVoiceMode = false
    @State private var scrollTarget: UUID?
    @FocusState private var isInputFocused: Bool
    @State private var monthlyEstimate: Double = 0
    /// nil = the general "Cobux" thread; a Book's id = that book's own
    /// persistent, scoped thread (see `ChatMessage.bookID`).
    @State private var selectedBookID: UUID?
    @State private var showSymposiumExplanation = false
    @State private var showingBookThreadPicker = false
    @AppStorage("hasSeenSymposiumExplanation") private var hasSeenSymposiumExplanation = false

    /// Soft warning threshold — Rajan's brother's key is capped around $5/mo;
    /// this isn't fetched from anywhere (Anthropic doesn't expose the cap
    /// itself to the app), it's just a reasonable default matching that
    /// convention so a warning shows before a confusing hard stop rather than
    /// never at all. See `UsageTracker` for how the estimate itself is built.
    private let budgetWarningThreshold: Double = 4.0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if symposiumModeEnabled {
                    symposiumBadge
                }
                if monthlyEstimate >= budgetWarningThreshold {
                    budgetWarningBanner
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
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
                                        accentColor: currentThreadAccent
                                    )
                                    .id(msg.id)
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
                    }
                }

                inputBar
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
                    Button {
                        showingVoiceMode = true
                    } label: {
                        Image(systemName: "mic.fill")
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
                checkAPIKey()
                loadChatHistory()
                monthlyEstimate = UsageTracker.currentMonthEstimate()
            }
            .onChange(of: selectedBookID) { _, _ in
                // Switching threads mid-stream: cancel rather than let a
                // response keep streaming into a thread the user has left.
                // v1 deliberately keeps this simple — one active stream at a
                // time, tied to whichever thread is open (see design notes).
                stopStreaming()
                loadChatHistory()
            }
            .alert("API Key Required", isPresented: $showNoAPIKeyAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Please configure your Anthropic API Key in Settings to use the chat.")
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
                    initialConversationHistory: conversationHistory
                )
            }
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
            TextField("Ask about your books...", text: $inputText, axis: .vertical)
                .focused($isInputFocused)
                .padding(12)
                .cobuxCard()
                .lineLimit(1...5)

            if isStreaming {
                Button(action: stopStreaming) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(currentThreadAccent)
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
            icon: "book.pages",
            title: "How can I help?",
            message: "Ask about the wisdom in your library"
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
        var tagCounts: [String: Int] = [:]
        for highlight in book.highlights {
            for tag in highlight.tags { tagCounts[tag, default: 0] += 1 }
        }
        let topTag = tagCounts.max { $0.value < $1.value }?.key

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
            messages = savedMessages.map { (id: UUID(), content: $0.content, isUser: $0.isUser, timestamp: $0.timestamp, referencedBooks: $0.referencedBooks, isError: false, isStreaming: false) }
            conversationHistory = savedMessages.map { AIMessage(role: $0.isUser ? "user" : "assistant", content: $0.content) }
        } else {
            messages = []
            conversationHistory = []
        }
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

        let userMessage = inputText
        inputText = ""
        dismissKeyboard()

        let newMessage = (id: UUID(), content: userMessage, isUser: true, timestamp: Date(), referencedBooks: [String](), isError: false, isStreaming: false)
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
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
            messages.append((id: streamingID, content: "", isUser: false, timestamp: Date(), referencedBooks: [], isError: false, isStreaming: true))
        }

        streamBuffers[streamingID] = ""
        startRevealTicker(for: streamingID)

        // The default chat path (`.general`) is the one that matters for
        // caching: it's where Utkarsh will actually rack up dozens of turns
        // per session.
        let referencedTitles: [String]
        let stream: AsyncThrowingStream<String, Error>
        let assembled = ChatPromptBuilder.assemble(userMessage: userMessage, books: books, selectedBookID: selectedBookID, symposiumModeEnabled: symposiumModeEnabled)
        switch assembled {
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
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return true }
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
        isStreaming = false
        streamTask = nil
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
    /// wrong-citation-chip bug). Book-scoped threads never had the sources
    /// instruction added to their prompt, so parsing one just yields no
    /// declared titles — the existing "no chip in a book thread" behavior
    /// falls out naturally rather than needing a special case here.
    @MainActor
    private func completeReveal(id: UUID) {
        defer { cleanupStream(id: id) }

        guard let idx = messages.firstIndex(where: { $0.id == id }),
              let pending = pendingFinalize[id] else { return }

        let rawText = streamBuffers[id] ?? messages[idx].content
        let parsed = CitationResolver.parse(rawReply: rawText)
        let finalText = parsed.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitles = CitationResolver.resolve(declaredTitles: parsed.declaredTitles, libraryTitles: books.map(\.title))

        if !finalText.isEmpty {
            messages[idx].content = finalText
            messages[idx].referencedBooks = resolvedTitles
            messages[idx].isStreaming = false

            let aiChatModel = ChatMessage(content: finalText, isUser: false, timestamp: messages[idx].timestamp, referencedBooks: resolvedTitles, bookID: selectedBookID)
            modelContext.insert(aiChatModel)

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
                messages.append((id: UUID(), content: noticeText, isUser: false, timestamp: Date(), referencedBooks: [], isError: true, isStreaming: false))
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
