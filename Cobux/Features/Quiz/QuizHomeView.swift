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
    /// Copy-tone only. `retention` (the default every pre-persona install
    /// lands on) keeps this screen's wording byte-identical to pre-2.3.0;
    /// `exam` is that same wording (it was written for exam prep); `habit`
    /// swaps in streak-forward framing. Behavior and recommendation order
    /// never change with persona.
    @AppStorage(UserPersona.storageKey) private var personaRaw = UserPersona.retention.rawValue
    private var persona: UserPersona { UserPersona(rawValue: personaRaw) ?? .retention }
    /// Same read-then-refresh-on-appear convention as `MoreView` -- `StreakTracker.currentStreak`
    /// is a computed read of UserDefaults, not something SwiftUI observes on its own.
    @State private var streak = StreakTracker.currentStreak

    /// One "what should I do right now" recommendation, in the same priority order the
    /// screen already used implicitly (Daily Review's own section came before "More Ways
    /// to Practice", which itself listed Rapid Recall before Chapter Cram) -- this promotes
    /// exactly one of those into the prominent card at the top instead of inventing new
    /// selection logic. `nil` only when there's truly nothing to recommend (no due reviews,
    /// no rapid-recall pool, no chapters anywhere) -- `CobuxEmptyStateView` already owns the
    /// fully-empty-library case via `books.isEmpty`, so this doesn't need to duplicate it.
    private enum PrimaryRecommendation {
        case dailyReview
        case rapidRecall
        case chapterCram
    }

    /// Every count this screen shows, derived from a single library traversal.
    ///
    /// These were five computed properties (`dueCount`, `rapidRecallCount`,
    /// `discriminationDrillCount`, `weakSpotsCount`, `hasAnyChapters`) plus
    /// three more layered on top of them (`primaryRecommendation`,
    /// `showsRapidRecallRow`, `showsChapterCramRow`). Swift recomputes a
    /// computed property on *every* access, and `body` read them about
    /// twenty-five times per render — several from inside the row builders,
    /// and each of the three derived ones re-triggering the pools underneath
    /// it. Every one of those reads ran `books.flatMap(\.chapters)
    /// .flatMap(\.quizQuestions)` from scratch. So one render of the Quiz tab
    /// walked this library's ~490 chapters and their questions roughly two
    /// dozen times over, on the main thread, before a single pixel appeared —
    /// the "takes a long time to switch tabs" report. Now: one traversal, one
    /// snapshot, every number read from it.
    private struct Counts {
        var due = 0
        var rapidRecall = 0
        var discriminationDrill = 0
        var weakSpots = 0
        var hasAnyChapters = false
        var primary: PrimaryRecommendation?

        /// Whichever mode got promoted into the primary card must not also still appear as a
        /// duplicate row further down in "More Ways to Practice".
        var showsRapidRecallRow: Bool { rapidRecall > 0 && primary != .rapidRecall }
        var showsChapterCramRow: Bool { hasAnyChapters && primary != .chapterCram }

        var hasAnyPracticeRow: Bool {
            showsRapidRecallRow || discriminationDrill > 0 || weakSpots > 0
                || showsChapterCramRow || due > 0
        }
    }

    private func makeCounts() -> Counts {
        var counts = Counts()
        // The one traversal. Everything below reads this array, never `books`.
        let allQuestions = books.allQuizQuestions
        counts.due = DailyReviewService.dueQuestions(among: allQuestions).count
        counts.rapidRecall = QuizModeService.rapidRecallPool(among: allQuestions).count
        counts.discriminationDrill = QuizModeService.discriminationDrillPool(
            among: allQuestions, answerRecords: answerRecords
        ).count
        counts.weakSpots = QuizModeService.weakSpotsPool(
            among: allQuestions, themes: themes, answerRecords: answerRecords
        ).count
        counts.hasAnyChapters = books.contains { !$0.chapters.isEmpty }

        if counts.due > 0 {
            counts.primary = .dailyReview
        } else if counts.rapidRecall > 0 {
            counts.primary = .rapidRecall
        } else if counts.hasAnyChapters {
            counts.primary = .chapterCram
        }
        return counts
    }

    var body: some View {
        NavigationStack(path: $path) {
            if SeedingStatus.shared.isSeeding {
                // This screen's due/pool counts fault every chapter's
                // quizQuestions relationship on evaluation — doing that while
                // the background seed/upgrade merge is mid-transaction is the
                // Build-5 crash class. Show a placeholder until the merge
                // lands; the observable flip re-renders the real screen.
                ProgressView("Syncing your library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Quiz")
            } else {
                quizContent(makeCounts())
            }
        }
    }

    private func quizContent(_ counts: Counts) -> some View {
            List {
                // `!books.isEmpty` matters on its own, not just as a proxy for
                // primaryRecommendation: `streak` comes from StreakTracker's own
                // shared UserDefaults, entirely independent of whether any Book
                // still exists -- a returning user who empties their whole
                // library keeps a real streak > 0 with primaryRecommendation
                // correctly nil, which without this check would leave just the
                // streak chip floating above the "No books yet" empty state
                // below instead of falling through to it cleanly.
                if !books.isEmpty && (streak > 0 || counts.primary != nil) {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            if streak > 0 {
                                streakChip
                            }
                            if let primary = counts.primary {
                                primaryActionCard(for: primary, counts: counts)
                            }
                        }
                        .padding(.horizontal, CobuxSpacing.screenMargin)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                if counts.hasAnyPracticeRow || !figures.isEmpty {
                    Section {
                        if counts.showsRapidRecallRow {
                            quickModeRow(
                                title: "Rapid Recall", systemImage: "bolt.fill",
                                detail: "\(counts.rapidRecall) card\(counts.rapidRecall == 1 ? "" : "s")"
                            ) {
                                start(QuizModeService.rapidRecallPool(books: books), scopeDescription: "Rapid Recall")
                            }
                        }
                        if counts.discriminationDrill > 0 {
                            quickModeRow(
                                title: "Discrimination Drills", systemImage: "arrow.left.arrow.right",
                                detail: "\(counts.discriminationDrill) question\(counts.discriminationDrill == 1 ? "" : "s")"
                            ) {
                                start(QuizModeService.discriminationDrillPool(books: books, answerRecords: answerRecords), scopeDescription: "Discrimination Drills")
                            }
                        }
                        if counts.weakSpots > 0 {
                            quickModeRow(
                                title: "Weak Spots", systemImage: "target",
                                detail: "\(counts.weakSpots) question\(counts.weakSpots == 1 ? "" : "s")"
                            ) {
                                start(QuizModeService.weakSpotsPool(books: books, themes: themes, answerRecords: answerRecords), scopeDescription: "Weak Spots")
                            }
                        }
                        if counts.showsChapterCramRow {
                            Button {
                                showingChapterCramPicker = true
                            } label: {
                                Label("Chapter Cram", systemImage: "text.book.closed.fill")
                            }
                            .listRowBackground(Color.cobuxSurface2)
                        }
                        if counts.due > 0 {
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
                } header: {
                    Text("Browse by Book")
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
            .onAppear { streak = StreakTracker.currentStreak }
    }

    /// Compact, satisfying streak readout -- reuses the exact numeral/content-transition
    /// convention this file already used for `dueCount` before this change, and the
    /// flame/`.cobuxWarning` convention `MoreView` already established for the same
    /// `StreakTracker.currentStreak` value, so this reads as the same streak, not a
    /// second, differently-styled one.
    private var streakChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
                .foregroundStyle(Color.cobuxWarning)
            Text("\(streak) day\(streak == 1 ? "" : "s") streak")
                .cobuxNumeralStyle(size: 14)
                .foregroundStyle(Color.cobuxInk)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.3), value: streak)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .cobuxGlassChip(tintColor: Color.cobuxWarning)
    }

    /// The one prominent, "start here" card -- deliberately NOT a plain list row like
    /// everything else on this screen, per `.cobuxGlassCard()`'s own doc comment: this is
    /// the one thing that should visually float and pop against the flat rows below it.
    /// Tap action reuses whichever start function that mode already used today; no new
    /// navigation/session logic.
    @ViewBuilder
    private func primaryActionCard(for recommendation: PrimaryRecommendation, counts: Counts) -> some View {
        Button(action: primaryAction(for: recommendation)) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.cobuxAccent.opacity(0.15))
                        .frame(width: 56, height: 56)
                    Image(systemName: primaryIcon(for: recommendation))
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.cobuxAccent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(primaryTitle(for: recommendation))
                        .font(CobuxTypography.cobuxTitle)
                        .foregroundStyle(Color.cobuxInk)
                    primarySubtitle(for: recommendation, counts: counts)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(18)
        }
        .buttonStyle(.plain)
        .cobuxGlassCard(tintColor: Color.cobuxAccent)
    }

    private func primaryAction(for recommendation: PrimaryRecommendation) -> () -> Void {
        switch recommendation {
        case .dailyReview:
            return startDailyReview
        case .rapidRecall:
            return { start(QuizModeService.rapidRecallPool(books: books), scopeDescription: "Rapid Recall") }
        case .chapterCram:
            return { showingChapterCramPicker = true }
        }
    }

    private func primaryIcon(for recommendation: PrimaryRecommendation) -> String {
        switch recommendation {
        case .dailyReview: return "clock.arrow.circlepath"
        case .rapidRecall: return "bolt.fill"
        case .chapterCram: return "text.book.closed.fill"
        }
    }

    private func primaryTitle(for recommendation: PrimaryRecommendation) -> String {
        switch recommendation {
        case .dailyReview: return persona == .habit ? "Keep the Streak Alive" : "Continue Daily Review"
        case .rapidRecall: return "Rapid Recall"
        case .chapterCram: return persona == .habit ? "Revisit a Chapter" : "Chapter Cram"
        }
    }

    @ViewBuilder
    private func primarySubtitle(for recommendation: PrimaryRecommendation, counts: Counts) -> some View {
        switch recommendation {
        case .dailyReview:
            let capped = min(counts.due, DailyReviewService.defaultNewPerDay + DailyReviewService.defaultReviewsPerDay)
            Text("\(capped) card\(capped == 1 ? "" : "s") due today")
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.3), value: counts.due)
        case .rapidRecall:
            Text("\(counts.rapidRecall) card\(counts.rapidRecall == 1 ? "" : "s") ready — quick and easy")
        case .chapterCram:
            Text("Pick a chapter to review")
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

    /// Same one-pass treatment as `QuizHomeView.Counts`, at row scale. The two
    /// counts below were computed properties read seven times between them per
    /// row render (`readyChaptersDescription` alone touches `readyChapterCount`
    /// three times), each one re-walking this book's chapters — and
    /// `readyChapterCount` re-runs `QuizGenerationService.needsGeneration` per
    /// chapter while it's at it.
    private struct RowCounts {
        var chapters = 0
        var ready = 0
        var due = 0

        /// Softer than the old "N/M chapters ready to quiz" fraction -- clinical, exam-bank
        /// phrasing that reads fine to a med student but odd to a population-generic user
        /// browsing a plain reading app. Same three states (nothing ready / partly ready /
        /// fully ready), plainer words.
        var readyChaptersDescription: String {
            guard chapters > 0 else { return "No chapters yet" }
            if ready == 0 { return "Not ready to quiz yet" }
            if ready == chapters { return "All \(ready) chapters ready" }
            return "\(ready) of \(chapters) chapters ready"
        }
    }

    private func makeRowCounts() -> RowCounts {
        var counts = RowCounts()
        let now = Date.now
        for chapter in book.chapters {
            counts.chapters += 1
            if !QuizGenerationService.needsGeneration(chapter: chapter, in: book) && !chapter.quizQuestions.isEmpty {
                counts.ready += 1
            }
            // FSRS-based, not the legacy per-highlight `HighlightMemory` -- must
            // match `DailyReviewService.dueQuestions`'s exact filter, or this
            // row's badge and the Daily Review count above it show two
            // different due counts.
            for question in chapter.quizQuestions
            where !question.isSuspended && (question.dueDate.map { $0 <= now } ?? false) {
                counts.due += 1
            }
        }
        return counts
    }

    var body: some View {
        let counts = makeRowCounts()
        VStack(alignment: .leading, spacing: 4) {
            BookTitleText(title: book.title)
            HStack(spacing: 8) {
                Text(counts.readyChaptersDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: counts.ready)
                if counts.due > 0 {
                    // Neutral accent, not `.cobuxWarning` -- Rajan's own
                    // note: a due count reading as a warning sign makes
                    // quiz feel like an obligation with stakes, which isn't
                    // this app's purpose. "To review" over "due" for the
                    // same reason -- informational, not a deadline.
                    Label("\(counts.due) to review", systemImage: "circle.fill")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.cobuxAccent.opacity(0.15))
                        .foregroundStyle(Color.cobuxAccent)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 2)
    }
}
