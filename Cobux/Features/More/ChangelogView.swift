import SwiftUI

/// "What's New" — a simple, hand-maintained release history so testers can
/// see what actually changed build to build instead of guessing. Data lives
/// in `BuildInfo.changelog`, updated alongside `uploadDate` as part of
/// shipping each new build.
struct ChangelogView: View {
    // Defaults to the full history for the existing More -> What's New push
    // destination; `WhatsNewSheet` passes a filtered slice instead.
    var entries: [ChangelogEntry] = BuildInfo.changelog

    var body: some View {
        List {
            ForEach(entries) { entry in
                Section {
                    ForEach(entry.changes, id: \.self) { change in
                        // A sparkle, not a tick. A checkmark beside every
                        // line read as a list of completed tasks -- the same
                        // to-do vocabulary retired from the widget and the
                        // app (`checklist:nothing-grades-the-user`) -- and
                        // this is the first thing a tester reads. Same glyph
                        // family as the What's New row that opens this.
                        Label(change, systemImage: "sparkle")
                            .font(.subheadline)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.primary)
                            .symbolRenderingMode(.hierarchical)
                    }
                } header: {
                    HStack {
                        Text("Version \(entry.version) (\(entry.build))")
                        Spacer()
                        Text(entry.date)
                    }
                }
            }
        }
        .navigationTitle("What's New")
    }
}
