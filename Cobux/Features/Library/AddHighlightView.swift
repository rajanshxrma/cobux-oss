import SwiftUI
import SwiftData
import WidgetKit
struct AddHighlightView: View {
    @Bindable var book: Book
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var books: [Book]

    @State private var text = ""
    @State private var chapter = ""
    @State private var pageString = ""
    @State private var personalNote = ""
    @State private var tagsString = ""
    @State private var isReminder = true
    @State private var didSave = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Quote / Passage") {
                    TextEditor(text: $text)
                        .frame(minHeight: 100)
                }

                Section("Location (Optional)") {
                    TextField("Chapter Name", text: $chapter)
                    TextField("Page Number", text: $pageString)
                        .keyboardType(.numberPad)
                }

                Section("My Thoughts (Optional)") {
                    TextEditor(text: $personalNote)
                        .frame(minHeight: 80)
                }

                Section("Tags (Comma-separated)") {
                    TextField("e.g. discipline, relationships, stoicism", text: $tagsString)
                }

                Section {
                    Toggle("Include in Reminders", isOn: $isReminder)
                }
            }
            .navigationTitle("Add Highlight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveHighlight() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || didSave)
                }
            }
        }
        .sensoryFeedback(.success, trigger: didSave)
    }

    private func saveHighlight() {
        // Same double-tap guard as `AddChapterView`/`AddBookView` -- without
        // it, a fast second tap in the moment before the sheet actually
        // dismisses appended a second, identical highlight.
        guard !didSave else { return }
        let tags = tagsString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let page = Int(pageString)

        let highlight = Highlight(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            chapter: chapter.isEmpty ? nil : chapter,
            page: page,
            personalNote: personalNote.isEmpty ? nil : personalNote.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: tags,
            isReminder: isReminder
        )

        book.highlights.append(highlight)
        highlight.embedding = EmbeddingService.embed(highlight.text)
        SpotlightIndexer.index(highlight)
        WidgetCenter.shared.reloadAllTimelines()
        StreakTracker.recordActivityToday()
        // This sheet dismisses straight back to Library, so any milestone the
        // record just crossed is celebrated by ContentView's overlay.
        StreakCelebrationCenter.shared.checkForPendingMilestone()
        WatchSyncService.sync(books: books)
        didSave = true
        dismiss()
    }
}
