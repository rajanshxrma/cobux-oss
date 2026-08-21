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

    private struct Row: Identifiable {
        let chapter: Chapter
        let bookTitle: String
        var id: UUID { chapter.id }
    }

    private var allRows: [Row] {
        var rows: [Row] = []
        for book in books.sorted(by: { $0.title < $1.title }) {
            let readyChapters = book.chapters
                .filter { !$0.quizQuestions.isEmpty }
                .sorted { ($0.chapterNumber ?? 0) < ($1.chapterNumber ?? 0) }
            for chapter in readyChapters {
                rows.append(Row(chapter: chapter, bookTitle: book.title))
            }
        }
        return rows
    }

    private var filteredRows: [Row] {
        guard !searchText.isEmpty else { return allRows }
        return allRows.filter {
            $0.chapter.title.localizedCaseInsensitiveContains(searchText)
                || $0.bookTitle.localizedCaseInsensitiveContains(searchText)
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
                    Text("\(row.bookTitle) · \(row.chapter.quizQuestions.count) question\(row.chapter.quizQuestions.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.cobuxSurface2)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.cobuxBackground)
        .overlay {
            if allRows.isEmpty {
                CobuxEmptyStateView(
                    icon: "text.book.closed",
                    title: "No chapters ready yet",
                    message: "Quiz a chapter at least once from its book to make it available here."
                )
            }
        }
        .searchable(text: $searchText, prompt: "Find a chapter")
    }
}
