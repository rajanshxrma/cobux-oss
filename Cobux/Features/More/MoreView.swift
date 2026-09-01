import SwiftUI

/// Destinations under More that something OUTSIDE the view can push -- today
/// the Journal widget and the `cobux://journal` deep link.
///
/// The ordinary rows here use `NavigationLink(destination:)`, which is fine for
/// a tap but can't be triggered programmatically: there's no value to append to
/// the tab's `NavigationPath`. Rather than convert every row (churn with no
/// benefit -- the others have no external entry point), this adds one typed
/// route for the destinations that genuinely need to be reachable from a
/// widget, a deep link, or a future Shortcut.
enum MoreRoute: Hashable {
    /// Journal's list. `startingNewEntry` opens the compose sheet straight
    /// away, which is the whole point of the widget's "write" tap -- Rajan's
    /// reminder was "Cobux journal widget direct", i.e. land on the page you
    /// actually came to use, not two taps short of it.
    case journal(startingNewEntry: Bool)
}

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
                CobuxFormSection(title: "Saved") {
                    NavigationLink(destination: LikedHighlightsView()) {
                        Label("Liked", systemImage: "heart.fill")
                    }
                }

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
                    // Not #if DEBUG. DiagnosticLog writes in Release too, and its whole
                    // purpose is letting a tester share what happened after a crash -- but
                    // the only viewer was compiled out of exactly the builds testers run,
                    // so the log had no way out of the device. The launch-crash hunt this
                    // was built for had to fall back to pulling logs off the phone by hand.
                    NavigationLink(destination: DiagnosticsView()) {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                }
            }
            .navigationTitle("More")
            // Programmatic counterpart to the Journal row's own NavigationLink,
            // so a widget tap / deep link lands on the same screen the tap does
            // (including its Face ID gate, which lives inside JournalListView).
            .navigationDestination(for: MoreRoute.self) { route in
                switch route {
                case .journal(let startingNewEntry):
                    JournalListView(startingNewEntry: startingNewEntry)
                }
            }
            .onAppear { streak = StreakTracker.currentStreak }
        }
    }
}
