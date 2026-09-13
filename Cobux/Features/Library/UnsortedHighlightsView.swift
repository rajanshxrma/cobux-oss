import SwiftUI
import SwiftData

/// Highlights with `book == nil` — quotes captured via the Share Extension before they're
/// filed to a book. Deliberately not a new model: `Highlight.book` was already a settable
/// optional, so "unsorted" falls out of the existing schema at zero migration cost. This view
/// is what keeps an unsorted highlight from being a dead end — `SearchService.buildContext`/
/// quiz generation only ever iterate a book's own highlights, so a quote sitting here is
/// invisible to chat/search/quiz until the user files it to a real book from this screen.
struct UnsortedHighlightsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]

    @State private var unsortedHighlights: [Highlight] = []

    var body: some View {
        Group {
            if unsortedHighlights.isEmpty {
                CobuxEmptyStateView(
                    icon: "tray",
                    title: "Nothing unsorted",
                    message: "Quotes you capture via Share from Kindle, Books, or Safari land here until you file them to a book."
                )
            } else {
                List {
                    ForEach(unsortedHighlights) { highlight in
                        row(for: highlight)
                    }
                }
            }
        }
        .navigationTitle("Unsorted")
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { _, newPhase in
            // Deliberately unconditional, not gated on `CrossProcessSync.consumeDirtyFlag()`
            // -- that flag is single-shot process-wide, and `LibraryView` (the tab root,
            // always present underneath this pushed screen) already consumes it for its
            // own refresh. Two `.onChange` handlers racing to consume the same one-shot
            // flag meant whichever fired first silently starved the other of a refresh
            // it also needed. `reload()` is a bounded, cheap fetch (`fetchLimit = 500`),
            // same "safe to call every foreground" cost class as `WatchSyncService.sync`
            // elsewhere in this app -- no correctness reason to gate it at all.
            guard newPhase == .active else { return }
            reload()
        }
    }

    @ViewBuilder
    private func row(for highlight: Highlight) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\"\(highlight.text)\"")
                .font(.subheadline)
                .italic()

            if books.isEmpty {
                Text("Add a book first to file this quote.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    ForEach(books) { book in
                        Button(book.title) { file(highlight, to: book) }
                    }
                } label: {
                    Label("File to…", systemImage: "folder")
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { delete(highlight) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func reload() {
        var descriptor = FetchDescriptor<Highlight>(
            predicate: #Predicate<Highlight> { $0.book == nil },
            sortBy: [SortDescriptor(\.dateAdded, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        // The row shows `text`; filing writes `book`, deleting needs the row.
        // Neither reads `embeddingData`, so its 2 KB per row (up to ~1 MB for
        // a full page of captures) is left out of this main-actor fetch.
        // SwiftData faults the column in lazily if anything later asks -- the
        // backfill that embeds a capture runs its own fetch, not this one.
        descriptor.propertiesToFetch = [\.id, \.text, \.dateAdded]
        unsortedHighlights = (try? modelContext.fetch(descriptor)) ?? []
    }

    private func file(_ highlight: Highlight, to book: Book) {
        highlight.book = book
        try? modelContext.save()
        withAnimation {
            unsortedHighlights.removeAll { $0.id == highlight.id }
        }
    }

    private func delete(_ highlight: Highlight) {
        modelContext.delete(highlight)
        try? modelContext.save()
        withAnimation {
            unsortedHighlights.removeAll { $0.id == highlight.id }
        }
    }
}
