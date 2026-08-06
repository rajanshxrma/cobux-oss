import SwiftUI
import SwiftData
struct AddChapterView: View {
    @Bindable var book: Book
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var chapterNumberString = ""
    @State private var summary = ""
    @State private var keyLessons: [String] = [""]
    @State private var didSave = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Chapter Details") {
                    TextField("Title", text: $title)
                    TextField("Chapter Number (Optional)", text: $chapterNumberString)
                        .keyboardType(.numberPad)
                }

                Section("Summary") {
                    TextEditor(text: $summary)
                        .frame(minHeight: 120)
                }

                Section("Key Lessons") {
                    ForEach($keyLessons.indices, id: \.self) { index in
                        HStack {
                            TextField("Lesson", text: $keyLessons[index])
                            if keyLessons.count > 1 {
                                Button(action: { keyLessons.remove(at: index) }) {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                    Button(action: { keyLessons.append("") }) {
                        Label("Add Lesson", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Add Chapter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveChapter() }
                        .disabled(title.isEmpty || summary.isEmpty)
                }
            }
        }
        .sensoryFeedback(.success, trigger: didSave)
    }

    private func saveChapter() {
        let number = Int(chapterNumberString)
        let filteredLessons = keyLessons.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        let chapter = Chapter(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            keyLessons: filteredLessons,
            chapterNumber: number
        )

        book.chapters.append(chapter)
        didSave = true
        dismiss()
    }
}
