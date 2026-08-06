import SwiftUI

struct GoodreadsShelfView: View {
    @State private var syncService = GoodreadsSyncService()
    @State private var selectedShelf: GoodreadsShelf = .read

    let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 16)
    ]

    private var filteredBooks: [GoodreadsBook] {
        syncService.books.filter { $0.shelf == selectedShelf }
    }

    var body: some View {
        // Pushed from MoreView's own NavigationStack -- no nested stack here,
        // which used to produce a doubled navigation bar.
        ScrollView {
                Picker("Shelf", selection: $selectedShelf) {
                    ForEach(GoodreadsShelf.allCases) { shelf in
                        Text(shelf.label).tag(shelf)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                if let syncError = syncService.syncError {
                    Text(syncError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                if filteredBooks.isEmpty && !syncService.isSyncing {
                    VStack(spacing: 16) {
                        Image(systemName: "books.vertical")
                            .font(.system(size: 50))
                            .foregroundStyle(.secondary)
                        Text("No books on this shelf yet")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filteredBooks) { book in
                            GoodreadsBookCard(book: book)
                        }
                    }
                    .padding()
                }

                if let lastSynced = syncService.lastSyncedDate {
                    Text("Synced \(lastSynced.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.bottom)
                }
            }
            .navigationTitle("Goodreads")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await syncService.sync() }
                    } label: {
                        if syncService.isSyncing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(syncService.isSyncing)
                }
            }
            .refreshable {
                await syncService.sync()
            }
            .onAppear {
                syncService.loadCacheIfNeeded()
                Task { await syncService.syncIfStale() }
            }
    }
}

private struct GoodreadsBookCard: View {
    let book: GoodreadsBook

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let urlString = book.coverImageURL, let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        default:
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .aspectRatio(3/4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)

            BookTitleText(title: book.title, font: .subheadline, weight: .semibold, lineLimit: 2)

            Text(book.author)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if book.averageRating > 0 {
                Label(String(format: "%.2f", book.averageRating), systemImage: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var placeholder: some View {
        LinearGradient(colors: [Color.cobuxAccent, Color.cobuxAccent.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
