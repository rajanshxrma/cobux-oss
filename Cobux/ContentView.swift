import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var claudeService = ClaudeService()
    @State private var notificationManager = NotificationManager()
    @State private var selectedTab = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Query private var books: [Book]
    @Query private var chatMessages: [ChatMessage]
    @AppStorage("hasOfferedPostUpgradeExport") private var hasOfferedPostUpgradeExport = false
    @State private var showingPostUpgradeExportPrompt = false
    private let seedingStatus = SeedingStatus.shared

    /// One NavigationPath per tab that actually pushes content, hoisted here
    /// so it can be reset from outside that tab's own view. Fixes two real
    /// navigation bugs: (1) re-tapping the already-active tab did nothing —
    /// standard iOS behavior is to pop that tab to its root; (2) the More tab
    /// kept whatever screen you'd pushed (Settings, Reminders...) even after
    /// switching away and back, since TabView keeps every tab's view tree
    /// alive rather than tearing it down. More is a menu, not content, so it
    /// resets on leaving — the other tabs intentionally do NOT reset on leave
    /// (Library shouldn't lose your place in a book just because you glanced
    /// at Chat).
    @State private var libraryPath = NavigationPath()
    @State private var wisdomPath = NavigationPath()
    @State private var quizPath = NavigationPath()
    @State private var morePath = NavigationPath()

    private var tabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == selectedTab {
                    switch newValue {
                    case 0: libraryPath = NavigationPath()
                    case 1: wisdomPath = NavigationPath()
                    case 3: quizPath = NavigationPath()
                    case 4: morePath = NavigationPath()
                    default: break
                    }
                }
                if selectedTab == 4, newValue != 4 {
                    morePath = NavigationPath()
                }
                selectedTab = newValue
            }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            LibraryView(path: $libraryPath)
                .tabItem {
                    Label("Library", systemImage: "books.vertical.fill")
                }
                .tag(0)

            WisdomGraphView(claudeService: claudeService, path: $wisdomPath)
                .tabItem {
                    Label("Wisdom", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .tag(1)

            ChatView(claudeService: claudeService)
                .tabItem {
                    Label("Chat", systemImage: "message.fill")
                }
                .tag(2)

            QuizHomeView(claudeService: claudeService, path: $quizPath)
                .tabItem {
                    Label("Quiz", systemImage: "checkmark.circle.fill")
                }
                .tag(3)

            MoreView(notificationManager: notificationManager, path: $morePath)
                .tabItem {
                    Label("More", systemImage: "ellipsis.circle.fill")
                }
                .tag(4)
        }
        .tint(Color.cobuxAccent)
        .onOpenURL { url in
            if url.host == "chat" {
                selectedTab = 2
            }
        }
        .overlay(alignment: .bottom) {
            if seedingStatus.isSeeding {
                seedingBanner
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: seedingStatus.isSeeding)
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active || newPhase == .background else { return }
            WatchSyncService.sync(books: books)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            checkPendingBatchGeneration()
        }
        .onAppear(perform: maybeOfferPostUpgradeExport)
        .sheet(isPresented: $showingPostUpgradeExportPrompt, onDismiss: { hasOfferedPostUpgradeExport = true }) {
            PostUpgradeExportPromptView(books: books, chatMessages: chatMessages)
        }
    }

    /// Promotes background quiz generation from "the user has to remember to come back and
    /// tap Check Status" to actually automatic -- checked opportunistically on every
    /// foreground, same pattern as `WatchSyncService.sync` above. A no-op almost always
    /// (`applyResultsIfDone` returns nil immediately if nothing is pending or the batch
    /// isn't done yet), so this is cheap to call this often.
    private func checkPendingBatchGeneration() {
        guard BatchGenerationService.pendingBatch != nil else { return }
        Task {
            guard let result = try? await BatchGenerationService.applyResultsIfDone(claudeService: claudeService, modelContext: modelContext) else { return }
            notificationManager.notifyBatchGenerationComplete(bookTitle: result.bookTitle, questionsInserted: result.questionsInserted)
        }
    }

    /// Only offered once ever, and only when there's existing content worth protecting --
    /// a genuinely fresh install has nothing to back up yet. Checked on every appearance
    /// rather than a stronger "first launch" signal since first-launch seeding is still
    /// asynchronous at this point (`seedingStatus.isSeeding`) and books/chatMessages may
    /// not have finished loading on the very first call.
    private func maybeOfferPostUpgradeExport() {
        guard !hasOfferedPostUpgradeExport, !seedingStatus.isSeeding else { return }
        guard !books.isEmpty || !chatMessages.isEmpty else {
            hasOfferedPostUpgradeExport = true
            return
        }
        showingPostUpgradeExportPrompt = true
    }

    private var seedingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(seedingStatus.message)
                .font(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .cobuxCard()
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }
}
