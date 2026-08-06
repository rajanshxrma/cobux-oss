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
    @State private var sessionNavigation: AttemptNavigationWrapper?
    @State private var showNoAPIKeyAlert = false

    @State private var batchProgress: BatchGenerationService.Progress?
    @State private var batchStatusMessage: String?
    @State private var batchDidApplyResults = false

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

    private var dueReviewCount: Int {
        book.highlights.compactMap(\.memory).filter { $0.nextReviewDate <= .now }.count
    }

    // MARK: - Exam Countdown

    private var notIntroducedCount: Int {
        book.chapters.flatMap(\.quizQuestions).filter { $0.dueDate == nil && !$0.isSuspended }.count
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

    private var chaptersNeedingGeneration: [Chapter] {
        chaptersInScope.filter { QuizGenerationService.needsGeneration(chapter: $0, in: book) }
    }

    private var totalEstimatedCost: Double {
        chaptersNeedingGeneration.reduce(0) { $0 + QuizGenerationService.estimatedCost(for: $1, in: book) }
    }

    var body: some View {
        Form {
            Section("What to quiz") {
                Picker("Scope", selection: Binding(
                    get: { scopeSelectionTag },
                    set: { setScope(tag: $0) }
                )) {
                    Text("By Chapter").tag("chapter")
                    Text("By Topic").tag("topic")
                    Text("Whole Book").tag("wholeBook")
                    if dueReviewCount > 0 {
                        Text("Review Queue (\(dueReviewCount) due)").tag("reviewQueue")
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
                    Text("Pulls only your \(dueReviewCount) already-cached questions due for review right now — no generation needed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("How to quiz") {
                Picker("Mode", selection: $mode) {
                    Text("Practice").tag(QuizMode.practice)
                    Text("Exam Simulation").tag(QuizMode.examSimulation)
                }
                .pickerStyle(.segmented)

                if dueReviewCount > 0, scope != .reviewQueue {
                    Toggle("Mix in due reviews", isOn: $mixInDueReviews)
                }

                Stepper("Up to \(questionCount) questions", value: $questionCount, in: 3...30, step: 1)
            }

            backgroundGenerationSection

            examCountdownSection

            if let prepError {
                Section {
                    Text(prepError)
                        .foregroundStyle(.red)
                        .font(.footnote)
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
                    } else if !chaptersNeedingGeneration.isEmpty {
                        Text("Generate & Start (~$\(String(format: "%.2f", totalEstimatedCost)), one-time)")
                    } else {
                        Text("Start Quiz")
                    }
                }
                .disabled(isPreparing || !scopeHasAnyContent)
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
            Text("Uses your Anthropic API key to write quiz questions for \(pendingChaptersToGenerate.count) chapter(s) — about $\(String(format: "%.2f", totalEstimatedCost)), a one-time cost. Cached afterward, so re-quizzing this scope is free unless the chapter's highlights change.")
        }
        .alert("API Key Required", isPresented: $showNoAPIKeyAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Add your Anthropic API key in Settings to generate quiz questions.")
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

    private var topicChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(allTags, id: \.self) { tag in
                    let isSelected = selectedTags.contains(tag)
                    Button {
                        if isSelected { selectedTags.remove(tag) } else { selectedTags.insert(tag) }
                    } label: {
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(isSelected ? Color.cobuxAccent : Color.secondary.opacity(0.12))
                            .foregroundStyle(isSelected ? .white : .primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var scopeHasAnyContent: Bool {
        switch scope {
        case .reviewQueue: return dueReviewCount > 0
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
    @ViewBuilder
    private var backgroundGenerationSection: some View {
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
                Button("Check Status") { Task { await checkBatchStatus() } }
                Button("Cancel Background Generation", role: .destructive) { Task { await cancelBatchGeneration() } }
                if let batchStatusMessage {
                    Text(batchStatusMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Background Generation")
            } footer: {
                Text("Submitted via Anthropic's Batch API at roughly half the live cost. Turnaround can range from minutes to about 24 hours — check back here for progress.")
            }
        } else if chaptersNeedingGeneration.count > 2 {
            Section {
                Button("Generate All \(chaptersNeedingGeneration.count) Chapters in Background (~50% cheaper)") {
                    Task { await startBackgroundGeneration() }
                }
                if let batchStatusMessage {
                    Text(batchStatusMessage).font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("An alternative to \"Generate & Start\" below for a whole book at once — runs in the background instead of blocking on an immediate quiz, at roughly half the cost.")
            }
        }
    }

    private func startBackgroundGeneration() async {
        guard !claudeService.apiKey.isEmpty else {
            showNoAPIKeyAlert = true
            return
        }
        do {
            try await BatchGenerationService.submit(chapters: chaptersNeedingGeneration, in: book, claudeService: claudeService)
            batchStatusMessage = "Submitted \(chaptersNeedingGeneration.count) chapter(s) for background generation."
        } catch {
            batchStatusMessage = error.localizedDescription
        }
    }

    private func checkBatchStatus() async {
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
        if !chaptersNeedingGeneration.isEmpty {
            guard !claudeService.apiKey.isEmpty else {
                showNoAPIKeyAlert = true
                return
            }
            pendingChaptersToGenerate = chaptersNeedingGeneration
            showCostConfirm = true
        } else {
            Task { await startWithoutGenerating() }
        }
    }

    private func generateThenStart() async {
        isPreparing = true
        defer { isPreparing = false }
        for chapter in pendingChaptersToGenerate {
            do {
                try await QuizGenerationService.generateQuestions(for: chapter, in: book, claudeService: claudeService, modelContext: modelContext)
            } catch {
                prepError = "Couldn't generate questions for \"\(chapter.title)\": \(error.localizedDescription)"
                return
            }
        }
        await startWithoutGenerating()
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
            let dueHighlightIDs = Set(book.highlights.compactMap { h -> UUID? in
                guard let memory = h.memory, memory.nextReviewDate <= .now else { return nil }
                return h.id
            })
            pool = book.chapters.flatMap(\.quizQuestions).filter { question in
                !question.sourceHighlights.filter { dueHighlightIDs.contains($0.id) }.isEmpty
            }
        }

        if mixInDueReviews, scope != .reviewQueue {
            let dueHighlightIDs = Set(book.highlights.compactMap { h -> UUID? in
                guard let memory = h.memory, memory.nextReviewDate <= .now else { return nil }
                return h.id
            })
            let dueQuestions = book.chapters.flatMap(\.quizQuestions).filter { question in
                !question.sourceHighlights.filter { dueHighlightIDs.contains($0.id) }.isEmpty
            }
            pool.append(contentsOf: dueQuestions.filter { q in !pool.contains(where: { $0.id == q.id }) })
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
