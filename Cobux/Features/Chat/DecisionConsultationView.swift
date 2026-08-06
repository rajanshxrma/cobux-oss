import SwiftUI
import SwiftData

/// A focused, structured alternative to free-form chat: the user describes a
/// decision (situation, options, stakes) and gets a single grounded answer
/// weighing each option against their book library, powered by
/// `PromptTemplates.decisionConsultation`.
struct DecisionConsultationView: View {
    @Bindable var claudeService: ClaudeService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var books: [Book]

    @State private var situation = ""
    @State private var options: [String] = ["", ""]
    @State private var stakes = ""

    @State private var isLoading = false
    @State private var resultText: String?
    @State private var errorText: String?
    @State private var showNoAPIKeyAlert = false

    private var nonEmptyOptions: [String] {
        options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private var canSubmit: Bool {
        !situation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && nonEmptyOptions.count >= 2
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
            .navigationTitle("Decision Consultation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear(perform: checkAPIKey)
            .alert("API Key Required", isPresented: $showNoAPIKeyAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Please configure your Anthropic API Key in Settings to use Decision Consultation.")
            }
        }
    }

    // MARK: - Form

    private var formView: some View {
        Form {
            Section {
                Text("Describe a decision and at least two options, and Claude weighs each one against the wisdom in your library — a single grounded answer, not a back-and-forth chat. Uses your Anthropic API credits.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)

            Section("Situation") {
                TextEditor(text: $situation)
                    .frame(minHeight: 90)
                    .overlay(alignment: .topLeading) {
                        if situation.isEmpty {
                            Text("What are you trying to decide?")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }

            Section("Options") {
                ForEach(options.indices, id: \.self) { index in
                    HStack {
                        TextField("Option \(index + 1)", text: $options[index])
                        if options.count > 2 {
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    _ = options.remove(at: index)
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .onDelete { indexSet in
                    guard options.count - indexSet.count >= 2 else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        options.remove(atOffsets: indexSet)
                    }
                }

                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        options.append("")
                    }
                } label: {
                    Label("Add option", systemImage: "plus.circle.fill")
                }
                .foregroundStyle(Color.cobuxAccent)
            }

            Section {
                TextEditor(text: $stakes)
                    .frame(minHeight: 70)
                    .overlay(alignment: .topLeading) {
                        if stakes.isEmpty {
                            Text("What's at stake? (optional)")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            } header: {
                Text("Stakes")
            } footer: {
                Text("Optional — what makes this decision matter, or what you're afraid of getting wrong.")
            }

            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                }
            }

            Section {
                Button {
                    getGuidance()
                } label: {
                    HStack {
                        Spacer()
                        if isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Get Guidance")
                                .fontWeight(.medium)
                        }
                        Spacer()
                    }
                }
                .listRowBackground(canSubmit && !isLoading ? Color.cobuxAccent : Color.secondary.opacity(0.3))
                .foregroundStyle(.white)
                .disabled(!canSubmit || isLoading)
            }
        }
    }

    // MARK: - Result

    private func resultView(_ text: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(attributedResult(text))
                    .textSelection(.enabled)
                    .padding(18)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                    )

                Button {
                    discussInChat(text)
                } label: {
                    Label("Discuss in Chat", systemImage: "bubble.left.and.bubble.right.fill")
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.cobuxAccent)

                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        resultText = nil
                    }
                } label: {
                    Text("Start Over")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .transition(.opacity.animation(.easeOut(duration: 0.25)))
    }

    private func attributedResult(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    // MARK: - Actions

    private func checkAPIKey() {
        claudeService.apiKey = KeychainManager.load(key: KeychainManager.anthropicAPIKey) ?? ""
    }

    private func getGuidance() {
        guard canSubmit else { return }
        if claudeService.apiKey.isEmpty {
            showNoAPIKeyAlert = true
            return
        }

        errorText = nil
        isLoading = true

        let situationText = situation.trimmingCharacters(in: .whitespacesAndNewlines)
        let stakesText = stakes.trimmingCharacters(in: .whitespacesAndNewlines)
        let optionsList = nonEmptyOptions
        let optionsText = optionsList.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")

        let (contextString, _) = SearchService.buildContext(query: situationText, books: books)
        let systemPrompt = String(
            format: PromptTemplates.decisionConsultation,
            contextString,
            situationText,
            optionsText,
            stakesText.isEmpty ? "Not specified" : stakesText
        )

        Task {
            do {
                let answer = try await claudeService.sendMessage(
                    userMessage: situationText,
                    conversationHistory: [],
                    systemPrompt: systemPrompt
                )
                await MainActor.run {
                    isLoading = false
                    withAnimation(.easeOut(duration: 0.25)) {
                        resultText = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func discussInChat(_ answer: String) {
        let situationText = situation.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()

        let userChatMessage = ChatMessage(content: situationText, isUser: true, timestamp: now, referencedBooks: [])
        modelContext.insert(userChatMessage)

        let aiChatMessage = ChatMessage(content: answer, isUser: false, timestamp: now.addingTimeInterval(0.01), referencedBooks: [])
        modelContext.insert(aiChatMessage)

        dismiss()
    }
}
