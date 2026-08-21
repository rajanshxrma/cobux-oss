import SwiftUI
import SwiftData

/// The Share Extension's own SwiftUI content, hosted by `ShareViewController`. Captures a
/// quote selected in Kindle/Books/Safari (or anywhere else that shares plain text) straight
/// into Cobux — filed to a book if one's picked, or left `Highlight.book == nil` ("unsorted",
/// see `UnsortedHighlightsView`) if not, so filing never blocks the save itself.
struct ShareQuoteView: View {
    let initialText: String
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var quoteText: String
    @State private var books: [Book] = []
    @State private var selectedBookID: UUID?
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(initialText: String, onComplete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.initialText = initialText
        self.onComplete = onComplete
        self.onCancel = onCancel
        _quoteText = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Quote") {
                    TextEditor(text: $quoteText)
                        .frame(minHeight: 100)
                }

                Section("Book") {
                    Picker("Book", selection: $selectedBookID) {
                        Text("Unsorted").tag(UUID?.none)
                        ForEach(books) { book in
                            Text(book.title).tag(Optional(book.id))
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(Color.cobuxDanger)
                    }
                }
            }
            .navigationTitle("Save to Cobux")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(quoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .onAppear(perform: loadBooks)
        }
    }

    private func loadBooks() {
        guard let container = ShareExtensionStore.makeContainer() else {
            errorMessage = "Couldn't open your Cobux library."
            return
        }
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Book>(sortBy: [SortDescriptor(\.title)])
        // A defensive bound, not a real-world limit -- an extension runs under a tight
        // memory ceiling and an unbounded fetch shouldn't be the thing that finds that out.
        descriptor.fetchLimit = 200
        books = (try? context.fetch(descriptor)) ?? []
    }

    private func save() {
        // Same double-tap guard as `AddBookView`/`AddChapterView`/
        // `AddHighlightView` in the host app: the toolbar button only
        // becomes `.disabled` once `isSaving` is read on a later render
        // pass, so a fast second tap in that window used to be able to fire
        // `save()` twice and insert two identical highlights.
        guard !isSaving else { return }
        let trimmed = quoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let container = ShareExtensionStore.makeContainer() else {
            errorMessage = "Couldn't open your Cobux library."
            return
        }
        isSaving = true

        let context = ModelContext(container)
        let highlight = Highlight(text: trimmed, isReminder: false)

        if let selectedBookID {
            var bookDescriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.id == selectedBookID })
            bookDescriptor.fetchLimit = 1
            if let book = (try? context.fetch(bookDescriptor))?.first {
                highlight.book = book
                book.highlights.append(highlight)
            }
        }

        context.insert(highlight)

        do {
            try context.save()
        } catch {
            isSaving = false
            errorMessage = "Couldn't save this quote. Try again from the app."
            return
        }

        SpotlightIndexer.index(highlight)
        CrossProcessSync.markDirty()
        onComplete()
    }
}
