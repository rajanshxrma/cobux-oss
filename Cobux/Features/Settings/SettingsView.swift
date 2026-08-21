import SwiftUI
import SwiftData
import AVFoundation
import CobuxCore
import UIKit

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var books: [Book]
    @Query private var highlights: [Highlight]
    @Query private var chapters: [Chapter]
    @Query private var chatMessages: [ChatMessage]
    @Query private var personalWritingEntries: [PersonalWritingEntry]
    @Query private var quizAttempts: [QuizAttempt]

    @AppStorage("themePreference") private var themeRaw: String = ThemePreference.system.rawValue
    @AppStorage(UserPersona.storageKey) private var personaRaw: String = UserPersona.retention.rawValue
    // Same default as `ChatView`'s copy of this key (Rajan explicitly asked
    // for this feature) — the one other place this exact key is read, so the
    // toggle here and the retrieval gate in chat always agree.
    @AppStorage("personalWritingContextEnabled") private var personalWritingContextEnabled: Bool = true
    // Defaults ON as of 2.5.3 -- Rajan had reserved this decision and has now
    // made it. Must stay identical to `ChatView`'s copy of this key; the two
    // disagreeing would mean the toggle shown here and the behaviour in chat
    // came from different defaults. Only ever reachable behind
    // `personalWritingContextEnabled`, which itself only matters once someone
    // has explicitly imported personal writing -- nothing is imported unasked.
    @AppStorage("useRealNamesInLifeExamples") private var useRealNamesInLifeExamples: Bool = true
    @AppStorage(JournalLockStatus.enabledKey) private var journalLockEnabled: Bool = true
    @State private var crashReports: [CrashReportCollector.StoredReport] = []
    private let updateStatus = UpdateAvailabilityStatus.shared
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
    @State private var showPersonalWritingImporter = false
    @State private var personalWritingImportMessage: String?
    @State private var isImportingPersonalWriting = false
    @State private var showAppleJournalImporter = false
    @State private var appleJournalImportMessage: String?
    @State private var isImportingAppleJournal = false
    @State private var showDeletePersonalWritingConfirm = false
    @State private var bookSuggestionTitle = ""
    @State private var bookSuggestionAuthor = ""
    @State private var bookSuggestionMessage: String?
    @State private var autoBackupManifest: BackupSnapshotManifest?
    @State private var isRestoringFromICloud = false

    var body: some View {
        // Pushed from MoreView's own NavigationStack -- no nested stack here,
        // which used to produce a doubled navigation bar.
        Form {
                CobuxFormSection(title: "Appearance") {
                    Picker("Theme", selection: $themeRaw) {
                        ForEach(ThemePreference.allCases) { theme in
                            Text(theme.label).tag(theme.rawValue)
                        }
                    }
                }

                CobuxFormSection(
                    title: "Focus",
                    footer: "Tunes how Cobux frames its recommendations. Every choice keeps the full feature set."
                ) {
                    Picker("I'm here to", selection: $personaRaw) {
                        ForEach(UserPersona.allCases) { persona in
                            Text(persona.title).tag(persona.rawValue)
                        }
                    }
                }

                // Same setting as Flow's own top-bar button writes -- one key,
                // two doors, so it's configurable without having to open the
                // feed first.
                CobuxFormSection(
                    title: "Flow and Wisdom",
                    footer: "Choose which books the Flow feed and the Wisdom Graph pull from. All of them, unless you say otherwise — except reference textbooks, which start off because their sheer highlight count would crowd out the rest of your library."
                ) {
                    NavigationLink {
                        BookSourceFilterView()
                    } label: {
                        Label("Books in Flow and Wisdom", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }

                CobuxFormSection(
                    title: "Voice Mode",
                    footer: "The voice Cobux speaks with in Voice Mode. Higher-quality voices sound more natural but take up more storage on your device."
                ) {
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
                }

                CobuxFormSection(
                    title: "AI Chat",
                    footer: "Your Anthropic API key is stored securely on this device and used only to talk to Claude. It's never included in the app itself. The spend estimate above is calculated from Claude's own token counts on this device, and only counts chat -- quiz generation is tracked separately below, since it's a different, much smaller, one-time-per-chapter cost. Neither is the same as Anthropic's own billing, which is always the final word."
                ) {
                    CobuxSettingsRow(
                        icon: "key.fill",
                        label: "Status",
                        value: hasStoredKey ? "Key set" : "No key",
                        valueColor: hasStoredKey ? Color.cobuxGood : .secondary
                    )
                    SecureField("Anthropic API Key (sk-...)", text: $apiKeyDraft)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                    Button("Save") {
                        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        // `KeychainManager.save` can genuinely fail (e.g. a
                        // Keychain error) -- this used to report "Saved" and
                        // flip `hasStoredKey` regardless, so a failed save
                        // looked identical to a real one until the next chat
                        // call mysteriously failed with no key found.
                        if KeychainManager.save(key: KeychainManager.anthropicAPIKey, data: trimmed) {
                            apiKeyDraft = ""
                            hasStoredKey = true
                            saveConfirmation = "Saved"
                        } else {
                            saveConfirmation = "Couldn't save the key. Try again."
                        }
                    }
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasStoredKey {
                        Button("Remove Key", role: .destructive) {
                            if KeychainManager.delete(key: KeychainManager.anthropicAPIKey) {
                                hasStoredKey = false
                                saveConfirmation = "Removed"
                            } else {
                                saveConfirmation = "Couldn't remove the key. Try again."
                            }
                        }
                    }
                    if let saveConfirmation {
                        Text(saveConfirmation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    CobuxSettingsRow(
                        icon: "dollarsign.circle.fill",
                        label: "Estimated spend this month",
                        value: formattedChatEstimate
                    )
                }
                .onAppear {
                    hasStoredKey = KeychainManager.load(key: KeychainManager.anthropicAPIKey)?.isEmpty == false
                }

                CobuxFormSection(
                    title: "Quiz Generation",
                    footer: "Generating a chapter's quiz questions spends a small amount from your Anthropic key -- typically a fraction of a cent per chapter, and only once per chapter unless its content changes. Once this month's estimated generation spend above would cross the budget cap, new generation is blocked until you raise it or the month resets. Tracked separately from chat spend above, since they're different, unrelated costs."
                ) {
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
                    CobuxSettingsRow(
                        icon: "sparkles",
                        label: "Estimated generation spend this month",
                        value: formattedGenerationEstimate
                    )
                }

                CobuxFormSection(
                    title: "Data",
                    footer: "Cobux also backs itself up to your iCloud automatically, once a day, private to your account -- three rotating snapshots, silently restored if you ever reinstall. \"Export Backup\" below is separate: a one-off JSON file of your books, chapters, highlights, chat history, quiz questions and history (including your earned review progress), and imported personal writing, for saving anywhere (Files, iCloud Drive, AirDrop) by hand."
                ) {
                    CobuxSettingsRow(icon: "books.vertical.fill", label: "Books", value: "\(books.count)")
                    CobuxSettingsRow(icon: "highlighter", label: "Highlights", value: "\(highlights.count)")
                    CobuxSettingsRow(icon: "list.number", label: "Chapters", value: "\(chapters.count)")

                    if let autoBackupManifest {
                        CobuxSettingsRow(icon: "icloud.fill", label: "Last Automatic Backup", value: autoBackupManifest.latestDate.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        CobuxSettingsRow(icon: "icloud.slash", label: "Last Automatic Backup", value: "Not yet")
                    }

                    Button("Export Backup") {
                        do {
                            let data = try BackupService.exportData(books: books, chatMessages: chatMessages, personalWritingEntries: personalWritingEntries, quizAttempts: quizAttempts)
                            exportDocument = BackupFileDocument(data: data)
                            showExporter = true
                        } catch {
                            backupMessage = "Couldn't create backup: \(error.localizedDescription)"
                        }
                    }
                    // `BackupService.exportData` faults every book's `chapters`/
                    // `highlights` relationships (and each chapter's `quizQuestions`)
                    // to build the DTOs -- the same relationship-fault-vs-seed-merge
                    // race already fixed at BookCard/QuizHomeView/ContentView's sync
                    // call. Settings has no seeding gate of its own (unlike those),
                    // and Settings is reachable via the tab bar during the first-
                    // launch seed window, so tapping this before the seed lands
                    // could crash. Disabled instead of hidden -- it's a brief,
                    // self-resolving window, not a feature this device lacks.
                    .disabled(SeedingStatus.shared.isSeeding)
                    Button("Restore from Backup") {
                        showImporter = true
                    }
                    // The manual escape hatch for the one case the silent
                    // automatic restore deliberately never fires on -- a
                    // store that was degraded (see `StoreHealthStatus`) at
                    // launch and has since recovered. Never gated on the
                    // automatic restore's own one-shot flag: an explicit tap
                    // here is a real ask, not an opportunistic background
                    // check, so it always tries.
                    Button("Restore from iCloud Backup") {
                        Task { await restoreFromICloudManually() }
                    }
                    .disabled(isRestoringFromICloud || SeedingStatus.shared.isSeeding)
                    if isRestoringFromICloud {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Restoring…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if SeedingStatus.shared.isSeeding {
                        Text("Your library is still being set up — export will be available in a moment.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let backupMessage {
                        Text(backupMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    CobuxSettingsRow(icon: "person.text.rectangle.fill", label: "Personal Writing Entries", value: "\(personalWritingEntries.count)")

                    Toggle("Require Face ID for Journal", isOn: $journalLockEnabled)
                    Text("Locks the Journal tab (More > Journal) behind Face ID or your device passcode. Nothing else in Cobux is affected — this is on by default since journal entries are the most personal thing stored here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Use my personal writing in chat replies", isOn: $personalWritingContextEnabled)
                    Text("When on, relevant excerpts from your imported personal writing (journal entries, reflections) are sent to Claude the same way book highlights already are, so replies can draw on them — including as brief lived examples woven into an answer where one genuinely fits. This content can be genuinely personal — turn it off anytime to stop it from being used in chat.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if personalWritingContextEnabled {
                        Toggle("Use real names in life examples", isOn: $useRealNamesInLifeExamples)
                        Text("When on, replies can name the people you've written about. Turn it off and they're referred to only by role or relationship (\"a friend\", \"someone you wrote about\"), never by name.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Import Personal Writing") {
                        showPersonalWritingImporter = true
                    }
                    // Embedding each entry means this can genuinely take a
                    // few seconds on a real journal-sized import -- with no
                    // indicator at all, a tap that seemed to do nothing was
                    // the only feedback until it silently finished. Disabling
                    // the button doubles as double-tap protection: nothing
                    // previously stopped picking a second file mid-import.
                    .disabled(isImportingPersonalWriting)
                    if isImportingPersonalWriting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Importing…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !personalWritingEntries.isEmpty {
                        Button("Delete All Personal Writing", role: .destructive) {
                            showDeletePersonalWritingConfirm = true
                        }
                    }
                    if let personalWritingImportMessage {
                        Text(personalWritingImportMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    Button("Import from Apple Journal") {
                        showAppleJournalImporter = true
                    }
                    .disabled(isImportingAppleJournal)
                    Text("One-time migration for existing Apple Journal entries. In Journal, tap the ⋯ menu > Export Journal, then in Files, long-press the AppleJournalEntries.zip and choose Uncompress. Pick the uncompressed folder here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if isImportingAppleJournal {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Importing…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let appleJournalImportMessage {
                        Text(appleJournalImportMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // No backend to auto-train on -- a user just names a book and it
                // goes to Rajan by email, same "manually review, then ship a build
                // with it" flow every other seeded book already goes through
                // (see docs/adding-a-book.md). Nothing here touches the model
                // context or the library at all; it's a mail composer, not a
                // feature request queue this app can act on by itself.
                CobuxFormSection(
                    title: "Suggest a Book",
                    footer: "Know a book you'd love to see in Cobux? Send the title (and author, if you know it) and it'll be considered for a future update."
                ) {
                    TextField("Book title", text: $bookSuggestionTitle)
                    TextField("Author (optional)", text: $bookSuggestionAuthor)
                    Button("Send Suggestion") {
                        sendBookSuggestion()
                    }
                    .disabled(bookSuggestionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let bookSuggestionMessage {
                        Text(bookSuggestionMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Only appears when MetricKit has actually captured a crash —
                // zero UI weight the (hopefully) overwhelming majority of the
                // time. Exists because a real tester crash produced nothing
                // actionable through Apple's own channels; now the report is
                // right here, exportable by the tester themselves.
                if !crashReports.isEmpty {
                    CobuxFormSection(
                        title: "Crash Reports",
                        footer: "The app crashed recently and captured its own diagnostic report. Share it with the developer so the crash can be fixed."
                    ) {
                        NavigationLink {
                            CrashReportsListView(reports: crashReports)
                        } label: {
                            Label("\(crashReports.count) Crash Report\(crashReports.count == 1 ? "" : "s")", systemImage: "ladybug.fill")
                        }
                    }
                }

                CobuxFormSection(
                    title: "About",
                    footer: "TestFlight builds always expire 90 days after upload — an Apple platform rule, not something this app controls. A new build resets this whenever one ships, which happens often during active development."
                ) {
                    CobuxSettingsRow(icon: "info.circle.fill", label: "Version", value: appVersion)
                    CobuxSettingsRow(icon: "person.fill", label: "Developer", value: "Rajan Sharma")
                    CobuxSettingsRow(
                        icon: "clock.fill",
                        label: "TestFlight renews in",
                        value: "\(BuildInfo.daysUntilExpiry) day\(BuildInfo.daysUntilExpiry == 1 ? "" : "s")",
                        valueColor: BuildInfo.daysUntilExpiry <= 14 ? Color.cobuxWarning : Color.secondary
                    )
                    // Undismissable mirror of `ContentView`'s update banner -- that
                    // banner can be swiped away for good once acknowledged, so this
                    // is the one place the state stays visible for as long as it's
                    // actually true.
                    if updateStatus.updateAvailable {
                        CobuxSettingsRow(
                            icon: "arrow.down.circle.fill",
                            iconTint: Color.cobuxAccent,
                            label: "Update available",
                            value: updateStatus.latestVersion,
                            valueColor: Color.cobuxAccent
                        )
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear { crashReports = CrashReportCollector.savedReports() }
            .task { autoBackupManifest = await AutoBackupService.currentManifest() }
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
            .fileImporter(isPresented: $showPersonalWritingImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    importPersonalWriting(from: url)
                case .failure(let error):
                    personalWritingImportMessage = "Import failed: \(error.localizedDescription)"
                }
            }
            // `.folder`, not `.zip` -- see `AppleJournalImportService`'s doc
            // comment on why this deliberately expects an already-uncompressed
            // folder instead of parsing the raw export archive.
            .fileImporter(isPresented: $showAppleJournalImporter, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    importAppleJournal(from: url)
                case .failure(let error):
                    appleJournalImportMessage = "Import failed: \(error.localizedDescription)"
                }
            }
            .alert("Delete all personal writing?", isPresented: $showDeletePersonalWritingConfirm) {
                Button("Cancel", role: .cancel) { }
                Button("Delete All", role: .destructive) { deleteAllPersonalWriting() }
            } message: {
                Text("This permanently removes every imported personal writing entry from this device. It can't be undone — you'd need to re-import to bring it back.")
            }
    }

    // Turning the toggle off only stops future chat turns from using this
    // content -- it doesn't remove anything already imported, so a real,
    // permanent delete matters here given how personal this content can be
    // (see `PersonalWritingImportService.deleteAll`'s own doc comment).
    private func deleteAllPersonalWriting() {
        do {
            let count = try PersonalWritingImportService.deleteAll(modelContext: modelContext)
            personalWritingImportMessage = "Deleted \(count) entries."
        } catch {
            personalWritingImportMessage = "Couldn't delete: \(error.localizedDescription)"
        }
    }

    /// A `mailto:` link, not a queue this app can act on by itself -- Cobux has
    /// no backend, and auto-training on an uploaded PDF is explicitly out of
    /// scope per the request this came from. Rajan reviews suggestions by hand
    /// and ships them the normal way (docs/adding-a-book.md) if he picks one up.
    private func sendBookSuggestion() {
        let title = bookSuggestionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let author = bookSuggestionAuthor.trimmingCharacters(in: .whitespacesAndNewlines)

        var bodyLines = ["Book: \(title)"]
        if !author.isEmpty { bodyLines.append("Author: \(author)") }
        let body = bodyLines.joined(separator: "\n")
        let subject = "Cobux book suggestion: \(title)"
        let recipient = "rajansharma9118@gmail.com"

        let allowed = CharacterSet.urlQueryAllowed
        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: allowed) ?? subject
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? body

        guard let url = URL(string: "mailto:\(recipient)?subject=\(encodedSubject)&body=\(encodedBody)"),
              UIApplication.shared.canOpenURL(url) else {
            bookSuggestionMessage = "Couldn't open Mail. Email \(recipient) directly with your suggestion."
            return
        }
        UIApplication.shared.open(url)
        bookSuggestionTitle = ""
        bookSuggestionAuthor = ""
        bookSuggestionMessage = "Opened Mail — send it from there to submit your suggestion."
    }

    private func importBackup(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            backupMessage = "Couldn't access that file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            let result = try BackupService.importData(data, existingBooks: books, existingChatMessages: chatMessages, existingPersonalWritingEntries: personalWritingEntries, modelContext: modelContext)
            if result.booksImported == 0 && result.chatMessagesImported == 0 && result.highlightMemoriesImported == 0 && result.quizQuestionsImported == 0 && result.personalWritingEntriesImported == 0 {
                backupMessage = "Nothing new to import — everything in that backup already exists here."
            } else {
                var parts: [String] = []
                if result.booksImported > 0 { parts.append("\(result.booksImported) book(s)") }
                if result.chatMessagesImported > 0 { parts.append("\(result.chatMessagesImported) chat message(s)") }
                if result.highlightMemoriesImported > 0 { parts.append("\(result.highlightMemoriesImported) review record(s)") }
                if result.quizQuestionsImported > 0 { parts.append("\(result.quizQuestionsImported) quiz question(s)") }
                if result.personalWritingEntriesImported > 0 {
                    let noun = result.personalWritingEntriesImported == 1 ? "entry" : "entries"
                    parts.append("\(result.personalWritingEntriesImported) personal writing \(noun)")
                }
                backupMessage = "Imported " + parts.joined(separator: ", ") + "."
            }
        } catch {
            backupMessage = "Couldn't read that backup: \(error.localizedDescription)"
        }
    }

    /// The manual counterpart to `AutoRestoreService.restoreIfNeeded` --
    /// same download-and-import path, but explicitly requested (so it skips
    /// that service's "only a genuinely fresh install" guards) and reachable
    /// any time, including the one real case the silent automatic restore
    /// deliberately never covers: a store that was degraded at launch and
    /// has since recovered (see `AutoRestoreService`'s own doc comment on
    /// why restoring a degraded store is worse than doing nothing).
    private func restoreFromICloudManually() async {
        isRestoringFromICloud = true
        defer { isRestoringFromICloud = false }

        guard let documentsURL = await UbiquityContainer.shared.documentsURL() else {
            backupMessage = "No iCloud backup found for this account yet."
            return
        }
        let backupsDir = documentsURL.appendingPathComponent("Backups", isDirectory: true)
        guard let manifest = BackupSnapshotManifest.read(from: backupsDir) else {
            backupMessage = "No iCloud backup found yet -- one is created automatically once a day."
            return
        }

        let snapshotURL = backupsDir.appendingPathComponent(manifest.latestFilename)
        guard await UbiquityContainer.shared.waitForDownload(of: snapshotURL) else {
            backupMessage = "Couldn't download the iCloud backup -- try again in a moment."
            return
        }
        guard let data = try? Data(contentsOf: snapshotURL) else {
            backupMessage = "Couldn't read the downloaded backup."
            return
        }

        do {
            let result = try BackupService.importData(data, existingBooks: books, existingChatMessages: chatMessages, existingPersonalWritingEntries: personalWritingEntries, existingQuizAttempts: quizAttempts, modelContext: modelContext)
            if result.booksImported == 0 && result.chatMessagesImported == 0 && result.highlightMemoriesImported == 0 && result.quizQuestionsImported == 0 && result.personalWritingEntriesImported == 0 && result.quizAttemptsImported == 0 {
                backupMessage = "Nothing new to restore -- everything in that backup already exists here."
            } else {
                var parts: [String] = []
                if result.booksImported > 0 { parts.append("\(result.booksImported) book(s)") }
                if result.chatMessagesImported > 0 { parts.append("\(result.chatMessagesImported) chat message(s)") }
                if result.highlightMemoriesImported > 0 { parts.append("\(result.highlightMemoriesImported) review record(s)") }
                if result.quizQuestionsImported > 0 { parts.append("\(result.quizQuestionsImported) quiz question(s)") }
                if result.quizAttemptsImported > 0 { parts.append("\(result.quizAttemptsImported) quiz attempt(s)") }
                if result.personalWritingEntriesImported > 0 {
                    let noun = result.personalWritingEntriesImported == 1 ? "entry" : "entries"
                    parts.append("\(result.personalWritingEntriesImported) personal writing \(noun)")
                }
                backupMessage = "Restored " + parts.joined(separator: ", ") + " from iCloud."
            }
            await AutoRestoreService.downloadPendingAttachments(modelContext: modelContext)
        } catch {
            backupMessage = "Couldn't restore: \(error.localizedDescription)"
        }
    }

    /// Same security-scoped-resource pattern as `importBackup` above, adapted
    /// for `PersonalWritingImportService.importData`'s `async throws`
    /// signature (it yields periodically while embedding, unlike
    /// `BackupService.importData`'s synchronous pass) — the file is read
    /// synchronously (inside the security scope) before handing the bytes to
    /// an unstructured `Task`, so `stopAccessingSecurityScopedResource` still
    /// fires immediately after the read completes rather than being held for
    /// the whole import.
    private func importPersonalWriting(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            personalWritingImportMessage = "Couldn't access that file."
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            url.stopAccessingSecurityScopedResource()
            personalWritingImportMessage = "Couldn't read that file: \(error.localizedDescription)"
            return
        }
        url.stopAccessingSecurityScopedResource()

        isImportingPersonalWriting = true
        Task {
            do {
                let result = try await PersonalWritingImportService.importData(data, modelContext: modelContext)
                await MainActor.run {
                    isImportingPersonalWriting = false
                    personalWritingImportMessage = "Imported \(result.imported) entries, \(result.skippedDuplicates) already present."
                }
            } catch {
                await MainActor.run {
                    isImportingPersonalWriting = false
                    personalWritingImportMessage = "Couldn't import: \(error.localizedDescription)"
                }
            }
        }
    }

    /// `.fileImporter` for a FOLDER (not a file) already hands back a URL the
    /// system has scoped for read access for the duration of this call --
    /// unlike `importPersonalWriting` above, the security scope is entered
    /// and exited inside `AppleJournalImportService.importFolder` itself
    /// (it needs to stay open across the whole folder enumeration, not just
    /// one `Data(contentsOf:)` read), so this wrapper only needs to route the
    /// result into the same `isImporting`/message `@State` pattern.
    private func importAppleJournal(from url: URL) {
        isImportingAppleJournal = true
        Task {
            do {
                let result = try await AppleJournalImportService.importFolder(at: url, modelContext: modelContext)
                await MainActor.run {
                    isImportingAppleJournal = false
                    if result.htmlFilesFound == 0 {
                        appleJournalImportMessage = "No entries found in that folder — make sure you picked the uncompressed AppleJournalEntries folder."
                    } else {
                        appleJournalImportMessage = "Imported \(result.imported) entries, \(result.skippedDuplicates) already present."
                    }
                }
            } catch {
                await MainActor.run {
                    isImportingAppleJournal = false
                    appleJournalImportMessage = "Couldn't import: \(error.localizedDescription)"
                }
            }
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

/// One row per crash report used to live directly in Settings, growing the
/// screen with every new crash. This is the drill-in destination instead —
/// Settings shows a single "N Crash Reports" row, and the actual list (and
/// each report's `ShareLink`) lives here.
///
/// Split into two sections rather than one flat list -- the entire point of
/// tagging each report with its build (`CrashReportCollector.StoredReport`)
/// is so a tester or Rajan can tell "this is from the build I'm running right
/// now" from "this is a build I've already fixed and moved past" at a glance,
/// instead of having to open every report's JSON to find out.
private struct CrashReportsListView: View {
    let reports: [CrashReportCollector.StoredReport]

    private var currentBuildReports: [CrashReportCollector.StoredReport] { reports.filter(\.isCurrentBuild) }
    private var staleReports: [CrashReportCollector.StoredReport] { reports.filter { !$0.isCurrentBuild } }

    var body: some View {
        List {
            if !currentBuildReports.isEmpty {
                Section {
                    ForEach(currentBuildReports) { report in
                        row(for: report)
                    }
                } header: {
                    Text("This Build")
                } footer: {
                    Text("Captured on the build you're running now — still worth sharing.")
                }
            }
            if !staleReports.isEmpty {
                Section {
                    ForEach(staleReports) { report in
                        row(for: report)
                    }
                } header: {
                    Text("Older Builds")
                } footer: {
                    Text("From a build before this one — may already be fixed, but still shareable if it looks unfamiliar.")
                }
            }
        }
        .navigationTitle("Crash Reports")
    }

    private func row(for report: CrashReportCollector.StoredReport) -> some View {
        ShareLink(item: report.url) {
            VStack(alignment: .leading, spacing: 2) {
                Label(
                    report.buildVersion == "unknown" ? "Build unknown" : "Build \(report.buildVersion)",
                    systemImage: "ladybug.fill"
                )
                .font(.subheadline)
                Text(report.url.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
