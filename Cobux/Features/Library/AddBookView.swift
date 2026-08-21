import SwiftUI
import SwiftData
import WidgetKit
struct AddBookView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var author = ""
    @State private var selectedColorHex = "#6366F1"
    @State private var isSaving = false

    let presetColors = ["#6366F1", "#8B5CF6", "#EC4899", "#F59E0B", "#10B981", "#3B82F6", "#EF4444", "#6B7280"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Book Details") {
                    TextField("Title", text: $title)
                    TextField("Author", text: $author)
                }

                Section("Cover Color") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 40))], spacing: 16) {
                        ForEach(presetColors, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 40, height: 40)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white, lineWidth: selectedColorHex == hex ? 3 : 0)
                                )
                                .overlay(
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.white)
                                        .opacity(selectedColorHex == hex ? 1 : 0)
                                )
                                .onTapGesture {
                                    withAnimation {
                                        selectedColorHex = hex
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("Add Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveBook()
                    }
                    .disabled(title.isEmpty || author.isEmpty || isSaving)
                }
            }
        }
    }

    private func saveBook() {
        // A quick real-device double-tap on "Save" (the toolbar button stays
        // interactive for the ~0.3s the sheet takes to actually dismiss) used
        // to insert two identical books before the sheet closed once -- this
        // guard makes the second tap a no-op instead of a silent duplicate.
        guard !isSaving else { return }
        isSaving = true
        let newBook = Book(title: title, author: author, coverColorHex: selectedColorHex)
        modelContext.insert(newBook)
        WidgetCenter.shared.reloadAllTimelines()
        dismiss()
    }
}
