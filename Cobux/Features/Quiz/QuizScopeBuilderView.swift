import SwiftUI
import SwiftData
import CobuxCore

private enum QuizScopeKind: Hashable {
    case chapter(Chapter)
    case topic
    case wholeBook
    case reviewQueue
}

struct QuizScopeBuilderView: View {
    let book: Book
    @Bindable var claudeService: ClaudeService
    @Environment(\.modelContext) private var modelContext
    /// For the "Open Settings" action on the API-key alert (`cobux://settings`).
    @Environment(\.openURL) private var openURL

    @State private var scope: QuizScopeKind = .wholeBook
    @State private var onlyIncompleteChapters = true
    @State private var selectedTags: Set<String> = []
    @State private var mode: QuizMode
    @State private var mixInDueReviews = false
    @State private var questionCount = 10

    @State private var isPreparing = false
    @State private var prepError: String?
    @State private var showCostConfirm = false
    @State private var pendingChaptersToGenerate: [Chapter] = []
    /// The price quoted for `pendingChaptersToGenerate`, captured with it.
    /// See the confirmation alert's message for why this is state rather than
    /// a computed property.
    @State private var pendingEstimatedCost: Double = 0
    @State private var failedChapters: [Chapter] = []
    @State private var sessionNavigation: AttemptNavigationWrapper?
    @State private var showNoAPIKeyAlert = false

    @State private var batchProgress: BatchGenerationService.Progress?
    @State private var batchStatusMessage: String?
    @State private var batchDidApplyResults = false
    /// `BatchGenerationService.submit` only persists its "in progress" marker
    /// AFTER the network call to Anthropic's Batch API returns -- its own
    /// `guard pendingBatch == nil` at the top reads that same marker, so two
    /// overlapping calls (a double-tap on the button below, fired before
    /// either call's `await` returns) both pass the guard and both actually
    /// submit the batch, paying for the same chapters twice. This is a
    /// local, synchronous-on-tap guard around that gap -- flips true the
    /// instant the button is tapped, well before the service's own check
    /// would even run.
    @State private var isSubmittingBatch = false
    /// Same class of gap as `isSubmittingBatch` above, one level down:
    /// `BatchGenerationService.applyResultsIfDone` reads `pendingBatch` from
    /// UserDefaults, does a real network round trip (`batchStatus`, then
    /// `batchResults`), and only clears that pending record in a `defer` at
    /// the very end -- so two overlapping "Check Status" taps (an impatient
    /// double-tap while waiting on a slow batch, or a normal tap landing
    /// mid-flight from a previous one) both see the same pending batch,
    /// both fetch and apply the same results, and each `applyGeneratedQuestions`
    /// call deletes-then-reinserts that chapter's questions -- doubling the
    /// "Applied N questions" count at best, and at worst discarding real FSRS
    /// review history on any question answered between the two applications.
    /// Guarded here the same synchronous-on-tap way, not inside the service.
    @State private var isCheckingStatus = false
    /// `BatchGenerationService.cancel` has the identical read-then-await-then-
    /// clear shape -- a double-tap on "Cancel" fires the cancel API call twice
    /// for the same batch, which is wasted work and flickers `batchStatusMessage`
    /// even if Anthropic's side tolerates the redundant call.
    @State private var isCancelingBatch = false

    init(book: Book, claudeService: ClaudeService) {
        self.book = book
        self.claudeService = claudeService
        _mode = State(initialValue: book.contentProfile.isExamStyleQuiz ? .examSimulation : .practice)
    }

    private var isExamStyleBook: Bool { book.contentProfile.isExamStyleQuiz }

    private var chapterCandidates: [Chapter] {
        let sorted = book.chapters.sorted { ($0.chapterNumber ?? 0) < ($1.chapterNumber ?? 0) }
        return onlyIncompleteChapters ? sorted.filter { !$0.isCompleted } : sorted
    }

    private var allTags: [String] {
        Array(Set(book.highlights.flatMap(\.tags))).sorted()
    }

    /// FSRS-based, not the legacy per-highlight `HighlightMemory` -- must match
    /// `DailyReviewService.dueQuestions`'s exact filter, or this screen and
    /// Daily Review show two different due counts for the same book.
    /// COUNTS, without building the pool.
    ///
    /// This was `dueQuestions().count`: a `flatMap` allocating an array of
    /// every question in the book, then a `filter` allocating a second array,
    /// to produce one integer -- and `body` asked for that integer five
    /// separate times (the scope picker's condition, its label, the review-queue
    /// explainer, the mix-in toggle's condition, and `scopeHasAnyContent`). Two
    /// whole-book arrays, five times over, every time anything on this screen
    /// changed. `dueQuestions()` itself is still there, unchanged, for the one
    /// caller that genuinely needs the questions (`buildPool`).
    ///
    /// The predicate is duplicated from `dueQuestions()` rather than shared,
    /// and that has to stay deliberate: it must match
    /// `DailyReviewService.dueQuestions`'s filter exactly or this screen and
    /// Daily Review disagree about the same book. Both copies are right here,
    /// adjacent, so they cannot drift unnoticed.
    private var dueReviewCount: Int {
        let now = Date.now
        var count = 0
        for chapter in book.chapters {
            for question in chapter.quizQuestions
            where !question.isSuspended && (question.dueDate.map { $0 <= now } ?? false) {
                count += 1
            }
        }
        return count
    }

    private func dueQuestions() -> [QuizQuestion] {
        book.chapters.flatMap(\.quizQuestions).filter { !$0.isSuspended && ($0.dueDate.map { $0 <= .now } ?? false) }
    }

    // MARK: - Exam Countdown

    /// Same treatment as `dueReviewCount`, and read twice per body from the
    /// exam-countdown section alone.
    private var notIntroducedCount: Int {
        var count = 0
        for chapter in book.chapters {
            for question in chapter.quizQuestions
            where question.dueDate == nil && !question.isSuspended {
                count += 1
            }
        }
        return count
    }

    private var examDateBinding: Binding<Date> {
        Binding(
            get: { book.examDate ?? Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now },
            set: { book.examDate = $0 }
        )
    }

    @ViewBuilder
    private var examCountdownSection: some View {
        Section {
            Toggle("Exam Countdown", isOn: Binding(
                get: { book.examDate != nil },
                set: { enabled in book.examDate = enabled ? (book.examDate ?? Calendar.current.date(byAdding: .day, value: 14, to: .now)) : nil }
            ))

            if let examDate = book.examDate {
                DatePicker("Exam date", selection: examDateBinding, in: Date.now..., displayedComponents: .date)

                let daysLeft = ExamCountdown.daysLeft(from: .now, to: examDate)
                let requiredPace = ExamCountdown.requiredNewPerDay(notIntroduced: notIntroducedCount, daysLeft: daysLeft)
                let retention = ExamCountdown.desiredRetention(daysLeft: daysLeft)

                VStack(alignment: .leading, spacing: 6) {
                    Text("\(daysLeft) day\(daysLeft == 1 ? "" : "s") left · \(notIntroducedCount) not yet introduced")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    if requiredPace > 0 {
                        Text("Study \(requiredPace) new card\(requiredPace == 1 ? "" : "s")/day to cover everything before the exam.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Everything's already been introduced at least once.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Review target: \(Int(retention * 100))% retention · nothing scheduled past exam day.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Exam Countdown")
        } footer: {
            Text("Set an exam date and reviews automatically compress as it approaches — nothing is ever scheduled past it.")
        }
    }

    /// Chapters this scope actually needs, so we know what (if anything)
    /// still needs a paid generation call before a quiz can start.
    private var chaptersInScope: [Chapter] {
        switch scope {
        case .chapter(let chapter):
            return [chapter]
        case .wholeBook:
            return chapterCandidates
        case .topic:
            guard !selectedTags.isEmpty else { return [] }
            return chapterCandidates.filter { chapter in
                !book.highlights(in: chapter).filter { !Set($0.tags).isDisjoint(with: selectedTags) }.isEmpty
            }
        case .reviewQueue:
            return []
        }
    }

    /// Buckets the book's highlights once, then asks per chapter -- instead of
    /// `needsGeneration` re-filtering every highlight in the book twice for
    /// each chapter in scope. Same answer, one pass.
    private var chaptersNeedingGeneration: [Chapter] {
        let scoped = chaptersInScope
        guard !scoped.isEmpty else { return [] }
        let highlightsByChapter = QuizGenerationService.highlightsByChapterID(in: book)
        return scoped.filter {
            QuizGenerationService.needsGeneration(
                chapter: $0,
                highlights: highlightsByChapter[$0.persistentModelID] ?? [])
        }
    }

    /// Takes the list rather than recomputing it. `totalEstimatedCost` used to
    /// be a computed property that called `chaptersNeedingGeneration` again,
    /// so every place that showed a price silently paid for a second full
    /// generation-need scan beside the one that decided to show it.
    private func estimatedCost(for chapters: [Chapter]) -> Double {
        chapters.reduce(0) { $0 + QuizGenerationService.estimatedCost(for: $1, in: book) }
    }

    var body: some View {
        Group {
            if SeedingStatus.shared.isSeeding {
                // Same seed-merge guard as `BookCard`/`BookDetailView`/`QuizHomeView` --
                // every computed property below (`chapterCandidates`, `allTags`,
                // `dueQuestions()`, `notIntroducedCount`) faults this book's
                // `chapters`/`highlights` (and each chapter's `quizQuestions`)
                // relationships synchronously in `body`. Landing that fault mid
                // seed/upgrade merge is the confirmed Build-5 crash class. This
                // screen is normally only reachable through `QuizHomeView`'s own
                // gated book list, but that's a fragile guarantee to lean on from
                // here -- a direct, local guard costs nothing and can't be
                // silently invalidated by a future new entry point.
                ProgressView("Syncing your library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                scopeForm
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Generate Questions?", isPresented: $showCostConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Generate & Start") {
                Task { await generateThenStart() }
            }
        } message: {
            // Both numbers come from state captured when the confirmation was
            // RAISED, not recomputed here. An `.alert` message closure is
            // rebuilt on every body pass whether or not the alert is showing,
            // so the old `totalEstimatedCost` here ran a full
            // generation-need scan of the book behind an invisible alert every
            // time anything on this screen changed. It is also more correct:
            // the price he is agreeing to is now literally the price that was
            // quoted, from the same instant as the chapter count beside it.
            Text("Uses your Anthropic API key to write quiz questions for \(pendingChaptersToGenerate.count) chapter(s) — about $\(String(format: "%.2f", pendingEstimatedCost)), a one-time cost. Cached afterward, so re-quizzing this scope is free unless the chapter's highlights change.")
        }
        .alert("API Key Required", isPresented: $showNoAPIKeyAlert) {
            // A route, not a direction. "In Settings" named a screen three
            // taps away that shares its name with iOS Settings; this opens it.
            Button("Open Settings") {
                if let url = URL(string: "cobux://settings") { openURL(url) }
            }
            Button("Not Now", role: .cancel) { }
        } message: {
            Text("Writing quiz questions runs on Claude with your own Anthropic API key. Add it under More → Settings.")
        }
        .navigationDestination(item: $sessionNavigation) { wrapper in
            // Clearing the item unwinds the whole Session -> Results stack in
            // one step (both are pushed as descendants of this destination) --
            // the fix for Results being a dead end with no way back except
            // switching tabs.
            QuizSessionView(attempt: wrapper.attempt, questions: wrapper.questions, onDone: { sessionNavigation = nil })
        }
        .sensoryFeedback(.success, trigger: batchDidApplyResults)
    }

    private var scopeForm: some View {
        // THE PER-BODY HOIST. Each of these used to be a computed property
        // re-evaluated at every reference below: `dueReviewCount` three times
        // inside this Form plus once more through `scopeHasAnyContent`, and
        // `chaptersNeedingGeneration` once for the button's label plus a second
        // time through `totalEstimatedCost` beside it plus twice more inside
        // `backgroundGenerationSection`. Every one of those was a full walk of
        // the book's chapters and questions, or of its highlights. They are
        // read once here and passed down.
        let dueCount = dueReviewCount
        let needingGeneration = chaptersNeedingGeneration
        return Form {
            CobuxFormSection(title: "What to quiz") {
                Picker("Scope", selection: Binding(
                    get: { scopeSelectionTag },
                    set: { setScope(tag: $0) }
                )) {
                    Text("By Chapter").tag("chapter")
                    Text("By Topic").tag("topic")
                    Text("Whole Book").tag("wholeBook")
                    if dueCount > 0 {
                        Text("Review Queue (\(dueCount) due)").tag("reviewQueue")
                    }
                }
                .pickerStyle(.menu)

                switch scope {
                case .chapter:
                    Toggle("Only chapters I haven't completed", isOn: $onlyIncompleteChapters)
                    Picker("Chapter", selection: chapterPickerBinding) {
                        ForEach(chapterCandidates, id: \.self) { chapter in
                            Text(chapter.title).tag(chapter as Chapter?)
                        }
                    }
                case .topic:
                    Toggle("Only chapters I haven't completed", isOn: $onlyIncompleteChapters)
                    topicChips
                case .wholeBook:
                    Toggle("Only chapters I haven't completed", isOn: $onlyIncompleteChapters)
                case .reviewQueue:
                    Text("Pulls only your \(dueCount) already-cached questions due for review right now — no generation needed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            CobuxFormSection(title: "How to quiz") {
                Picker("Mode", selection: $mode) {
                    Text("Practice").tag(QuizMode.practice)
                    Text("Exam Simulation").tag(QuizMode.examSimulation)
                }
                .pickerStyle(.segmented)

                if dueCount > 0, scope != .reviewQueue {
                    Toggle("Mix in due reviews", isOn: $mixInDueReviews)
                }

                Stepper("Up to \(questionCount) questions", value: $questionCount, in: 3...30, step: 1)
            }

            backgroundGenerationSection(needingGeneration: needingGeneration)

            examCountdownSection

            if let prepError {
                Section {
                    Text(prepError)
                        .foregroundStyle(Color.cobuxDanger)
                        .font(.footnote)
                    if !failedChapters.isEmpty {
                        Button("Retry Failed Chapters") {
                            retryFailedChapters()
                        }
                        .disabled(isPreparing)
                    }
                }
            }

            Section {
                Button {
                    beginPreparation()
                } label: {
                    if isPreparing {
                        HStack {
                            ProgressView()
                            Text("Preparing…")
                        }
                    } else if !needingGeneration.isEmpty {
                        Text("Generate & Start (~$\(String(format: "%.2f", estimatedCost(for: needingGeneration))), one-time)")
                    } else {
                        Text("Start Quiz")
                    }
                }
                .disabled(isPreparing || !scopeHasAnyContent(dueCount: dueCount))
            }
        }
    }

    // MARK: - Scope selection plumbing

    private var scopeSelectionTag: String {
        switch scope {
        case .chapter: return "chapter"
        case .topic: return "topic"
        case .wholeBook: return "wholeBook"
        case .reviewQueue: return "reviewQueue"
        }
    }

    private func setScope(tag: String) {
        switch tag {
        case "chapter": scope = .chapter(chapterCandidates.first ?? book.chapters.first ?? Chapter(title: "", summary: ""))
        case "topic": scope = .topic
        case "reviewQueue": scope = .reviewQueue
        default: scope = .wholeBook
        }
    }

    private var chapterPickerBinding: Binding<Chapter?> {
        Binding(
            get: {
                if case .chapter(let c) = scope { return c }
                return nil
            },
            set: { newValue in
                if let newValue { scope = .chapter(newValue) }
            }
        )
    }

    @ViewBuilder
    private var topicChips: some View {
        if allTags.isEmpty {
            // A blank horizontal strip reads as a control that's broken rather
            // than one with nothing in it yet. Topics come from the highlights
            // themselves, so say so instead of showing empty space.
            Text("No topics in this book yet — the tags you put on a highlight are what show up here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(allTags, id: \.self) { tag in
                        let isSelected = selectedTags.contains(tag)
                        Button {
                            if isSelected { selectedTags.remove(tag) } else { selectedTags.insert(tag) }
                        } label: {
                            // Quiet chips, selected or not -- the same
                            // one-saturation correction as `QuizSessionView`'s
                            // confidence row. A strip of topic chips is a
                            // multi-select, so ANY number of them can be on at
                            // once; filling each one solid meant a screen that
                            // could carry six saturated capsules and a filled
                            // Start button, all at full strength on near-black.
                            Text(tag)
                                .foregroundStyle(isSelected ? Color.cobuxAccent : Color.secondary)
                                .cobuxQuietChip(tint: isSelected ? Color.cobuxAccent : Color.secondary)
                                .overlay {
                                    Capsule().stroke(isSelected ? Color.cobuxAccent.opacity(0.55) : .clear,
                                                     lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Takes the count its caller already computed, rather than recomputing it.
    private func scopeHasAnyContent(dueCount: Int) -> Bool {
        switch scope {
        case .reviewQueue: return dueCount > 0
        case .topic: return !selectedTags.isEmpty && !chaptersInScope.isEmpty
        default: return !chaptersInScope.isEmpty
        }
    }

    // MARK: - Background (Batch API) generation

    /// Offered as an alternative to the synchronous "Generate & Start" flow
    /// above when there's enough in scope to make the ~50% Batch API
    /// discount worth the turnaround -- one chapter needing generation
    /// isn't worth waiting on a background job for, but a whole
    /// under-covered book is. Only one batch runs at a time app-wide, so
    /// this also surfaces (and lets you check on / cancel) a batch already
    /// in flight, even one started for a different book.
    /// `needingGeneration` is passed in, not recomputed: this section read
    /// `chaptersNeedingGeneration` twice, and the caller had already computed
    /// the identical list for the Start button below.
    @ViewBuilder
    private func backgroundGenerationSection(needingGeneration: [Chapter]) -> some View {
        if let pending = BatchGenerationService.pendingBatch {
            Section {
                HStack {
                    Text("Chapters submitted")
                    Spacer()
                    Text("\(pending.chapterIDs.count)").foregroundStyle(.secondary)
                }
                if pending.bookTitle != book.title {
                    Text("Running for \"\(pending.bookTitle)\" — only one background batch can run at a time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let batchProgress {
                    Text("\(batchProgress.succeeded) done, \(batchProgress.processing) still processing, \(batchProgress.errored) errored")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    isCheckingStatus = true
                    Task { await checkBatchStatus() }
                } label: {
                    if isCheckingStatus {
                        HStack {
                            ProgressView()
                            Text("Checking…")
                        }
                    } else {
                        Text("Check Status")
                    }
                }
                .disabled(isCheckingStatus || isCancelingBatch)
                Button("Cancel Background Generation", role: .destructive) {
                    isCancelingBatch = true
                    Task { await cancelBatchGeneration() }
                }
                .disabled(isCheckingStatus || isCancelingBatch)
                if let batchStatusMessage {
                    Text(batchStatusMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Background Generation")
            } footer: {
                Text("Submitted via Anthropic's Batch API at roughly half the live cost. Turnaround can range from minutes to about 24 hours — check back here for progress.")
            }
        } else if needingGeneration.count > 2 {
            Section {
                Button {
                    isSubmittingBatch = true
                    Task { await startBackgroundGeneration() }
                } label: {
                    if isSubmittingBatch {
                        HStack {
                            ProgressView()
                            Text("Submitting…")
                        }
                    } else {
                        Text("Generate All \(needingGeneration.count) Chapters in Background (~50% cheaper)")
                    }
                }
                .disabled(isSubmittingBatch)
                if let batchStatusMessage {
                    Text(batchStatusMessage).font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("An alternative to \"Generate & Start\" below for a whole book at once — runs in the background instead of blocking on an immediate quiz, at roughly half the cost.")
            }
        }
    }

    private func startBackgroundGeneration() async {
        defer { isSubmittingBatch = false }
        guard !claudeService.apiKey.isEmpty else {
            showNoAPIKeyAlert = true
            return
        }
        // Once, for both the submission and the message about it -- and so the
        // sentence can never name a different number than what was submitted.
        let needing = chaptersNeedingGeneration
        do {
            try await BatchGenerationService.submit(chapters: needing, in: book, claudeService: claudeService)
            batchStatusMessage = "Submitted \(needing.count) chapter(s) for background generation."
        } catch {
            batchStatusMessage = error.localizedDescription
        }
    }

    private func checkBatchStatus() async {
        defer { isCheckingStatus = false }
        do {
            guard let progress = try await BatchGenerationService.checkProgress(claudeService: claudeService) else {
                batchProgress = nil
                return
            }
            batchProgress = progress
            guard progress.isDone else { return }

            if let result = try await BatchGenerationService.applyResultsIfDone(claudeService: claudeService, modelContext: modelContext) {
                batchStatusMessage = "Applied \(result.questionsInserted) question(s) across \(result.chaptersUpdated) chapter(s)."
                if result.chaptersFailed > 0 {
                    batchStatusMessage! += " \(result.chaptersFailed) chapter(s) failed and can be generated individually instead."
                }
                // A haptic nudge for a background job finishing while the
                // user may not be looking at the screen -- the one moment
                // in this flow with no other feedback mechanism.
                batchDidApplyResults.toggle()
            }
            batchProgress = nil
        } catch {
            batchStatusMessage = error.localizedDescription
        }
    }

    private func cancelBatchGeneration() async {
        defer { isCancelingBatch = false }
        do {
            try await BatchGenerationService.cancel(claudeService: claudeService)
            batchProgress = nil
            batchStatusMessage = "Background generation canceled."
        } catch {
            batchStatusMessage = error.localizedDescription
        }
    }

    // MARK: - Preparation flow

    private func beginPreparation() {
        prepError = nil
        failedChapters = []
        // Computed ONCE here, then used three times, instead of three separate
        // whole-book scans in a row.
        let needing = chaptersNeedingGeneration
        if !needing.isEmpty {
            guard !claudeService.apiKey.isEmpty else {
                showNoAPIKeyAlert = true
                return
            }
            pendingChaptersToGenerate = needing
            // Priced at the same instant as the list it prices -- the number
            // the confirmation alert quotes.
            pendingEstimatedCost = estimatedCost(for: needing)
            showCostConfirm = true
        } else {
            // Set synchronously, not just inside `startWithoutGenerating()`'s own
            // first line -- `Task { }` doesn't run its body inline, it schedules it,
            // so a fast double-tap on "Start Quiz" landed both taps before the
            // button's `.disabled(isPreparing || ...)` had actually flipped, each
            // one inserting and saving its own `QuizAttempt`. Flipping the flag
            // here, before the tap handler even returns, makes the second tap see
            // the button already disabled.
            isPreparing = true
            Task { await startWithoutGenerating() }
        }
    }

    /// Used to be: one thrown error on ANY chapter set `prepError` and `return`ed
    /// immediately, abandoning every remaining chapter in the batch — a single
    /// network blip on chapter 2 of 12 meant chapters 3-12 never even attempted.
    /// Now each chapter gets its own bounded retry (`RetryPolicy`, transient
    /// failures only — a bad API key or a content refusal isn't retried, since
    /// asking again wouldn't help and would just bill twice for the same
    /// non-answer) and a chapter that still fails after retrying doesn't stop the
    /// rest of the batch — it's recorded in `failedChapters` and the loop
    /// continues. Only chapters that never succeeded stay in scope for a manual
    /// retry via `retryFailedChapters()`.
    private func generateThenStart() async {
        isPreparing = true
        defer { isPreparing = false }
        failedChapters = []

        for chapter in pendingChaptersToGenerate {
            do {
                try await RetryPolicy.run {
                    try await QuizGenerationService.generateQuestions(for: chapter, in: book, claudeService: claudeService, modelContext: modelContext)
                }
            } catch {
                failedChapters.append(chapter)
            }
        }

        if failedChapters.isEmpty {
            prepError = nil
        } else if failedChapters.count == pendingChaptersToGenerate.count {
            prepError = "Couldn't generate questions for any chapter — check your connection and try again."
        } else {
            let succeededCount = pendingChaptersToGenerate.count - failedChapters.count
            prepError = "Generated \(succeededCount) of \(pendingChaptersToGenerate.count) chapters — \(failedChapters.count) failed: \(failedChapters.map(\.title).joined(separator: ", "))."
        }

        // Start with whatever DID generate rather than blocking the whole quiz on
        // a chapter or two that didn't -- a partial quiz is more useful than none.
        // But skip this entirely on a TOTAL failure: `startWithoutGenerating()`
        // unconditionally overwrites `prepError` with a generic "No questions
        // available for this scope yet." the moment its own pool is empty,
        // silently clobbering the more useful "check your connection and try
        // again" message just set above with no way back to it.
        let allChaptersFailed = !pendingChaptersToGenerate.isEmpty && failedChapters.count == pendingChaptersToGenerate.count
        guard !allChaptersFailed else { return }
        await startWithoutGenerating()
    }

    private func retryFailedChapters() {
        prepError = nil
        pendingChaptersToGenerate = failedChapters
        // Same eager flip as `beginPreparation()` above, and for the same reason --
        // this button is only `.disabled(isPreparing)`, which doesn't actually
        // become true until `generateThenStart()`'s Task body starts running.
        isPreparing = true
        Task { await generateThenStart() }
    }

    private func startWithoutGenerating() async {
        isPreparing = true
        defer { isPreparing = false }

        // Free, on-device, no API key needed — runs regardless of whether
        // Claude generation was needed for this scope. Cheap (string/tag
        // matching + NLTagger, no network), so it's fine to check on every
        // quiz start; already-covered highlights are skipped internally.
        for chapter in chaptersInScope {
            ClozeService.generateIfNeeded(for: chapter, in: book, modelContext: modelContext)
        }

        var pool: [QuizQuestion] = []
        switch scope {
        case .chapter(let chapter):
            pool = chapter.quizQuestions
        case .wholeBook:
            pool = chaptersInScope.flatMap(\.quizQuestions)
        case .topic:
            pool = chaptersInScope.flatMap(\.quizQuestions).filter { !Set($0.topicTags).isDisjoint(with: selectedTags) }
        case .reviewQueue:
            pool = dueQuestions()
        }

        if mixInDueReviews, scope != .reviewQueue {
            let due = dueQuestions()
            pool.append(contentsOf: due.filter { q in !pool.contains(where: { $0.id == q.id }) })
        }

        guard !pool.isEmpty else {
            prepError = "No questions available for this scope yet."
            return
        }

        let selected = Array(pool.shuffled().prefix(questionCount))
        let scopeDescription: String = {
            switch scope {
            case .chapter(let c): return c.title
            case .topic: return "Topic: \(selectedTags.sorted().joined(separator: ", "))"
            case .wholeBook: return "Whole Book"
            case .reviewQueue: return "Review Queue"
            }
        }()

        let timeLimit = mode == .examSimulation ? selected.count * 90 : nil
        let attempt = QuizAttempt(book: book, scopeDescription: scopeDescription, mode: mode, timeLimitSeconds: timeLimit)
        attempt.totalQuestions = selected.count
        modelContext.insert(attempt)
        try? modelContext.save()

        sessionNavigation = AttemptNavigationWrapper(attempt: attempt, questions: selected)
    }
}

/// Not `private` -- reused by `QuizHomeView`'s Daily Review entry point,
/// which needs the identical "build the attempt, then navigate" shape.
struct AttemptNavigationWrapper: Identifiable, Hashable {
    let attempt: QuizAttempt
    let questions: [QuizQuestion]
    var id: UUID { attempt.id }

    static func == (lhs: AttemptNavigationWrapper, rhs: AttemptNavigationWrapper) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
