import SwiftUI
import SwiftData

/// A short reflection interview shown when the user marks a book finished.
/// Claude synthesizes the user's answers together with the book's existing
/// highlights/chapters into a permanent one-page "Closing Reflection" chapter.
struct ClosingInterviewView: View {
    @Bindable var book: Book
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var claudeService = ClaudeService()

    @State private var whatChangedMind = ""
    @State private var whatToDoDifferently = ""
    @State private var oneMoreThought = ""

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var resultText: String?

    private var hasAnyAnswer: Bool {
        !whatChangedMind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !whatToDoDifferently.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !oneMoreThought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if let resultText {
                    resultView(resultText)
                } else {
                    formView
                }
            }
            .navigationTitle("Closing Interview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(resultText == nil ? "Cancel" : "Discard") { dismiss() }
                }
            }
            .onAppear {
                // Reflect the current keychain state, mirroring ChatView.checkAPIKey().
                claudeService.apiKey = KeychainManager.load(key: KeychainManager.anthropicAPIKey) ?? ""
            }
        }
    }

    // MARK: - Form

    private var formView: some View {
        Form {
            Section {
                Text("You just finished \u{201C}\(book.title)\u{201D}. A few quick questions before Cobux writes your permanent reflection. Answer as many as you like. Generating it uses your Anthropic API credits.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)

            Section("What actually changed your mind reading this?") {
                TextEditor(text: $whatChangedMind)
                    .frame(minHeight: 80)
            }

            Section("What will you do differently now?") {
                TextEditor(text: $whatToDoDifferently)
                    .frame(minHeight: 80)
            }

            Section("Anything else worth remembering?") {
                TextEditor(text: $oneMoreThought)
                    .frame(minHeight: 80)
            }

            if claudeService.apiKey.isEmpty {
                Section {
                    Label("Add your Anthropic API key in Settings to generate a reflection.", systemImage: "key.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button(action: generateReflection) {
                    HStack {
                        Spacer()
                        if isLoading {
                            ProgressView()
                                .padding(.trailing, 8)
                        }
                        Text(isLoading ? "Writing..." : "Generate Reflection")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(isLoading || !hasAnyAnswer || claudeService.apiKey.isEmpty)
                .listRowBackground(
                    (isLoading || !hasAnyAnswer || claudeService.apiKey.isEmpty)
                        ? Color.secondary.opacity(0.15)
                        : Color.cobuxAccent
                )
                .foregroundStyle(
                    (isLoading || !hasAnyAnswer || claudeService.apiKey.isEmpty) ? Color.secondary : Color.white
                )
            }
        }
    }

    // MARK: - Result

    private func resultView(_ text: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Closing Reflection", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(Color.cobuxAccent)

                Text(attributedResult(text))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cobuxCard()

                Button(action: saveReflection) {
                    Text("Save to Book")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.cobuxAccent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: CobuxRadius.card))
                }
            }
            .padding()
        }
    }

    private func attributedResult(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    // MARK: - Actions

    private func generateReflection() {
        guard !claudeService.apiKey.isEmpty else { return }
        errorMessage = nil
        isLoading = true

        let bookContextString = buildBookContext()
        let answersString = buildAnswersString()
        let systemPrompt = String(format: PromptTemplates.closingInterview, bookContextString, answersString)

        Task {
            do {
                let text = try await claudeService.sendMessage(
                    userMessage: "Write my closing reflection.",
                    conversationHistory: [],
                    systemPrompt: systemPrompt
                )
                await MainActor.run {
                    isLoading = false
                    resultText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func saveReflection() {
        guard let resultText else { return }
        let chapter = Chapter(title: "\u{1F4DD} Closing Reflection", summary: resultText, keyLessons: [], chapterNumber: nil)
        chapter.book = book
        book.chapters.append(chapter)
        try? modelContext.save()
        dismiss()
    }

    // MARK: - Context builders

    /// Plain-text summary of this book's highlights and chapters for the closing-interview prompt.
    /// Single-book, so a simple local builder is enough — no need for SearchService's library-wide context.
    private func buildBookContext() -> String {
        var lines: [String] = []

        if !book.highlights.isEmpty {
            lines.append("Highlights:")
            for highlight in book.highlights.sorted(by: { $0.dateAdded < $1.dateAdded }) {
                var line = "- \"\(highlight.text)\""
                if let chapter = highlight.chapter, !chapter.isEmpty {
                    line += " (\(chapter))"
                }
                if let note = highlight.personalNote, !note.isEmpty {
                    line += " \u{2014} note: \(note)"
                }
                lines.append(line)
            }
        }

        if !book.chapters.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("Chapters:")
            for chapter in book.chapters.sorted(by: { ($0.chapterNumber ?? 0) < ($1.chapterNumber ?? 0) }) {
                lines.append("- \(chapter.title): \(chapter.summary)")
                for lesson in chapter.keyLessons {
                    lines.append("  \u{2022} \(lesson)")
                }
            }
        }

        if lines.isEmpty {
            return "No highlights or chapters recorded for this book yet."
        }
        return lines.joined(separator: "\n")
    }

    private func buildAnswersString() -> String {
        var parts: [String] = []
        let changedMind = whatChangedMind.trimmingCharacters(in: .whitespacesAndNewlines)
        let toDoDifferently = whatToDoDifferently.trimmingCharacters(in: .whitespacesAndNewlines)
        let more = oneMoreThought.trimmingCharacters(in: .whitespacesAndNewlines)

        if !changedMind.isEmpty {
            parts.append("What changed your mind: \(changedMind)")
        }
        if !toDoDifferently.isEmpty {
            parts.append("What you'll do differently: \(toDoDifferently)")
        }
        if !more.isEmpty {
            parts.append("Anything else worth remembering: \(more)")
        }
        return parts.joined(separator: "\n")
    }
}
