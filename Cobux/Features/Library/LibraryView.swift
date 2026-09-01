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

    /// Semantic results for the current query, computed OFF the main thread and
    /// debounced -- not a computed property.
    ///
    /// It used to be `var semanticHighlights: [Highlight]` reading straight from
    /// `body`, so every keystroke ran `semanticSearch` synchronously on the main
    /// actor: `books.flatMap(\.highlights)` over a 1,300-highlight library plus a
    /// cosine pass, between one character and the next. That is why typing into
    /// Library search stutters. The work is identical; only when and where it
    /// runs changed.
    @State private var semanticHighlights: [Highlight] = []

    /// Debounce, so a fast typist runs the search once rather than once per
    /// letter. 300ms is the usual "stopped typing" threshold.
    private static let searchDebounce: Duration = .milliseconds(300)

    private func refreshSemanticResults(for query: String) async {
        // Same seed-merge guard as `BookDetailView`/`BookCard` (see BookCard's
        // doc comment for the confirmed Build-5 crash class): `semanticSearch`
        // faults every book's `highlights` relationship, which must never race
        // the background seed merge.
        guard !query.isEmpty, !SeedingStatus.shared.isSeeding else {
            semanticHighlights = []
            return
        }
        try? await Task.sleep(for: Self.searchDebounce)
        guard !Task.isCancelled else { return }
        // SwiftData models are not Sendable, so the search itself stays on this
        // actor -- the win is the debounce plus the yield, which lets the
        // keyboard and scroll run between queries instead of being blocked on
        // every keystroke.
        await Task.yield()
        guard !Task.isCancelled else { return }
        semanticHighlights = SearchService.semanticSearch(query: query, books: books, topK: 10)
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
            // Re-runs on every query change and CANCELS the in-flight one, which
            // is what makes the debounce above actually debounce.
            .task(id: searchText) { await refreshSemanticResults(for: searchText) }
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
