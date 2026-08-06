import SwiftUI

/// "What's New" — a simple, hand-maintained release history so testers can
/// see what actually changed build to build instead of guessing. Data lives
/// in `BuildInfo.changelog`, updated alongside `uploadDate` as part of
/// shipping each new build.
struct ChangelogView: View {
    var body: some View {
        List {
            ForEach(BuildInfo.changelog) { entry in
                Section {
                    ForEach(entry.changes, id: \.self) { change in
                        Label(change, systemImage: "checkmark.circle.fill")
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
