import SwiftUI
import SwiftData

struct LibraryView: View {
    @Binding var path: NavigationPath
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]
    @State private var searchText = ""
    @State private var showingAddBook = false
    @State private var unsortedCount = 0
    @Namespace private var bookHeroNamespace

    let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 16)
    ]

    var filteredBooks: [Book] {
        if searchText.isEmpty {
            return books
        } else {
            return books.filter { $0.title.localizedCaseInsensitiveContains(searchText) || $0.author.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var semanticHighlights: [Highlight] {
        // Same seed-merge guard as `BookDetailView`/`BookCard` (see BookCard's
        // doc comment for the confirmed Build-5 crash class): `semanticSearch`
        // does `books.flatMap(\.highlights)`, faulting every book's
        // `highlights` relationship synchronously. Unlike the grid (which
        // defers its own relationship read to `BookCard`'s `.task`), this
        // runs straight from `body` the moment `searchText` is non-empty --
        // and typing into Search is entirely possible while a first-run or
        // content-upgrade seed merge is still in flight in the background.
        // Reading `SeedingStatus.shared.isSeeding` here (an `@Observable`
        // property) makes this view re-render and retry the instant seeding
        // finishes, same as `BookDetailView.body` reading it directly.
        guard !searchText.isEmpty, !SeedingStatus.shared.isSeeding else { return [] }
        return SearchService.semanticSearch(query: searchText, books: books, topK: 10)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if unsortedCount > 0 {
                    unsortedRow
                }

                if books.isEmpty {
                    CobuxEmptyStateView(
                        icon: "books.vertical",
                        title: "Add your first book",
                        message: "Start storing wisdom from your reading."
                    ) {
                        CobuxEmptyStateButton("Add Book") { showingAddBook = true }
                    }
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filteredBooks) { book in
                            NavigationLink(destination: BookDetailView(book: book, heroTransitionNamespace: bookHeroNamespace)) {
                                BookCard(book: book)
                                    .cobuxZoomTransitionSource(id: book.id, in: bookHeroNamespace)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .scrollTransition { content, phase in
                                content
                                    .opacity(phase.isIdentity ? 1 : 0.4)
                                    .scaleEffect(phase.isIdentity ? 1 : 0.92)
                            }
                        }
                    }
                    .padding(16)
                }

                if !searchText.isEmpty && !semanticHighlights.isEmpty {
                    highlightsSection
                }
            }
            .background(Color.cobuxBackground)
            .navigationTitle("Library")
            .searchable(text: $searchText, prompt: "Search books or authors")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showingAddBook = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddBook) {
                AddBookView()
            }
            .onAppear(perform: refreshUnsortedCount)
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active, CrossProcessSync.consumeDirtyFlag() else { return }
                refreshUnsortedCount()
            }
        }
    }

    /// A quote captured via the Share Extension before it's filed to a book. Only shown when
    /// non-zero so the row never adds clutter for anyone who's never used Share.
    private var unsortedRow: some View {
        NavigationLink(destination: UnsortedHighlightsView()) {
            HStack {
                Image(systemName: "tray.fill")
                    .foregroundStyle(Color.cobuxAccent)
                Text("Unsorted (\(unsortedCount))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .cobuxCard()
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func refreshUnsortedCount() {
        let descriptor = FetchDescriptor<Highlight>(predicate: #Predicate<Highlight> { $0.book == nil })
        unsortedCount = (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    @ViewBuilder
    private var highlightsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Highlights")
                .font(.title3)
                .fontWeight(.bold)
                .padding(.horizontal)

            VStack(spacing: 12) {
                ForEach(semanticHighlights) { highlight in
                    if let book = highlight.book {
                        NavigationLink(destination: BookDetailView(book: book)) {
                            HighlightSearchCard(highlight: highlight, book: book)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.top, 8)
    }
}

private struct HighlightSearchCard: View {
    let highlight: Highlight
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\"\(highlight.text)\"")
                .font(.subheadline)
                .italic()
                .lineLimit(3)
                .foregroundStyle(.primary)

            HStack(spacing: 4) {
                BookTitleText(title: book.title, font: .caption, weight: .semibold, color: Color.cobuxAccent)
                if let chapter = highlight.chapter, !chapter.isEmpty {
                    Text("· \(chapter)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cobuxCard()
    }
}
