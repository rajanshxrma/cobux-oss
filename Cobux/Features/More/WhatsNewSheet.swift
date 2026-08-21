import SwiftUI

/// Presented automatically by `ContentView` the first time a tester opens the app on
/// a build newer than the one they last saw it on — closes the loop with the
/// bottom-of-screen "update available" banner (nudge to update, then show what they
/// actually got). `ChangelogView` itself is built for PUSH navigation (a plain `List`
/// with `.navigationTitle`, reached via `NavigationLink` from `MoreView`) — presented
/// bare in a `.sheet` it would render with no title and no way to dismiss, so this
/// wraps it in its own `NavigationStack` with a Done button, and filters to just the
/// entries newer than `sinceBuild` rather than the entire release history.
struct WhatsNewSheet: View {
    /// The build the tester last saw a changelog for, e.g. from before this update.
    /// Empty is treated the same as "show nothing" -- `ContentView.maybeShowWhatsNew`
    /// never presents this sheet with an empty `sinceBuild` in the first place.
    let sinceBuild: String
    @Environment(\.dismiss) private var dismiss

    private var newEntries: [ChangelogEntry] {
        BuildInfo.changelog.filter { BuildVersion.isNewer($0.build, than: sinceBuild) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if newEntries.isEmpty {
                    // Falls back to the full history rather than an empty screen --
                    // reachable if `sinceBuild` doesn't match any changelog entry's
                    // build string (e.g. a hotfix branch build number that was never
                    // added to `BuildInfo.changelog`).
                    ChangelogView()
                } else {
                    ChangelogView(entries: newEntries)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
