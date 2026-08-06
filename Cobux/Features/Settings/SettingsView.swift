import SwiftUI
import SwiftData
import AVFoundation
import CobuxCore

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var books: [Book]
    @Query private var highlights: [Highlight]
    @Query private var chapters: [Chapter]
    @Query private var chatMessages: [ChatMessage]

    @AppStorage("themePreference") private var themeRaw: String = ThemePreference.system.rawValue
    @State private var selectedVoiceIdentifier: String = VoicePreference.selectedVoice()?.identifier ?? ""

    // Read/written by `QuizGenerationService` directly via matching
    // UserDefaults keys — the same "one durable place to configure it"
    // pattern as the API key above.
    @AppStorage("questionQualityRaw") private var questionQualityRaw: String = QuestionQuality.balanced.rawValue
    @AppStorage("generationBudgetCapDollars") private var budgetCapDollars: Double = BudgetGuard.defaultCapDollars

    // Onboarding is the only OTHER place an Anthropic key can be entered, and
    // it has a "Skip for now" path that never returns — so this is the one
    // durable way to add, change, or remove the key after first launch.
    @State private var apiKeyDraft: String = ""
    @State private var hasStoredKey: Bool = false
    @State private var saveConfirmation: String?
    @State private var exportDocument: BackupFileDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var backupMessage: String?

    var body: some View {
        // Pushed from MoreView's own NavigationStack -- no nested stack here,
        // which used to produce a doubled navigation bar.
        Form {
                Section("Appearance") {
                    Picker("Theme", selection: $themeRaw) {
                        ForEach(ThemePreference.allCases) { theme in
                            Text(theme.label).tag(theme.rawValue)
                        }
                    }
                }

                Section {
                    let voices = VoicePreference.availableVoices()
                    Picker("Voice", selection: $selectedVoiceIdentifier) {
                        ForEach(voices, id: \.identifier) { voice in
                            Text(voice.cobuxDisplayLabel).tag(voice.identifier)
                        }
                    }
                    .onChange(of: selectedVoiceIdentifier) { _, newValue in
                        VoicePreference.selectedVoiceIdentifier = newValue.isEmpty ? nil : newValue
                    }
                    if VoicePreference.onlyDefaultQualityVoicesAvailable {
                        Text("For a more natural voice, download an Enhanced or Premium voice in iOS Settings → Accessibility → Spoken Content → Voices.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Voice Mode")
                } footer: {
                    Text("The voice Cobux speaks with in Voice Mode. Higher-quality voices sound more natural but take up more storage on your device.")
                }

                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(hasStoredKey ? "Key set" : "No key")
                            .foregroundStyle(hasStoredKey ? .green : .secondary)
                    }
                    SecureField("Anthropic API Key (sk-...)", text: $apiKeyDraft)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                    Button("Save") {
                        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        KeychainManager.save(key: KeychainManager.anthropicAPIKey, data: trimmed)
                        apiKeyDraft = ""
                        hasStoredKey = true
                        saveConfirmation = "Saved"
                    }
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasStoredKey {
                        Button("Remove Key", role: .destructive) {
                            KeychainManager.delete(key: KeychainManager.anthropicAPIKey)
                            hasStoredKey = false
                            saveConfirmation = "Removed"
                        }
                    }
                    if let saveConfirmation {
                        Text(saveConfirmation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Estimated spend this month")
                        Spacer()
                        Text(formattedChatEstimate)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("AI Chat")
                } footer: {
                    Text("Your Anthropic API key is stored securely on this device and used only to talk to Claude. It's never included in the app itself. The spend estimate above is calculated from Claude's own token counts on this device, and only counts chat -- quiz generation is tracked separately below, since it's a different, much smaller, one-time-per-chapter cost. Neither is the same as Anthropic's own billing, which is always the final word.")
                }
                .onAppear {
                    hasStoredKey = KeychainManager.load(key: KeychainManager.anthropicAPIKey)?.isEmpty == false
                }

                Section {
                    Picker("Question Quality", selection: $questionQualityRaw) {
                        ForEach(QuestionQuality.allCases) { quality in
                            Text(quality.label).tag(quality.rawValue)
                        }
                    }
                    if let quality = QuestionQuality(rawValue: questionQualityRaw) {
                        Text(quality.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Stepper(
                        "Generation budget: $\(String(format: "%.2f", budgetCapDollars))",
                        value: $budgetCapDollars, in: 0.50...20.0, step: 0.50
                    )
                    HStack {
                        Text("Estimated generation spend this month")
                        Spacer()
                        Text(formattedGenerationEstimate)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Quiz Generation")
                } footer: {
                    Text("Generating a chapter's quiz questions spends a small amount from your Anthropic key -- typically a fraction of a cent per chapter, and only once per chapter unless its content changes. Once this month's estimated generation spend above would cross the budget cap, new generation is blocked until you raise it or the month resets. Tracked separately from chat spend above, since they're different, unrelated costs.")
                }

                Section {
                    HStack { Text("Books"); Spacer(); Text("\(books.count)").foregroundStyle(.secondary) }
                    HStack { Text("Highlights"); Spacer(); Text("\(highlights.count)").foregroundStyle(.secondary) }
                    HStack { Text("Chapters"); Spacer(); Text("\(chapters.count)").foregroundStyle(.secondary) }

                    Button("Export Backup") {
                        do {
                            let data = try BackupService.exportData(books: books, chatMessages: chatMessages)
                            exportDocument = BackupFileDocument(data: data)
                            showExporter = true
                        } catch {
                            backupMessage = "Couldn't create backup: \(error.localizedDescription)"
                        }
                    }
                    Button("Restore from Backup") {
                        showImporter = true
                    }
                    if let backupMessage {
                        Text(backupMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("There's no automatic sync between devices — export creates a JSON file of your books, chapters, highlights, chat history, and quiz questions (including your earned review progress) you can save anywhere (Files, iCloud Drive, AirDrop) and restore later if this phone is lost or reset.")
                }

                Section {
                    HStack { Text("Version"); Spacer(); Text(appVersion).foregroundStyle(.secondary) }
                    HStack { Text("Developer"); Spacer(); Text("Rajan Sharma").foregroundStyle(.secondary) }
                    HStack {
                        Text("TestFlight renews in")
                        Spacer()
                        Text("\(BuildInfo.daysUntilExpiry) day\(BuildInfo.daysUntilExpiry == 1 ? "" : "s")")
                            .foregroundStyle(BuildInfo.daysUntilExpiry <= 14 ? Color.cobuxWarning : Color.secondary)
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("TestFlight builds always expire 90 days after upload — an Apple platform rule, not something this app controls. A new build resets this whenever one ships, which happens often during active development.")
                }
            }
            .navigationTitle("Settings")
            .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .json, defaultFilename: "cobux-backup") { result in
                switch result {
                case .success: backupMessage = "Backup exported."
                case .failure(let error): backupMessage = "Export failed: \(error.localizedDescription)"
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    importBackup(from: url)
                case .failure(let error):
                    backupMessage = "Import failed: \(error.localizedDescription)"
                }
            }
    }

    private func importBackup(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            backupMessage = "Couldn't access that file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            let result = try BackupService.importData(data, existingBooks: books, existingChatMessages: chatMessages, modelContext: modelContext)
            if result.booksImported == 0 && result.chatMessagesImported == 0 && result.highlightMemoriesImported == 0 && result.quizQuestionsImported == 0 {
                backupMessage = "Nothing new to import — everything in that backup already exists here."
            } else {
                var parts: [String] = []
                if result.booksImported > 0 { parts.append("\(result.booksImported) book(s)") }
                if result.chatMessagesImported > 0 { parts.append("\(result.chatMessagesImported) chat message(s)") }
                if result.highlightMemoriesImported > 0 { parts.append("\(result.highlightMemoriesImported) review record(s)") }
                if result.quizQuestionsImported > 0 { parts.append("\(result.quizQuestionsImported) quiz question(s)") }
                backupMessage = "Imported " + parts.joined(separator: ", ") + "."
            }
        } catch {
            backupMessage = "Couldn't read that backup: \(error.localizedDescription)"
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var formattedChatEstimate: String {
        String(format: "~$%.2f", UsageTracker.currentMonthEstimate(for: .chat))
    }

    private var formattedGenerationEstimate: String {
        String(format: "~$%.2f", UsageTracker.currentMonthEstimate(for: .generation))
    }
}
