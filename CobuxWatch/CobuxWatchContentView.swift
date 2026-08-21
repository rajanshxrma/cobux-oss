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

    // Was `receiver.latestPayload?.dueCount ?? 0` -- a genuinely-zero due count and
    // "never synced yet" rendered identically, which is exactly what the "0 day
    // streak / 0 due" report turned out to be: a watch that had never once
    // received real data, indistinguishable on screen from having correctly
    // received zero. An em dash can't be confused with a real count.
    private var streakRow: some View {
        HStack {
            Image(systemName: "flame.fill")
                .foregroundStyle(Color.cobuxWarning)
            Text("\(receiver.latestPayload.map { "\($0.streakCount)" } ?? "—") day streak")
                .font(.headline)
            Spacer()
        }
    }

    private var dueRow: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.cobuxGood)
            Text("\(receiver.latestPayload.map { "\($0.dueCount)" } ?? "—") due")
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
