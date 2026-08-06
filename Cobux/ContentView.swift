import SwiftUI

struct ContentView: View {
    @State private var claudeService = ClaudeService()
    @State private var notificationManager = NotificationManager()
    @State private var selectedTab = 0
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
    }

    private var seedingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(seedingStatus.message)
                .font(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: CobuxRadius.card))
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }
}
