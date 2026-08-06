import SwiftUI
import SwiftData

struct QuizHomeView: View {
    @Bindable var claudeService: ClaudeService
    @Binding var path: NavigationPath
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]
    @Query private var themes: [Theme]
    @Query private var answerRecords: [QuizAnswerRecord]
    @Query private var figures: [Figure]
    @State private var showingFigureID = false
    @State private var dailyReviewNavigation: AttemptNavigationWrapper?
    @State private var quickModeNavigation: AttemptNavigationWrapper?
    @State private var spokenQuizNavigation: AttemptNavigationWrapper?
    @State private var showingChapterCramPicker = false

    /// The FSRS-backed cross-library queue (`QuizQuestion.dueDate`) — distinct
    /// from each book row's own `dueReviewCount`, which still reads the older
    /// per-highlight `HighlightMemory.nextReviewDate` and only ever covers one
    /// book at a time. Daily Review is the first entry point that actually
    /// spans the whole library.
    private var dueCount: Int { DailyReviewService.dueQuestions(in: books).count }

    private var rapidRecallCount: Int { QuizModeService.rapidRecallPool(books: books).count }
    private var discriminationDrillCount: Int { QuizModeService.discriminationDrillPool(books: books, answerRecords: answerRecords).count }
    private var weakSpotsCount: Int { QuizModeService.weakSpotsPool(books: books, themes: themes, answerRecords: answerRecords).count }
    private var hasAnyChapters: Bool { books.contains { !$0.chapters.isEmpty } }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if dueCount > 0 {
                    Section {
                        Button {
                            startDailyReview()
                        } label: {
                            HStack {
                                Label("Daily Review", systemImage: "clock.arrow.circlepath")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.cobuxInk)
                                Spacer()
                                Text("\(min(dueCount, DailyReviewService.defaultNewPerDay + DailyReviewService.defaultReviewsPerDay)) due")
                                    .cobuxNumeralStyle(size: 15)
                                    .foregroundStyle(Color.cobuxAccent)
                                    .contentTransition(.numericText())
                                    .animation(.easeOut(duration: 0.3), value: dueCount)
                            }
                        }
                        .listRowBackground(Color.cobuxSurface2)
                    }
                    .listRowSeparatorTint(Color.cobuxLine)
                }

                if rapidRecallCount > 0 || discriminationDrillCount > 0 || weakSpotsCount > 0 || hasAnyChapters || !figures.isEmpty {
                    Section {
                        if rapidRecallCount > 0 {
                            quickModeRow(
                                title: "Rapid Recall", systemImage: "bolt.fill",
                                detail: "\(rapidRecallCount) card\(rapidRecallCount == 1 ? "" : "s")"
                            ) {
                                start(QuizModeService.rapidRecallPool(books: books), scopeDescription: "Rapid Recall")
                            }
                        }
                        if discriminationDrillCount > 0 {
                            quickModeRow(
                                title: "Discrimination Drills", systemImage: "arrow.left.arrow.right",
                                detail: "\(discriminationDrillCount) question\(discriminationDrillCount == 1 ? "" : "s")"
                            ) {
                                start(QuizModeService.discriminationDrillPool(books: books, answerRecords: answerRecords), scopeDescription: "Discrimination Drills")
                            }
                        }
                        if weakSpotsCount > 0 {
                            quickModeRow(
                                title: "Weak Spots", systemImage: "target",
                                detail: "\(weakSpotsCount) question\(weakSpotsCount == 1 ? "" : "s")"
                            ) {
                                start(QuizModeService.weakSpotsPool(books: books, themes: themes, answerRecords: answerRecords), scopeDescription: "Weak Spots")
                            }
                        }
                        if hasAnyChapters {
                            Button {
                                showingChapterCramPicker = true
                            } label: {
                                Label("Chapter Cram", systemImage: "text.book.closed.fill")
                            }
                            .listRowBackground(Color.cobuxSurface2)
                        }
                        if dueCount > 0 {
                            Button {
                                startSpokenQuiz()
                            } label: {
                                Label("Spoken Quiz", systemImage: "mic.fill")
                            }
                            .listRowBackground(Color.cobuxSurface2)
                        }
                        // Hidden until image extraction actually populates Figure rows --
                        // blocked on Rajan's own Anthropic API key, per the plan's own guard
                        // requirement ("hide itself from the mode picker when zero Figure rows
                        // exist, so it doesn't couple Quiz's ship date to the image blocker").
                        if !figures.isEmpty {
                            Button {
                                showingFigureID = true
                            } label: {
                                Label("Figure ID", systemImage: "photo.on.rectangle.angled")
                            }
                            .listRowBackground(Color.cobuxSurface2)
                        }
                    } header: {
                        Text("More Ways to Practice")
                    }
                    .listRowSeparatorTint(Color.cobuxLine)
                }

                Section {
                    ForEach(books) { book in
                        NavigationLink(destination: QuizScopeBuilderView(book: book, claudeService: claudeService)) {
                            QuizBookRow(book: book)
                        }
                        .listRowBackground(Color.cobuxSurface2)
                    }
                }
                .listRowSeparatorTint(Color.cobuxLine)

                Section {
                    NavigationLink(destination: QuizAnalyticsView()) {
                        Label("Analytics", systemImage: "chart.bar.fill")
                    }
                    .listRowBackground(Color.cobuxSurface2)
                }
                .listRowSeparatorTint(Color.cobuxLine)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.cobuxBackground)
            .navigationTitle("Quiz")
            .overlay {
                if books.isEmpty {
                    CobuxEmptyStateView(
                        icon: "questionmark.circle",
                        title: "No books yet",
                        message: "Add a book in Library to start quizzing yourself on it."
                    )
                }
            }
            .navigationDestination(item: $dailyReviewNavigation) { wrapper in
                QuizSessionView(attempt: wrapper.attempt, questions: wrapper.questions, onDone: { dailyReviewNavigation = nil })
            }
            .navigationDestination(item: $quickModeNavigation) { wrapper in
                QuizSessionView(attempt: wrapper.attempt, questions: wrapper.questions, onDone: { quickModeNavigation = nil })
            }
            .sheet(isPresented: $showingChapterCramPicker) {
                ChapterCramPickerView(books: books) { chapter in
                    showingChapterCramPicker = false
                    start(chapter.quizQuestions, scopeDescription: "Chapter Cram: \(chapter.title)")
                }
            }
            .fullScreenCover(item: $spokenQuizNavigation) { wrapper in
                SpokenQuizView(attempt: wrapper.attempt, questions: wrapper.questions, onDone: { spokenQuizNavigation = nil })
            }
            .fullScreenCover(isPresented: $showingFigureID) {
                FigureIDView(figures: figures.shuffled(), onDone: { showingFigureID = false })
            }
        }
    }

    private func startSpokenQuiz() {
        let due = DailyReviewService.dueQuestions(in: books)
        let queue = DailyReviewService.budgetedQueue(from: due)
        guard !queue.isEmpty else { return }

        let attempt = QuizAttempt(book: nil, scopeDescription: "Spoken Quiz", mode: .practice)
        modelContext.insert(attempt)
        try? modelContext.save()

        spokenQuizNavigation = AttemptNavigationWrapper(attempt: attempt, questions: queue)
    }

    private func startDailyReview() {
        let due = DailyReviewService.dueQuestions(in: books)
        let queue = DailyReviewService.budgetedQueue(from: due)
        guard !queue.isEmpty else { return }

        let attempt = QuizAttempt(book: nil, scopeDescription: "Daily Review", mode: .practice)
        modelContext.insert(attempt)
        try? modelContext.save()

        dailyReviewNavigation = AttemptNavigationWrapper(attempt: attempt, questions: queue)
    }

    /// Shared starter for Rapid Recall/Discrimination Drills/Weak Spots/Chapter Cram --
    /// each is just a different pool feeding the same practice-mode session, exactly like
    /// Daily Review already does.
    private func start(_ questions: [QuizQuestion], scopeDescription: String) {
        guard !questions.isEmpty else { return }
        let attempt = QuizAttempt(book: nil, scopeDescription: scopeDescription, mode: .practice)
        modelContext.insert(attempt)
        try? modelContext.save()
        quickModeNavigation = AttemptNavigationWrapper(attempt: attempt, questions: questions.shuffled())
    }

    @ViewBuilder
    private func quickModeRow(title: String, systemImage: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listRowBackground(Color.cobuxSurface2)
    }
}

private struct QuizBookRow: View {
    let book: Book

    private var readyChapterCount: Int {
        book.chapters.filter { !QuizGenerationService.needsGeneration(chapter: $0, in: book) && !$0.quizQuestions.isEmpty }.count
    }

    /// FSRS-based, not the legacy per-highlight `HighlightMemory` -- must match
    /// `DailyReviewService.dueQuestions`'s exact filter, or this row's badge and
    /// the Daily Review count above it show two different due counts.
    private var dueReviewCount: Int {
        book.chapters.flatMap(\.quizQuestions).filter { !$0.isSuspended && ($0.dueDate.map { $0 <= .now } ?? false) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            BookTitleText(title: book.title)
            HStack(spacing: 8) {
                if book.chapters.isEmpty {
                    Text("No chapters yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(readyChapterCount)/\(book.chapters.count) chapters ready to quiz")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.3), value: readyChapterCount)
                }
                if dueReviewCount > 0 {
                    Label("\(dueReviewCount) due", systemImage: "clock.arrow.circlepath")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.cobuxWarning.opacity(0.15))
                        .foregroundStyle(Color.cobuxWarning)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 2)
    }
}
