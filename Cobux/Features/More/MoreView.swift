import SwiftUI

/// Landing point for the lower-priority tabs — Reminders and Settings
/// (which already has its own Appearance/theme picker) — kept
/// off the main tab bar so Library/Wisdom/Chat, the features actually used
/// day to day, stay front and center.
struct MoreView: View {
    let notificationManager: NotificationManager
    @Binding var path: NavigationPath
    @State private var streak = StreakTracker.currentStreak

    var body: some View {
        NavigationStack(path: $path) {
            List {
                // Second consumer of CobuxFormSection/CobuxSettingsRow (2.2.0),
                // proving the pattern established on SettingsView generalizes.
                // This screen was a flat, unsectioned List before -- grouping it
                // into "Progress"/"Library" is itself part of "looks modern," not
                // just a mechanical swap: a flat list of unrelated rows is exactly
                // the stock-Form look this redesign is fixing.
                if streak > 0 {
                    CobuxFormSection(title: "Progress") {
                        CobuxSettingsRow(
                            icon: "flame.fill",
                            iconTint: Color.cobuxWarning,
                            label: "Current streak",
                            value: "\(streak) day\(streak == 1 ? "" : "s")",
                            valueNumericTransition: true
                        )
                        .animation(.easeOut(duration: 0.3), value: streak)
                    }
                }

                // Its own section, not folded into "Library" below -- unlike
                // Reminders/Settings/What's New (each a one-time visit, or an
                // occasional check-in), this is meant to be a daily habit, and
                // burying it as the fourth row of a settings-shaped list would
                // undersell that. `path` binding matches the four other tabs'
                // convention (see `ContentView.tabSelection`'s doc comment) --
                // More is a menu, not content, so this is the one place that
                // convention doesn't apply, and this NavigationLink is fine
                // pushing onto More's own reset-on-leave path.
                CobuxFormSection(title: "Journal") {
                    NavigationLink(destination: JournalListView()) {
                        Label("Journal", systemImage: "book.closed.fill")
                    }
                }

                CobuxFormSection(title: "Library") {
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
            }
            .navigationTitle("More")
            .onAppear { streak = StreakTracker.currentStreak }
        }
    }
}
