import SwiftUI

/// Chapter Cram's actual gap wasn't pooling logic -- `QuizScopeBuilderView`'s existing
/// `.chapter(chapter)` scope already quizzes one chapter's full question bank unfiltered.
/// The gap was a global entry point: picking a chapter to cram meant first navigating into
/// its book. This is that picker, searchable across every book's chapters at once.
struct ChapterCramPickerView: View {
    let books: [Book]
    let onSelect: (Chapter) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    /// `searchText` after the debounce. The list filters on THIS, so a
    /// keystroke changes what he sees a beat later instead of re-running the
    /// filter under his thumb -- the same split `LibraryView` uses.
    @State private var settledSearchText = ""
    /// Built ONCE, in `.task`, instead of three times per body.
    ///
    /// `allRows` used to be a computed property that faulted every book's
    /// `chapters` relationship and then every chapter's `quizQuestions`
    /// relationship -- and `body` reached it three times (through
    /// `filteredRows` for the `List`, directly for the empty overlay, and
    /// through `filteredRows` again for the no-matches overlay). Driven by an
    /// undebounced `.searchable`, that was the whole faulting pass, three
    /// times, on every character typed.
    ///
    /// A row now carries everything the list draws, including the question
    /// count, so drawing a row touches no relationship at all.
    @State private var rows: [Row] = []
    @State private var hasBuiltRows = false

    private struct Row: Identifiable {
        let chapter: Chapter
        let bookTitle: String
        /// Snapshotted with the row. The label rendered this as
        /// `chapter.quizQuestions.count` TWICE per row (once for the number,
        /// once to decide the plural), which is two relationship faults per
        /// visible row per body.
        let questionCount: Int
        var id: UUID { chapter.id }
    }

    /// The one pass over the store. Main actor: these are `@Model` rows and
    /// they never leave it -- what changes is that this happens once when the
    /// sheet opens, not on every keystroke.
    private func buildRows() {
        var built: [Row] = []
        for book in books.sorted(by: { $0.title < $1.title }) {
            let readyChapters = book.chapters
                .filter { !$0.quizQuestions.isEmpty }
                .sorted { ($0.chapterNumber ?? 0) < ($1.chapterNumber ?? 0) }
            for chapter in readyChapters {
                built.append(Row(chapter: chapter,
                                 bookTitle: book.title,
                                 questionCount: chapter.quizQuestions.count))
            }
        }
        rows = built
        hasBuiltRows = true
    }

    private static let searchDebounce: Duration = .milliseconds(300)

    /// Cancelled and restarted by `.task(id:)` on every keystroke, which is
    /// what makes the sleep an actual debounce rather than a delay.
    private func settleSearch(_ query: String) async {
        // Clearing the field must be instant -- there is nothing to wait for,
        // and a 300ms lag before the full list returns reads as a stutter.
        if query.isEmpty {
            settledSearchText = ""
            return
        }
        try? await Task.sleep(for: Self.searchDebounce)
        guard !Task.isCancelled else { return }
        settledSearchText = query
    }

    private var filteredRows: [Row] {
        guard !settledSearchText.isEmpty else { return rows }
        return rows.filter {
            $0.chapter.title.localizedCaseInsensitiveContains(settledSearchText)
                || $0.bookTitle.localizedCaseInsensitiveContains(settledSearchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if SeedingStatus.shared.isSeeding {
                    // Same seed-merge guard as `BookCard`/`BookDetailView`/`QuizHomeView` --
                    // `allRows` faults every book's `chapters` and each chapter's
                    // `quizQuestions` relationship synchronously in `body`. Landing
                    // that fault mid seed/upgrade merge is the confirmed Build-5
                    // crash class. Reached only through `QuizHomeView`'s own gated
                    // list today, but that's a fragile guarantee to lean on from
                    // here -- a local guard costs nothing.
                    ProgressView("Syncing your library…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    pickerList
                }
            }
            .navigationTitle("Chapter Cram")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var pickerList: some View {
        List(filteredRows) { row in
            Button {
                onSelect(row.chapter)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.chapter.title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text("\(row.bookTitle) · \(row.questionCount) question\(row.questionCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // Behind the sheet's first frame. `pickerList` is only built once the
        // seed-merge guard above has cleared, so this inherits that guard --
        // the fault pass still never races the background merge.
        .task {
            await Task.yield()
            buildRows()
        }
        .task(id: searchText) { await settleSearch(searchText) }
        // Same correction as `QuizHomeView`: this was a grouped list rebuilt
        // by hand out of full-bleed `cobuxSurface2` bands on the near-black
        // ground. Settings sets none of these and reads better for it.
        .overlay {
            if !hasBuiltRows {
                // The one frame before the rows land. Without this the empty
                // state would claim "No chapters ready yet" to someone whose
                // library is full -- the deferral must not be allowed to lie,
                // and an empty `rows` means "not read yet" until it doesn't.
                ProgressView()
            } else if rows.isEmpty {
                CobuxEmptyStateView(
                    icon: "text.book.closed",
                    title: "No chapters ready yet",
                    message: "Quiz a chapter at least once from its book to make it available here."
                )
            } else if filteredRows.isEmpty {
                // The overlay used to test `allRows` only, so searching a
                // stocked picker down to zero matches left a blank list and no
                // words -- the same silent hole the Library search had.
                //
                // Quotes the SETTLED query, not the live field: naming a string
                // the list has not filtered on yet would put a "no chapter is
                // called X" beside rows that still match the previous X.
                CobuxEmptyStateView(
                    icon: "magnifyingglass",
                    title: "No matches",
                    message: "No chapter or book here is called \"\(settledSearchText)\"."
                )
            }
        }
        .searchable(text: $searchText, prompt: "Find a chapter")
    }
}
