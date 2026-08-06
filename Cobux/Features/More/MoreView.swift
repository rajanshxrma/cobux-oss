import SwiftUI

/// Landing point for the lower-priority tabs — Goodreads import, Reminders,
/// and Settings (which already has its own Appearance/theme picker) — kept
/// off the main tab bar so Library/Wisdom/Chat, the features actually used
/// day to day, stay front and center.
struct MoreView: View {
    let notificationManager: NotificationManager
    @Binding var path: NavigationPath
    @State private var streak = StreakTracker.currentStreak

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if streak > 0 {
                    HStack {
                        Image(systemName: "flame.fill")
                            .foregroundStyle(Color.cobuxWarning)
                        Text("\(streak) day\(streak == 1 ? "" : "s") streak")
                            .fontWeight(.semibold)
                            .contentTransition(.numericText())
                            .animation(.easeOut(duration: 0.3), value: streak)
                        Spacer()
                    }
                }

                NavigationLink(destination: GoodreadsShelfView()) {
                    Label("Goodreads", systemImage: "text.book.closed.fill")
                }
                NavigationLink(destination: RemindersView(notificationManager: notificationManager)) {
                    Label("Reminders", systemImage: "bell.fill")
                }
                NavigationLink(destination: SettingsView()) {
                    Label("Settings", systemImage: "gearshape")
                }
                NavigationLink(destination: ChangelogView()) {
                    Label("What's New", systemImage: "sparkles")
                }
                #if DEBUG
                NavigationLink(destination: DiagnosticsView()) {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
                #endif
            }
            .navigationTitle("More")
            .onAppear { streak = StreakTracker.currentStreak }
        }
    }
}
