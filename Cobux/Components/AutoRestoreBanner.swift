import SwiftUI

/// A dismissible, non-blocking notice that `AutoRestoreService` just silently
/// recovered data from an iCloud backup -- floating glass, not a sheet, per
/// `AutoRestoreService`'s own doc comment on why a sheet would re-enter a bug
/// already fixed twice in `ContentView`'s launch-sheet chain.
struct AutoRestoreBanner: View {
    let summary: String
    let canUndo: Bool
    let onUndo: () -> Void
    let onDismiss: () -> Void

    /// Undo removes restored rows, so it asks first. It is one tap away from a
    /// banner that sits there for the whole session, and the thing on the other
    /// side of it is his own archive.
    @State private var confirmingUndo = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "icloud.and.arrow.down.fill")
                .font(.title3)
                .foregroundStyle(Color.cobuxAccent)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(Color.cobuxInk)
                    .fixedSize(horizontal: false, vertical: true)

                if canUndo {
                    Button("Undo") { confirmingUndo = true }
                        .font(.caption.weight(.semibold))
                        .confirmationDialog("Undo this restore?",
                                            isPresented: $confirmingUndo,
                                            titleVisibility: .visible) {
                            Button("Undo Restore", role: .destructive, action: onUndo)
                            Button("Keep Everything", role: .cancel) {}
                        } message: {
                            Text("Entries you have written in since the restore are kept.")
                        }
                }
            }

            Spacer(minLength: 0)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .cobuxGlassCard()
        .padding(.horizontal, 16)
    }
}
