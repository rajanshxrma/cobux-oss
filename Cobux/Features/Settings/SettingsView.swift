import SwiftUI
import SwiftData
import AVFoundation
import CobuxCore
import UIKit

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    /// No `@Query private var books: [Book]` any more either.
    ///
    /// It was kept when the five tables beside it went -- every Highlight,
    /// Chapter, ChatMessage, PersonalWritingEntry and QuizAttempt, materialised
    /// on the main actor to show four counts and serve a one-shot export -- on
    /// the grounds that it was "a few dozen rows". It is 156 now and grows with
    /// every book that ships, and its four readers are one displayed COUNT and
    /// three taps (export, restore, iCloud restore). So it follows the same
    /// rule as the rest: the count is a `fetchCount` (`refreshCounts`), and the
    /// rows are fetched at the moment a tap needs them (`allBooks`).
    @State private var bookCount = 0
    @State private var highlightCount = 0
    @State private var chapterCount = 0
    @State private var personalWritingCount = 0

    @AppStorage("themePreference") private var themeRaw: String = ThemePreference.system.rawValue
    @AppStorage(UserPersona.storageKey) private var personaRaw: String = UserPersona.retention.rawValue
    // Defaults OFF as of build 58 and is turned on by Face ID, not by a tap:
    // the first successful journal unlock sets it (see
    // `JournalLockStatus.authenticate`), "Turn off" is free, turning it back
    // on asks Face ID. Rajan: "once the Journal context is turned off, to turn
    // back on the Face ID should be used". Must stay byte-identical to
    // `ChatView`'s copy of this line -- the one other place this exact key is
    // declared -- so the toggle here and the retrieval gate in chat always
    // agree on a fresh install. The key itself is `JournalLockStatus`'s
    // constant, because the journal's Face ID success writes it too.
    @AppStorage(JournalLockStatus.contextEnabledKey) private var personalWritingContextEnabled: Bool = false
    // Written by "Turn off" here and in chat, cleared by a successful "Turn
    // on"; a later journal unlock reads it and leaves the context off. Same
    // key, same semantics as `ChatView`'s copy.
    @AppStorage(JournalLockStatus.contextExplicitlyOffKey) private var personalWritingContextExplicitlyOff: Bool = false
    @State private var isAuthenticatingPersonalWriting = false
    @AppStorage("crossChatMemoryEnabled") private var crossChatMemoryEnabled: Bool = true
    // Defaults ON as of 2.5.3 -- Rajan had reserved this decision and has now
    // made it. Must stay identical to `ChatView`'s copy of this key; the two
    // disagreeing would mean the toggle shown here and the behaviour in chat
    // came from different defaults. Only ever reachable behind
    // `personalWritingContextEnabled`, which itself only matters once someone
    // has explicitly imported personal writing -- nothing is imported unasked.
    @AppStorage("useRealNamesInLifeExamples") private var useRealNamesInLifeExamples: Bool = true
    @AppStorage(JournalLockStatus.enabledKey) private var journalLockEnabled: Bool = true
    @AppStorage(HealthContextService.enabledKey) private var healthContextEnabled: Bool = false
    /// `store:` is load-bearing. Without it `@AppStorage` writes to
    /// `UserDefaults.standard`, while `AmbientContextService.isEnabled` and
    /// `AmbientContext.cached()` read the app-group suite -- so this toggle set
    /// a flag nothing on the reading side could ever see, and temperature and
    /// place never appeared no matter how many times it was switched on. The
    /// line above (`healthContextEnabled`) needs no store because its service
    /// reads `.standard`, which is the whole reason that feature works and this
    /// one did not.
    @AppStorage(AmbientContextService.enabledKey, store: CobuxSchema.groupDefaults)
    private var ambientContextEnabled: Bool = true // default ON since 58 -- his 12 Sep words in AmbientContext.cached()
    @AppStorage("cobux.user.displayName") private var displayName: String = ""
    @State private var showingNamePrompt = false
    @State private var nameDraft = ""
    @State private var deltaSnapshot = DeltaLedger.Snapshot()
    @State private var quietWords: [String] = JournalQuietWords.all()
    @State private var showingQuietWordPrompt = false
    @State private var newQuietWord = ""
    @AppStorage(ClaudeService.extendedThinkingKey) private var extendedThinking: Bool = false
    @State private var crashReports: [CrashReportCollector.StoredReport] = []
    private let updateStatus = UpdateAvailabilityStatus.shared
    /// The user's EXPLICIT pick, or "" for automatic -- deliberately not
    /// `selectedVoice()?.identifier`, which returns the *resolved* voice. Seeding from the
    /// resolved value meant simply opening this screen showed Samantha as the selection, and
    /// any interaction with the picker then persisted her identifier as a deliberate choice.
    /// From that moment `selectedVoice()` returned her explicitly forever and the
    /// best-available fallback never ran again -- so downloading a better voice would have
    /// changed nothing, silently.
    @State private var selectedVoiceIdentifier: String = VoicePreference.selectedVoiceIdentifier ?? ""
    /// The installed voices, read ONCE per visit rather than once per body.
    ///
    /// `VoicePreference.availableVoices()` calls `AVSpeechSynthesisVoice
    /// .speechVoices()`, which asks the speech service to enumerate every voice
    /// installed on the device, and `usingDefaultQualityVoice` calls into it a
    /// second time. Both were being read straight out of `body` — on a screen
    /// with three dozen `@State`/`@AppStorage` properties, so flipping any
    /// toggle on this screen paid for two full voice enumerations, and opening
    /// it paid for the first one before the Form could draw. Voices only change
    /// when someone downloads one in iOS Settings, which is a trip out of the
    /// app and back, and `.task` re-runs on the way back in.
    ///
    /// Empty for the frame before the read lands. The Picker's "Automatic" row
    /// carries the `""` tag and is always present, so the default selection
    /// always matches; only someone who has explicitly pinned a voice sees a
    /// blank value for that one frame, and SwiftUI never writes a Picker's
    /// binding on its own — so the stale-pin trap `selectedVoiceIdentifier`
    /// documents above cannot be reached this way.
    @State private var availableVoices: [AVSpeechSynthesisVoice] = []
    @State private var usingDefaultQualityVoice = false

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
    @State private var isSyncingJournal = false
    @State private var showingAddContact = false
    @State private var contactAddress = ""
    @State private var contactMessage: String?
    @State private var journalSyncMessage: String?
    @State private var isImportingPersonalWriting = false
    @State private var showAppleJournalImporter = false
    @State private var appleJournalImportMessage: String?
    @State private var isImportingAppleJournal = false
    @State private var bookSuggestionTitle = ""
    @State private var bookSuggestionAuthor = ""
    @State private var bookSuggestionMessage: String?
    @State private var autoBackupManifest: BackupSnapshotManifest?
    @State private var isRestoringFromICloud = false

    var body: some View {
        // Pushed from MoreView's own NavigationStack -- no nested stack here,
        // which used to produce a doubled navigation bar.
        Form {
                // "<Name>'s Cobux" -- his ask. The app does not know his name
                // until he offers it, so it starts as "Your Cobux".
                //
                // First on the screen deliberately: everything else here is a
                // control, and this is the only thing that is his.
                CobuxFormSection(
                    title: displayName.isEmpty ? "Your Cobux" : "\(displayName)'s Cobux",
                    footer: "Grown from everything you've written and asked here. It never leaves this device, and it only ever grows."
                ) {
                    CobuxSigilView(snapshot: deltaSnapshot)
                    if displayName.isEmpty {
                        Button {
                            nameDraft = ""
                            showingNamePrompt = true
                        } label: {
                            Label("Add your name", systemImage: "person")
                        }
                        .buttonStyle(.plain)
                    }
                }

                // "Crimson" is the dark red-black look on any device: the
                // fourth choice the ledger carried since the 3.0 repaint
                // reached only phones already in dark mode. See
                // `ThemePreference.crimson`.
                CobuxFormSection(
                    title: "Appearance",
                    footer: "Crimson wears the red-black look whatever your device is set to."
                ) {
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
                // Health opt-in. `HealthContextService.requestAuthorization()` existed with a
                // doc comment saying "called when the user opts in from Settings" -- but that
                // opt-in was never built, so it had ZERO call sites anywhere in the app.
                // Without it HealthKit returns nil forever and the meditation/sleep row beside
                // a journal entry can never render, which is why two separate reminders were
                // closed on a feature that could not possibly work.
                if HealthContextService.isAvailable {
                    CobuxFormSection(
                        title: "Health",
                        footer: "Shows last night's sleep and today's mindful minutes beside a journal entry, so an entry sits next to how you actually slept. Read-only — Cobux never writes to Health, and nothing leaves your device."
                    ) {
                        Toggle("Use Health data in Journal", isOn: $healthContextEnabled)
                            .onChange(of: healthContextEnabled) { _, enabled in
                                guard enabled else { return }
                                Task {
                                    // iOS shows its sheet once; if he declines, the toggle
                                    // must not sit there claiming a permission we don't have.
                                    let granted = await HealthContextService.requestAuthorization()
                                    if !granted { await MainActor.run { healthContextEnabled = false } }
                                }
                            }
                    }
                }

                // The one control that answers the ex problem, and it is his
                // list rather than the app's judgment -- see `JournalQuietWords`
                // for why the app refuses to infer this.
                CobuxFormSection(
                    title: "Quiet words",
                    footer: "Anything containing these words or names will never appear on its own — not under the calendar, not in Ebb, not in Flow. You can still find it by searching or scrolling; Cobux just won't bring it to you."
                ) {
                    ForEach(quietWords, id: \.self) { word in
                        HStack {
                            Text(word)
                            Spacer()
                            Button {
                                JournalQuietWords.remove(word)
                                quietWords = JournalQuietWords.all()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button {
                        newQuietWord = ""
                        showingQuietWordPrompt = true
                    } label: {
                        Label("Quiet a word or name", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                }

                CobuxFormSection(
                    title: "Weather & place",
                    footer: "Adds the temperature — and the city, when you're somewhere new — to the dated line that starts each entry. Uses your approximate location only while Cobux is open. City-level only; your coordinates are never stored, and the line is yours to edit like any other text. Weather from  Apple Weather."
                ) {
                    Toggle("Weather & place in Journal", isOn: $ambientContextEnabled)
                        .onChange(of: ambientContextEnabled) { _, enabled in
                            guard enabled else { return }
                            // Same honesty as the Health toggle above: iOS asks
                            // once, and a toggle must never sit there claiming a
                            // permission that was declined.
                            AmbientContextService.shared.requestAuthorization()
                            Task {
                                try? await Task.sleep(for: .seconds(1))
                                if AmbientContextService.shared.authorizationDenied {
                                    ambientContextEnabled = false
                                } else {
                                    AmbientContextService.shared.refreshIfNeeded()
                                }
                            }
                        }
                }

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
                    Picker("Voice", selection: $selectedVoiceIdentifier) {
                        // Automatic is a real, selectable option rather than an invisible
                        // default, so "follow the best voice installed" stays reachable after
                        // a manual pick instead of being a one-way door.
                        Text("Automatic (best available)").tag("")
                        ForEach(availableVoices, id: \.identifier) { voice in
                            Text(voice.cobuxDisplayLabel).tag(voice.identifier)
                        }
                    }
                    .onChange(of: selectedVoiceIdentifier) { _, newValue in
                        VoicePreference.selectedVoiceIdentifier = newValue.isEmpty ? nil : newValue
                        // The nudge below is about the voice actually in use, so
                        // it has to follow a pick rather than wait for the next
                        // visit -- one enumeration on a deliberate change, not
                        // one per render.
                        usingDefaultQualityVoice = VoicePreference.usingDefaultQualityVoice
                    }
                    if usingDefaultQualityVoice {
                        Text(VoicePreference.upgradeRecipe)
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
                    CobuxSettingsRow(icon: "books.vertical.fill", label: "Books", value: "\(bookCount)")
                    CobuxSettingsRow(icon: "highlighter", label: "Highlights", value: "\(highlightCount)")
                    CobuxSettingsRow(icon: "list.number", label: "Chapters", value: "\(chapterCount)")

                    if let autoBackupManifest {
                        CobuxSettingsRow(icon: "icloud.fill", label: "Last Automatic Backup", value: autoBackupManifest.latestDate.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        CobuxSettingsRow(icon: "icloud.slash", label: "Last Automatic Backup", value: "Not yet")
                    }

                    Button("Export Backup") {
                        do {
                            // Fetched here rather than held in `@Query`s: an
                            // export is a one-shot action, and holding five
                            // tables for it kept the whole store on the main
                            // actor for as long as Settings was open. Every
                            // table the backup format carries is fetched --
                            // omitting Keeps and situations is what once made
                            // a manual backup silently drop them.
                            let chatMessages = try modelContext.fetch(FetchDescriptor<ChatMessage>())
                            let personalWritingEntries = try modelContext.fetch(FetchDescriptor<PersonalWritingEntry>())
                            let quizAttempts = try modelContext.fetch(FetchDescriptor<QuizAttempt>())
                            let keeps = (try? modelContext.fetch(FetchDescriptor<JournalKeep>())) ?? []
                            let situations = (try? modelContext.fetch(FetchDescriptor<SituationThread>())) ?? []
                            let data = try BackupService.exportData(books: allBooks(), chatMessages: chatMessages, personalWritingEntries: personalWritingEntries, quizAttempts: quizAttempts, journalKeeps: keeps, situations: situations)
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

                    CobuxSettingsRow(icon: "person.text.rectangle.fill", label: "Personal Writing Entries", value: "\(personalWritingCount)")

                    // A button, because the automatic sync is both invisible and
                    // unpushable: it runs only at launch and silently skips when the
                    // file's byte count is unchanged. "i want to sync earlier this
                    // morning journal, but it hasn't synced automatically and even it's
                    // not doing it automatically just now." There was genuinely no way
                    // to make it happen, and no way to see why it hadn't.
                    Button {
                        Task { await runJournalSync() }
                    } label: {
                        HStack {
                            Label("Sync Journal with iCloud", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if isSyncingJournal { ProgressView() }
                        }
                    }
                    .disabled(isSyncingJournal)
                    if let journalSyncMessage {
                        Text(journalSyncMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Require Face ID for Journal", isOn: $journalLockEnabled)
                    Text("Locks the Journal tab (More > Journal) behind Face ID. Nothing else in Cobux is affected — this is on by default since journal entries are the most personal thing stored here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Extended thinking in chat", isOn: $extendedThinking)
                    Text("Lets Claude reason at length before answering. It genuinely helps on hard questions — comparing several books, or Symposium Mode — but that reasoning is billed at the most expensive rate and you never see it, so this is off by default. Turn it on for a question worth the cost, then back off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // A custom binding, not `$personalWritingContextEnabled`:
                    // the two directions differ. Off writes at once and
                    // records the explicit choice; on only asks Face ID, and
                    // the stored value moves when -- and only when -- that
                    // succeeds. The Toggle reads the stored value back, so a
                    // cancelled prompt leaves it visibly off with nothing to
                    // revert by hand. Through `JournalUnlockCoordinator`, the
                    // one door every unlock in the app goes through.
                    Toggle("Use my personal writing in chat replies", isOn: Binding(
                        get: { personalWritingContextEnabled },
                        set: { wantsOn in
                            if wantsOn {
                                guard !isAuthenticatingPersonalWriting else { return }
                                isAuthenticatingPersonalWriting = true
                                Task {
                                    let unlocked = await JournalUnlockCoordinator.authenticate(JournalLockStatus.shared)
                                    if unlocked {
                                        personalWritingContextEnabled = true
                                        personalWritingContextExplicitlyOff = false
                                    }
                                    isAuthenticatingPersonalWriting = false
                                }
                            } else {
                                personalWritingContextEnabled = false
                                personalWritingContextExplicitlyOff = true
                            }
                        }
                    ))
                    .disabled(isAuthenticatingPersonalWriting)
                    Text("When on, relevant excerpts from your journal are sent to Claude alongside book highlights, so a reply can draw on your own writing where it genuinely fits — sometimes as a brief lived example woven into an answer.\n\nIt turns on the first time you unlock your journal with Face ID, and stays on until you turn it off — here, or from the line above the chat composer. Turning it back on asks Face ID again, so no one holding your unlocked phone can switch it on for you. Your journal itself stays locked regardless: the tab, an entry, and the journal thread all still ask.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if personalWritingContextEnabled {
                        Toggle("Use real names in life examples", isOn: $useRealNamesInLifeExamples)
                        Text("When on, replies can name the people you've written about. Turn it off and they're referred to only by role or relationship (\"a friend\", \"someone you wrote about\"), never by name.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Remember across conversations", isOn: $crossChatMemoryEnabled)
                    Text("When on, a chat can draw on things you've said in your other Cobux conversations, and it will always tell you which conversation and when. Only your own messages are used — never Cobux's replies — and your journal thread is never included. Anything in Quiet Words stays out of this too, unless you ask about it directly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
                    // No delete button, by his ruling: "cobux journals are
                    // supposed to be serious and part of life which will be
                    // there." Deleting did not disappear, it moved to where the
                    // writing came from -- remove a note in Apple Notes and the
                    // next sync mirrors that here. Entries written IN Cobux have
                    // no other home, so there is nothing to mirror and they stay.
                    // He may add a delete option in a later build; that is his
                    // call to make rather than one to pre-empt.
                    if let personalWritingImportMessage {
                        Text(personalWritingImportMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // No `Divider()` between the two imports. `CobuxFormSection`
                    // is a `Section` in a `Form`, so everything in this closure
                    // is a ROW: a Divider gets a full-height row of its own,
                    // with the Form's own separators drawn above and below it,
                    // and only a hairline inside -- which reads as an empty row
                    // that exists and renders nothing. "the space dher between
                    // the two improt options is that a bug or why?" It was: the
                    // Apple Journal import was added below the personal-writing
                    // one and reached for a Divider to separate them, the way
                    // you would inside a VStack. A Form already draws a
                    // separator between adjacent rows, so the separation it was
                    // asking for was there before the Divider was.
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
                // The permanent, findable home for "how do I write into this
                // thing" -- his instinct was an info section, and a list of
                // capture paths is what that instinct was actually pointing at.
                // Most of these are invisible until something says they exist.
                //
                // THREE sections, not one, and the split is by what the thing
                // actually DOES -- because a single "Ways to Write" list was
                // making claims its own rows did not support, twice over. Every
                // line below was checked against the code that runs it:
                //
                //   writes a `PersonalWritingEntry` (the journal)
                //     - `CobuxWidgets/JournalWidget.swift` (home + accessory)
                //     - `Cobux/Intents/JournalEntryIntent.swift:61`
                //     - `CobuxMessages/MessagesJournalView.swift:151`
                //   writes a `Highlight` (the library -- NOT the journal)
                //     - `CobuxShareExtension/ShareQuoteView.swift:97`
                //     - `Cobux/Intents/CaptureQuoteIntent.swift`, whose own
                //       description reads "Save a quote to a book in your
                //       Cobux library"
                //   writes nothing at all
                //     - `AskCobuxIntent`, `RandomHighlightIntent`
                //     - `CobuxWatch/CobuxWatchContentView.swift:4`: "only
                //       (streak, due count, a featured quote), never a second
                //       place to browse/review/chat"
                //
                // So the share sheet had been sitting under "Every way into
                // your journal, in one place" while writing to the library --
                // the same defect as "Add Journal to Contacts" one section
                // down, found in the same sweep. A row can be scrupulously
                // honest and still be made to lie by the header above it.
                //
                // Grouped by capability rather than by invocation channel on
                // purpose: five of these are Siri, and nesting phrases under a
                // single "Siri" parent would put a second level of hierarchy
                // inside a caption-scale block, which is precisely what falls
                // apart at large Dynamic Type. Three short blocks read calmer
                // there than one nine-line wall, and each header stands alone.
                CobuxFormSection(
                    title: "Ways to Write",
                    footer: "Every way into your journal from outside the app. The Journal tab itself is always there too."
                ) {
                    // These sections are information and nothing else, which is
                    // what they were always pretending not to be. Statements of
                    // fact and one real control ("Add Journal to Contacts",
                    // since moved to its own section) shared one row shape, one
                    // violet icon treatment and one separator stack, so the only
                    // thing saying "this one does nothing" was the label's
                    // colour -- and the violet icon argued the other way. "the
                    // ways here which is an information for user but is kinda
                    // used the same ui as off clickable buttons that shuldnt be
                    // it differnet cateofries shuold be dsitingaushable right
                    // ??" Yes.
                    //
                    // So each group is ONE row of explanatory lines in this
                    // screen's own explanatory voice -- caption, secondary: the
                    // same treatment every Toggle's paragraph above uses, and
                    // the same `CobuxFormSection` gives its footer. One row
                    // means no separators implying a tappable stack, and a
                    // secondary icon stops the accent colour from claiming an
                    // affordance that isn't there.
                    VStack(alignment: .leading, spacing: CobuxSpacing.sm) {
                        capabilityLine("Journal widget — home screen and lock screen",
                                       icon: "square.and.pencil")
                        capabilityLine("Siri — \"Journal in Cobux\"", icon: "mic.fill")
                        capabilityLine("iMessage — tap + in any conversation, choose Cobux",
                                       icon: "message.fill")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // The share sheet's own string never claimed the journal --
                // "send selected text to Cobux" is exactly what it does. It
                // only needed a header that agrees with it.
                CobuxFormSection(
                    title: "Ways to Save a Quote",
                    footer: "Both file the quote to a book in your library, not to your journal."
                ) {
                    VStack(alignment: .leading, spacing: CobuxSpacing.sm) {
                        capabilityLine("Share sheet — send selected text to Cobux",
                                       icon: "square.and.arrow.up")
                        capabilityLine("Siri — \"Save a quote to Cobux\"", icon: "mic.fill")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // The Apple Watch app is a whole bundled target that had no
                // entry point anywhere in the app -- nothing told anyone it
                // existed. It is read-only by its own ruling, so it belongs
                // beside the two Siri phrases that also only ever hand
                // something back.
                CobuxFormSection(
                    title: "Ways to Ask and Glance",
                    footer: "Nothing here writes anything — they answer, show, or carry a line for you."
                ) {
                    VStack(alignment: .leading, spacing: CobuxSpacing.sm) {
                        capabilityLine("Siri — \"Ask Cobux a question\"", icon: "mic.fill")
                        capabilityLine("Siri — \"Give me a highlight from Cobux\"",
                                       icon: "mic.fill")
                        capabilityLine("Apple Watch — streak, what's due, and one line to carry",
                                       icon: "applewatch")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

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

                // Deliberately NOT a fifth row of "Ways to Write", and
                // deliberately far from it. `CobuxContactService`'s own doc
                // settles it: "The message ingestion is a script on Rajan's
                // Mac, not part of this app. A contact created for someone
                // without that pipeline would look like a feature and do
                // nothing." So for anyone but Rajan this is not a way into the
                // journal at all -- and the string never said it was. The
                // SECTION said it: a header reading "Ways to Write" over a
                // footer reading "Every way into your journal, in one place"
                // makes the promise the copy carefully avoids, which is worse
                // than a wrong string because nothing in the string is wrong.
                //
                // It stays on the screen because the contact is real and Rajan
                // uses it, but it stands on its own words now: a Messages
                // convenience, in the utilities tail beside About, with a
                // footer that says what it does AND what it does not do. The
                // four ways in stay where they are, all four true for everyone
                // -- which is exactly why a fifth thing standing among them
                // that is true for one person was the problem.
                CobuxFormSection(
                    title: "Messages Contact",
                    footer: "Creates one contact called Journal 📓 pointing at your own iMessage address, so a chat with yourself reads as what you use it for. That is all it does — Cobux never reads a Messages conversation. To write an entry from Messages, open the Cobux pane from the + button."
                ) {
                    // Naming a chat with yourself "Cobux" is the closest the
                    // platform allows to texting the app: a Messages extension
                    // is a pane you open, and no app can be a real iMessage
                    // contact. This only creates the contact -- it makes no
                    // claim about journaling, because on iOS nothing here reads
                    // Messages.
                    Button {
                        showingAddContact = true
                    } label: {
                        Label("Add Journal to Contacts", systemImage: "person.crop.circle.badge.plus")
                    }
                    if let contactMessage {
                        Text(contactMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                CobuxFormSection(
                    title: "About",
                    footer: "TestFlight builds always expire 90 days after upload — an Apple platform rule, not something this app controls. A new build resets this whenever one ships, which happens often during active development."
                ) {
                    CobuxSettingsRow(icon: "info.circle.fill", label: "Version", value: Self.appVersion)
                    CobuxSettingsRow(icon: "person.fill", label: "Developer", value: "Rajan Sharma")
                    // The advice notice (ledger N20). Here, beside the version,
                    // and nowhere in chat -- Rajan: "I don't want the chat to
                    // be changed or mention this tho but make sure". A
                    // `CobuxSettingsRow` as the label, not a bare `Label`, so
                    // the row sits in this section's own grammar.
                    NavigationLink {
                        CobuxNoticeView()
                    } label: {
                        CobuxSettingsRow(icon: "text.quote", label: "A note on advice")
                    }
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
            .task {
                // Computed when the screen opens, never on a timer -- nothing
                // here needs to be current to the second. Yield first so the
                // screen's own push animation commits before the two
                // whole-table walks run; the sigil fades in when ready.
                await Task.yield()
                await Task.yield()
                refreshCounts()
                // Both voice reads, together, once -- see `availableVoices`.
                // After the yields, so the enumeration lands behind the first
                // frame rather than in front of it; the Picker shows
                // "Automatic" until it does, which is the correct selection for
                // anyone who has not picked a voice.
                availableVoices = VoicePreference.availableVoices()
                usingDefaultQualityVoice = VoicePreference.usingDefaultQualityVoice
                deltaSnapshot = DeltaLedger.snapshot(context: modelContext)
            }
            // An import or restore from this very screen changes the counts;
            // follow the store the way the old `@Query`s did, without holding
            // the tables to do it.
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
                        .receive(on: DispatchQueue.main)) { _ in
                // Not during a seed, which saves in small batches hundreds of
                // times; the counts are re-read when the screen next opens.
                guard !SeedingStatus.shared.isSeeding else { return }
                refreshCounts()
            }
            .alert("Your name", isPresented: $showingNamePrompt) {
                TextField("What should Cobux call this?", text: $nameDraft)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    displayName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } message: {
                Text("Only used to name this section. It stays on your device.")
            }
            .alert("Quiet a word", isPresented: $showingQuietWordPrompt) {
                TextField("A name, or any word", text: $newQuietWord)
                Button("Cancel", role: .cancel) { }
                Button("Quiet it") {
                    JournalQuietWords.add(newQuietWord)
                    quietWords = JournalQuietWords.all()
                }
            } message: {
                Text("Entries containing it will stop appearing on their own. Nothing is deleted.")
            }
            .alert("Add Journal to Contacts", isPresented: $showingAddContact) {
                TextField("Your number or Apple ID", text: $contactAddress)
                    .textInputAutocapitalization(.never)
                Button("Add") { Task { await addCobuxContact() } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("iOS never tells an app your own number, so Cobux needs the one you use for iMessage. It creates a single contact called Journal 📓 — a chat with yourself, named for what you use it for — and never reads your address book.")
            }

            // `.task`, not `.onAppear`. `savedReports()` enumerates a directory
            // and parses every filename in it -- file IO, and `.onAppear` runs
            // it BEFORE the first frame commits. The Crash Reports section only
            // exists at all when something has already gone wrong, so it is the
            // last thing on this screen that should hold up its opening.
            .task {
                await Task.yield()
                crashReports = CrashReportCollector.savedReports()
            }
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
    }

    // Turning the toggle off only stops future chat turns from using this
    // content -- it doesn't remove anything already imported, so a real,
    // permanent delete matters here given how personal this content can be
    /// Pushes this device's entries out, then pulls anything new in, ignoring
    /// both gates the automatic path uses. Newest entries import first and
    /// embeddings are deferred to the background backfill, so today's journal is
    /// readable in seconds rather than after several hundred model calls.
    @MainActor

    private func addCobuxContact() async {
        switch await CobuxContactService.addContact(address: contactAddress) {
        case .added:
            contactMessage = "Added. Start a Messages chat with Journal 📓 — it's a chat with yourself, named for what it is."
        case .alreadyExists:
            contactMessage = "You already have a Journal contact."
        case .permissionDenied:
            contactMessage = "Contacts access is off. Turn it on in Settings to add it."
        case .failed(let reason):
            contactMessage = "Couldn't add it: \(reason)"
        }
        contactAddress = ""
    }

    /// One line in the three capability sections: information, never a control.
    ///
    /// `Label`, not an `HStack`, precisely for the accessibility half of the
    /// split -- a `Label` is a single static-text element whose accessibility
    /// label is its title, with the symbol decorative, so VoiceOver reads a
    /// fact and never announces a button. "Add Journal to Contacts" stays a
    /// `Button` wrapping a `Label`, so it announces as one, with its own label.
    ///
    /// Every Siri line uses `mic.fill`, the symbol the original Siri row
    /// already carried, rather than mixing in a second waveform glyph: eight
    /// lines split across three sections only read as one system if the same
    /// capability wears the same mark in all of them.
    ///
    /// The icon frame is explicit because a `Form` only aligns `Label` icons
    /// across separate ROWS, and the lines in each section share one row --
    /// without it `mic.fill` and `square.and.arrow.up` set their text at
    /// different margins.
    private func capabilityLine(_ text: String, icon: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon)
                .frame(width: 18)
        }
        .font(CobuxTypography.cobuxCaption)
        .foregroundStyle(.secondary)
    }

    private func runJournalSync() async {
        isSyncingJournal = true
        journalSyncMessage = nil
        defer { isSyncingJournal = false }

        await JournalAutoExportService.export(modelContext: modelContext, force: true)
        switch await PersonalWritingAutoImportService.syncNow(modelContext: modelContext) {
        case .imported(let count):
            journalSyncMessage = "Synced. \(count) new \(count == 1 ? "entry" : "entries") added."
        case .alreadyUpToDate:
            journalSyncMessage = "Already up to date. Your entries here were uploaded."
        case .noFileInICloud:
            journalSyncMessage = "Nothing in iCloud to import yet. Your entries here were just uploaded."
        case .waitingForICloudDownload:
            journalSyncMessage = "iCloud is still downloading. Try again in a moment."
        case .failed:
            journalSyncMessage = "Sync didn't finish. Check iCloud is signed in, then try again."
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
        // Public contact address, not the private one. This file is mirrored to
        // the PUBLIC cobux-oss repo, where the private address was sitting in
        // plain sight and scrapeable. 9218 is already published on his resume,
        // LinkedIn and GitHub profile, so it is the correct address for anything
        // a stranger's app can send.
        let recipient = "rajansharma9218@gmail.com"

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

    /// Four `fetchCount`s -- the Data section's numbers without the rows. Each
    /// is one SQL `COUNT`: exact, and nothing is registered in the context.
    private func refreshCounts() {
        bookCount = (try? modelContext.fetchCount(FetchDescriptor<Book>())) ?? 0
        highlightCount = (try? modelContext.fetchCount(FetchDescriptor<Highlight>())) ?? 0
        chapterCount = (try? modelContext.fetchCount(FetchDescriptor<Chapter>())) ?? 0
        personalWritingCount = (try? modelContext.fetchCount(FetchDescriptor<PersonalWritingEntry>())) ?? 0
    }

    /// Every book, for the three taps that need the rows rather than the count.
    /// Fetched at the tap, exactly as the chat messages, personal-writing
    /// entries, quiz attempts, Keeps and situation threads beside it already
    /// are -- so nothing holds the table open while Settings is merely on
    /// screen. `BackupService` reads each book's `chapters`/`highlights`
    /// relationships from these, which is why every caller is already gated on
    /// `SeedingStatus.shared.isSeeding`.
    private func allBooks() -> [Book] {
        (try? modelContext.fetch(FetchDescriptor<Book>())) ?? []
    }

    /// Names every counted category on `BackupService.ImportResult`, once, for
    /// both import call sites in this file. They each used to carry their own
    /// hand-maintained list AND a separate hand-maintained "is this empty"
    /// boolean, and both drifted the moment the result struct grew a field:
    /// `journalKeepsImported`, `situationsImported` and `booksMerged` were
    /// counted by the import and named by neither, so a manual import whose
    /// entire recovered value was held passages, situation threads, or notes
    /// folded into books that already existed reported "Nothing new to
    /// import" -- the same understating-the-restore bug
    /// `AutoRestoreService.summaryText` was fixed for, on the two screens the
    /// user explicitly asked for the import from. Emptiness is now derived
    /// from this one list rather than asserted next to it, so a future field
    /// can only ever go unnamed, never silently turn a real import into
    /// "nothing happened".
    ///
    /// `booksMerged` is the one that matters most in practice: after any
    /// reseed the local store already holds every seed book by title, so a
    /// restore's recovered chapters/highlights/notes land as merges and
    /// `booksImported` stays 0 (see `ImportResult.booksMerged`'s own comment).
    /// It counts only books something actually landed in -- a title match on
    /// its own used to be enough, which pinned this list permanently non-empty
    /// on any seeded phone and so made the emptiness case below dead code that
    /// reported a restore for an import that restored nothing.
    private func importedParts(for result: BackupService.ImportResult) -> [String] {
        var parts: [String] = []
        if result.booksImported > 0 { parts.append("\(result.booksImported) book(s)") }
        if result.chatMessagesImported > 0 { parts.append("\(result.chatMessagesImported) chat message(s)") }
        if result.highlightMemoriesImported > 0 { parts.append("\(result.highlightMemoriesImported) review record(s)") }
        if result.quizQuestionsImported > 0 { parts.append("\(result.quizQuestionsImported) quiz question(s)") }
        if result.personalWritingEntriesImported > 0 {
            let noun = result.personalWritingEntriesImported == 1 ? "entry" : "entries"
            parts.append("\(result.personalWritingEntriesImported) personal writing \(noun)")
        }
        if result.situationsImported > 0 { parts.append("\(result.situationsImported) situation thread(s)") }
        if result.quizAttemptsImported > 0 { parts.append("\(result.quizAttemptsImported) quiz attempt(s)") }
        if result.journalKeepsImported > 0 { parts.append("\(result.journalKeepsImported) held passage(s)") }
        if result.booksMerged > 0 { parts.append("saved progress on \(result.booksMerged) existing book(s)") }
        return parts
    }

    private func importBackup(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            backupMessage = "Couldn't access that file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            let chatMessages = try modelContext.fetch(FetchDescriptor<ChatMessage>())
            let personalWritingEntries = try modelContext.fetch(FetchDescriptor<PersonalWritingEntry>())
            // Fetched and passed for the same reason `AutoRestoreService` now
            // passes chat messages and personal-writing entries: `importData`
            // dedupes attempts ONLY against the rows it is handed, so omitting
            // this made re-importing the same file structurally incapable of
            // recognising an attempt it had already imported and it re-inserted
            // the whole quiz history every time. Dedup is on (book, scope,
            // startedAt), so nothing genuinely new is ever dropped by adding it.
            let quizAttempts = try modelContext.fetch(FetchDescriptor<QuizAttempt>())
            let result = try BackupService.importData(data, existingBooks: allBooks(), existingChatMessages: chatMessages, existingPersonalWritingEntries: personalWritingEntries, existingQuizAttempts: quizAttempts, modelContext: modelContext)
            let parts = importedParts(for: result)
            if parts.isEmpty {
                backupMessage = "Nothing new to import — everything in that backup already exists here."
            } else {
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
            let chatMessages = try modelContext.fetch(FetchDescriptor<ChatMessage>())
            let personalWritingEntries = try modelContext.fetch(FetchDescriptor<PersonalWritingEntry>())
            let quizAttempts = try modelContext.fetch(FetchDescriptor<QuizAttempt>())
            let result = try BackupService.importData(data, existingBooks: allBooks(), existingChatMessages: chatMessages, existingPersonalWritingEntries: personalWritingEntries, existingQuizAttempts: quizAttempts, modelContext: modelContext)
            // Same one list as `importBackup` -- this call site had the identical
            // drift (no `journalKeepsImported`, `situationsImported` or
            // `booksMerged`), and on the iCloud path `booksMerged` is the normal
            // case, so a real restore onto a seeded store could report "nothing
            // new" while having just recovered every note in the library.
            let parts = importedParts(for: result)
            if parts.isEmpty {
                backupMessage = "Nothing new to restore -- everything in that backup already exists here."
            } else {
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

    /// `static let`, not a computed property, for `DiagnosticsView.appVersion`'s
    /// reason: `Bundle.main.infoDictionary` is fixed for the life of the
    /// process, and this was a dictionary lookup on every body evaluation of a
    /// screen whose body re-runs on every toggle it holds.
    private static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"

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
