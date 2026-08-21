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
                    Button("Undo", action: onUndo)
                        .font(.caption.weight(.semibold))
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
