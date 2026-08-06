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

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty {
                    row(title: "General", isSelected: selectedBookID == nil) {
                        selectedBookID = nil
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
