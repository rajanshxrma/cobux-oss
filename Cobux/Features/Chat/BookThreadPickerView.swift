import SwiftUI

/// The chat thread picker, presented as a sheet rather than a `Menu`.
///
/// The old toolbar `Menu` listed "General" + every book as inline `Button`s.
/// That works fine for a handful of items, but with the library at 15+ books
/// a flat `Menu`'s native dropdown scroll becomes unreliable on real
/// devices — confirmed live by Rajan ("the scroll of this dropdown is
/// cooked"). A `List` inside a sheet uses the same scrolling machinery as
/// every other list in the app (Library, Quiz Home) instead of `Menu`'s
/// separate, less-tested-at-scale scroll path, and gets a free search field
/// for finding one book in a long library.
struct BookThreadPickerView: View {
    let books: [Book]
    @Binding var selectedBookID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var sortedBooks: [Book] {
        books.sorted { $0.title < $1.title }
    }

    private var filteredBooks: [Book] {
        guard !searchText.isEmpty else { return sortedBooks }
        return sortedBooks.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    /// Books grouped by `category` for the browsing (non-search) layout —
    /// each section's books sorted by title, sections sorted alphabetically
    /// by category name, with any `category == nil` books collected into a
    /// trailing "Other" section rather than dropped. Only used when
    /// `searchText` is empty; search results stay a flat filtered list (see
    /// `filteredBooks`) since grouping only helps browsing, not searching.
    private var groupedBooks: [(category: String, books: [Book])] {
        let grouped = Dictionary(grouping: sortedBooks) { $0.category ?? "Other" }
        return grouped
            .sorted { lhs, rhs in
                if lhs.key == "Other" { return false }
                if rhs.key == "Other" { return true }
                return lhs.key < rhs.key
            }
            .map { (category: $0.key, books: $0.value.sorted { $0.title < $1.title }) }
    }

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty {
                    row(title: "General", isSelected: selectedBookID == nil) {
                        selectedBookID = nil
                        dismiss()
                    }
                    // Pinned above the book sections: the journal thread is a
                    // surface of its own, not a book in a category. Selecting
                    // it while the journal is Face-ID locked is fine -- the
                    // lock is enforced where the content shows (`ChatView`
                    // wraps this thread in `JournalLocked`, which auto-prompts
                    // on arrival), so this row stays a plain selection.
                    row(title: "My Journal", isSelected: selectedBookID == ChatPromptBuilder.journalThreadID) {
                        selectedBookID = ChatPromptBuilder.journalThreadID
                        dismiss()
                    }
                    ForEach(groupedBooks, id: \.category) { group in
                        Section {
                            ForEach(group.books) { book in
                                row(title: book.title, isSelected: selectedBookID == book.id) {
                                    selectedBookID = book.id
                                    dismiss()
                                }
                            }
                        } header: {
                            Text(group.category)
                                .font(CobuxTypography.cobuxSectionHeader)
                        }
                    }
                } else {
                    // The pinned journal row stays findable under search too --
                    // same substring rule the books get.
                    if "My Journal".localizedCaseInsensitiveContains(searchText) {
                        row(title: "My Journal", isSelected: selectedBookID == ChatPromptBuilder.journalThreadID) {
                            selectedBookID = ChatPromptBuilder.journalThreadID
                            dismiss()
                        }
                    }
                    ForEach(filteredBooks) { book in
                        row(title: book.title, isSelected: selectedBookID == book.id) {
                            selectedBookID = book.id
                            dismiss()
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.cobuxBackground)
            .searchable(text: $searchText, prompt: "Find a book")
            .navigationTitle("Chat Thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                BookTitleText(title: title, font: .body, weight: isSelected ? .semibold : .regular, color: .primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.cobuxAccent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.cobuxSurface)
    }
}
