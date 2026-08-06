import SwiftUI

/// The app's ONE screen, deliberately — per Fable's ruling, the watch is read-only glanceables
/// only (streak, due count, a featured quote), never a second place to browse/review/chat.
/// The complications (`CobuxWatchWidgets`) are the actual product; this app exists because
/// watchOS requires a host for them, not because it needs its own UI depth.
struct CobuxWatchContentView: View {
    @State private var receiver = WatchConnectivityReceiver()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                streakRow
                dueRow
                if let quote = receiver.latestPayload?.quoteText, !quote.isEmpty {
                    quoteCard(text: quote, book: receiver.latestPayload?.quoteBook)
                }
                if receiver.latestPayload == nil {
                    Text("Open Cobux on your iPhone to sync.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
        }
        .onAppear { receiver.activateIfNeeded() }
    }

    private var streakRow: some View {
        HStack {
            Image(systemName: "flame.fill")
                .foregroundStyle(Color.cobuxWarning)
            Text("\(receiver.latestPayload?.streakCount ?? StreakTracker.currentStreak) day streak")
                .font(.headline)
            Spacer()
        }
    }

    private var dueRow: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.cobuxGood)
            Text("\(receiver.latestPayload?.dueCount ?? 0) due")
                .font(.headline)
            Spacer()
        }
    }

    private func quoteCard(text: String, book: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\"\(text)\"")
                .font(.footnote)
                .italic()
            if let book {
                Text("— \(book)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
