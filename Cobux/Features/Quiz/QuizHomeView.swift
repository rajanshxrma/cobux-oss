import SwiftUI
import SwiftData

struct QuizHomeView: View {
    @Bindable var claudeService: ClaudeService
    @Binding var path: NavigationPath
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]
    /// The only `@Query` this tab keeps. It used to hold four: `themes`,
    /// `answerRecords` and `figures` too, and the tab shell keeps every tab
    /// alive, so all four re-fetched on EVERY store save from any tab -- the
    /// 1,597 `Figure` rows were resident for the life of the app to answer
    /// one `isEmpty`. The three are gone: the counts come from `QuizHomeProbe`
    /// below, and the two tap actions that need themes or answer records
    /// fetch them at the tap (`fetchThemes`/`fetchAnswerRecords`).
    @State private var figureNavigation: FigureDeckWrapper?
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

    private typealias PrimaryRecommendation = QuizHomeCounts.PrimaryRecommendation

    /// Every count this screen shows, read by `QuizHomeProbe` off the main
    /// actor and published here. `nil` until the first probe lands.
    ///
    /// History, because the same defect has now been fixed here twice and the
    /// second fix is the one that holds. First: five computed properties each
    /// re-ran `books.flatMap(\.chapters).flatMap(\.quizQuestions)` and `body`
    /// read them ~25 times per render -- two dozen library walks per frame.
    /// The fix was one snapshot per body (`makeCounts()`), which was still one
    /// walk of ~490 chapters (a SELECT each) PLUS `weakSpotsPool`, which
    /// faults every `theme.highlights` row -- every highlight in the library
    /// carrying its 2 KB vector -- on the main thread, in `body`, on every
    /// render of a tab the shell keeps alive. That is the identical defect
    /// `WisdomGraphView` had and fixed with `WisdomProbe`; this is the same
    /// shape. The numbers are the same numbers -- see the probe for how each
    /// definition was restated as a `COUNT`.
    ///
    /// The previous counts stay on screen while a refresh runs (the Wisdom
    /// grid lesson: a screen does not empty itself to reload).
    @State private var counts: QuizHomeCounts?
    /// Bumped on every appearance so a card that came due while he was on
    /// another tab is counted the next time he looks.
    @State private var appearances = 0

    /// What the probe's answer depends on. `path.isEmpty` covers coming back
    /// from a chapter's quiz generation (`QuizScopeBuilderView` is pushed on
    /// this stack); the three navigation wrappers cover the end of a session,
    /// which is what changes the due count most. While any of those is
    /// non-empty the root is not visible and `loadCounts` declines to run.
    private var probeKey: String {
        let inSession = dailyReviewNavigation != nil || quickModeNavigation != nil || spokenQuizNavigation != nil
        return "\(books.count)|\(path.isEmpty)|\(inSession)|\(SeedingStatus.shared.isSeeding)|\(appearances)"
    }

    /// `@MainActor` explicitly, the way `WisdomGraphView.loadCounts` is: this
    /// assigns `@State`, and a bare `async` method makes no promise about
    /// which actor it resumes on (SE-0338). The probe's method is isolated to
    /// its `@ModelActor`, so awaiting it hops off main and only a `Sendable`
    /// value comes back -- no `@Model` object and no `ModelContext` crosses.
    @MainActor
    private func loadCounts() async {
        guard !SeedingStatus.shared.isSeeding, path.isEmpty,
              dailyReviewNavigation == nil, quickModeNavigation == nil, spokenQuizNavigation == nil
        else { return }
        let probe = QuizHomeProbe(modelContainer: modelContext.container)
        counts = await probe.counts()
    }

    /// Fetched at the tap, for the two pools that need them. These were
    /// `@Query`s held for the life of the tab and re-fetched on every store
    /// save; the taps that need them are rare and can afford one fetch each.
    private func fetchThemes() -> [Theme] {
        (try? modelContext.fetch(FetchDescriptor<Theme>())) ?? []
    }

    private func fetchAnswerRecords() -> [QuizAnswerRecord] {
        (try? modelContext.fetch(FetchDescriptor<QuizAnswerRecord>())) ?? []
    }

    var body: some View {
        NavigationStack(path: $path) {
            if SeedingStatus.shared.isSeeding {
                // The probe reads `theme.highlights` while building -- doing
                // that while the background seed/upgrade merge is
                // mid-transaction is the Build-5 crash class. Show a
                // placeholder until the merge lands; the observable flip
                // re-renders the real screen and `probeKey` re-runs the probe.
                ProgressView("Syncing your library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Quiz")
            } else {
                quizContent(counts)
                    .task(id: probeKey) { await loadCounts() }
            }
        }
    }

    private func quizContent(_ counts: QuizHomeCounts?) -> some View {
            List {
                // `!books.isEmpty` matters on its own, not just as a proxy for
                // primaryRecommendation: `streak` comes from StreakTracker's own
                // shared UserDefaults, entirely independent of whether any Book
                // still exists -- a returning user who empties their whole
                // library keeps a real streak > 0 with primaryRecommendation
                // correctly nil, which without this check would leave just the
                // streak chip floating above the "No books yet" empty state
                // below instead of falling through to it cleanly.
                //
                // `counts == nil` keeps the slot: before the probe lands the
                // card is drawn redacted (the `WidgetInviteView` convention --
                // greyed bars, never a number that has not been read), so the
                // screen's anchor is on frame one and fills in rather than
                // arriving a beat later and pushing the shelf down.
                if !books.isEmpty && (streak > 0 || counts == nil || counts?.primary != nil) {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            if streak > 0 {
                                streakChip
                            }
                            if let counts {
                                if let primary = counts.primary {
                                    primaryActionCard(for: primary, counts: counts)
                                }
                            } else {
                                primaryActionCard(for: .dailyReview, counts: .pending)
                                    .redacted(reason: .placeholder)
                                    .disabled(true)
                            }
                        }
                        .padding(.horizontal, CobuxSpacing.screenMargin)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                if let counts, counts.hasAnyPracticeRow || counts.hasFigures {
                    CobuxFormSection(title: "More Ways to Practice") {
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
                                start(QuizModeService.discriminationDrillPool(books: books, answerRecords: fetchAnswerRecords()), scopeDescription: "Discrimination Drills")
                            }
                        }
                        if counts.weakSpots > 0 {
                            quickModeRow(
                                title: "Weak Spots", systemImage: "target",
                                detail: "\(counts.weakSpots) question\(counts.weakSpots == 1 ? "" : "s")"
                            ) {
                                start(QuizModeService.weakSpotsPool(books: books, themes: fetchThemes(), answerRecords: fetchAnswerRecords()), scopeDescription: "Weak Spots")
                            }
                        }
                        if counts.showsChapterCramRow {
                            Button {
                                showingChapterCramPicker = true
                            } label: {
                                modeLabel("Chapter Cram", systemImage: "text.book.closed.fill")
                            }
                        }
                        if counts.due > 0 {
                            Button {
                                startSpokenQuiz()
                            } label: {
                                modeLabel("Spoken Quiz", systemImage: "mic.fill")
                            }
                        }
                        // Hidden until image extraction actually populates Figure rows --
                        // blocked on Rajan's own Anthropic API key, per the plan's own guard
                        // requirement ("hide itself from the mode picker when zero Figure rows
                        // exist, so it doesn't couple Quiz's ship date to the image blocker").
                        if counts.hasFigures {
                            Button {
                                startFigureID()
                            } label: {
                                modeLabel("Figure ID", systemImage: "photo.on.rectangle.angled")
                            }
                        }
                    }
                }

                CobuxFormSection(title: "Browse by Book") {
                    ForEach(books) { book in
                        NavigationLink(destination: QuizScopeBuilderView(book: book, claudeService: claudeService)) {
                            QuizBookRow(book: book)
                        }
                    }
                }

                CobuxFormSection(title: "Analytics") {
                    NavigationLink(destination: QuizAnalyticsView()) {
                        modeLabel("Analytics", systemImage: "chart.bar.fill")
                    }
                }
            }
            // The whole reason this screen read as flat next to Settings.
            //
            // It was `.plain` + `scrollContentBackground(.hidden)` + a
            // `cobuxBackground` fill + `cobuxSurface2` on every row -- a
            // grouped list rebuilt by hand out of full-bleed bands. In dark
            // mode that paints edge-to-edge slabs at (0.125, 0.098, 0.106) on
            // a (0.031, 0.020, 0.024) ground, separated by `cobuxLine`
            // hairlines: four times the ground's luminance, running off both
            // screen edges, with no inset and no corner. Settings does none of
            // it -- no list style, no background, no row background, headers
            // through `CobuxFormSection` -- and gets the system's inset cards
            // and iOS 26's material for free. Rajan, on exactly this pair:
            // *"the quzi seciton ui colors in dark mode kinda looks ugly make
            // it better liek the settings section in dark mode look so
            // beatiful."* So this screen now joins that family instead of
            // imitating it. The hero row keeps its clear background and zero
            // insets, because the primary card is meant to float free of the
            // grouping -- that part was always right.
            //
            // P9 adds one thing under the family look: in dark the list's
            // black backdrop steps aside for the journal's crimson wash
            // (`cobuxRoomGround`), and the inset cards keep their material on
            // top of it. Light is untouched, grouped grey and all.
            .cobuxRoomGround()
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
            .fullScreenCover(item: $figureNavigation) { wrapper in
                FigureIDView(figures: wrapper.figures, onDone: { figureNavigation = nil })
            }
            .onAppear {
                streak = StreakTracker.currentStreak
                appearances += 1
            }
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
    private func primaryActionCard(for recommendation: PrimaryRecommendation, counts: QuizHomeCounts) -> some View {
        Button(action: primaryAction(for: recommendation)) {
            HStack(spacing: 16) {
                // The machinery-badge rule (see `quickModeRow`): crimson glyph
                // on a crimson wash. This well was a violet wash under a
                // crimson glyph -- one of three badge treatments on one
                // screen. The card's glass keeps its violet tint: the card is
                // the interactive surface, the badge is the machinery.
                ZStack {
                    Circle()
                        .fill(Color.cobuxCrimson.opacity(0.14))
                        .frame(width: 56, height: 56)
                    Image(systemName: primaryIcon(for: recommendation))
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.cobuxCrimson)
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
    private func primarySubtitle(for recommendation: PrimaryRecommendation, counts: QuizHomeCounts) -> some View {
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

    /// The deck is fetched HERE, at the tap, and released when the cover
    /// closes -- not held in a `@Query` for the life of the tab. Same
    /// `shuffled()` as before; same wrapper shape as the three quiz sessions.
    private func startFigureID() {
        let figures = (try? modelContext.fetch(FetchDescriptor<Figure>())) ?? []
        guard !figures.isEmpty else { return }
        figureNavigation = FigureDeckWrapper(figures: figures.shuffled())
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

        dailyReviewNavigation = AttemptNavigationWrapper(attempt: attempt, questions: QuizModeService.warmUpOrdered(queue))
    }

    /// Shared starter for Rapid Recall/Discrimination Drills/Weak Spots/Chapter Cram --
    /// each is just a different pool feeding the same practice-mode session, exactly like
    /// Daily Review already does.
    private func start(_ questions: [QuizQuestion], scopeDescription: String) {
        guard !questions.isEmpty else { return }
        let attempt = QuizAttempt(book: nil, scopeDescription: scopeDescription, mode: .practice)
        modelContext.insert(attempt)
        try? modelContext.save()
        quickModeNavigation = AttemptNavigationWrapper(attempt: attempt, questions: QuizModeService.warmUpOrdered(questions))
    }

    /// The badge-label the mode rows share -- same grammar as
    /// `quickModeRow`, extracted so NavigationLink rows can use it too.
    @ViewBuilder
    private func modeLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: CobuxRadius.iconBadge, style: .continuous)
                .fill(Color.cobuxCrimson.opacity(0.14))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.cobuxCrimson)
                }
            Text(title)
                .font(CobuxTypography.cobuxRowLabel)
        }
    }

    @ViewBuilder
    private func quickModeRow(title: String, systemImage: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // The design system's icon-badge grammar (`CobuxRadius.iconBadge`
                // documents it for settings rows): modes are app machinery, so
                // every badge on this screen is uniformly CRIMSON on a crimson
                // wash -- the curated machinery chrome the red-black identity
                // owns (`ContentView`'s tint comment). Variety on this screen
                // comes from the books' own spines, never from the tools.
                RoundedRectangle(cornerRadius: CobuxRadius.iconBadge, style: .continuous)
                    .fill(Color.cobuxCrimson.opacity(0.14))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: systemImage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.cobuxCrimson)
                    }
                Text(title)
                    .font(CobuxTypography.cobuxRowLabel)
                Spacer()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Presented-deck wrapper for Figure ID, mirroring `AttemptNavigationWrapper`:
/// `fullScreenCover(item:)` owns the deck's lifetime, so the `Figure` rows are
/// held only while the cover is up and dropped with it.
struct FigureDeckWrapper: Identifiable {
    let id = UUID()
    let figures: [Figure]
}

/// Every count the Quiz home shows. A value type of plain integers and
/// booleans -- `Sendable`, so it is the ONLY thing that crosses back from
/// `QuizHomeProbe`'s actor.
struct QuizHomeCounts: Equatable, Sendable {
    /// One "what should I do right now" recommendation, in the same priority
    /// order the screen always used (Daily Review's own section came before
    /// "More Ways to Practice", which itself listed Rapid Recall before
    /// Chapter Cram). `nil` only when there's truly nothing to recommend --
    /// `CobuxEmptyStateView` already owns the fully-empty-library case via
    /// `books.isEmpty`.
    enum PrimaryRecommendation: Equatable, Sendable {
        case dailyReview
        case rapidRecall
        case chapterCram
    }

    var due = 0
    var rapidRecall = 0
    var discriminationDrill = 0
    var weakSpots = 0
    var hasAnyChapters = false
    var hasFigures = false

    /// Drawn redacted while the first probe is in flight.
    static let pending = QuizHomeCounts()

    var primary: PrimaryRecommendation? {
        if due > 0 { return .dailyReview }
        if rapidRecall > 0 { return .rapidRecall }
        if hasAnyChapters { return .chapterCram }
        return nil
    }

    /// Whichever mode got promoted into the primary card must not also still appear as a
    /// duplicate row further down in "More Ways to Practice".
    var showsRapidRecallRow: Bool { rapidRecall > 0 && primary != .rapidRecall }
    var showsChapterCramRow: Bool { hasAnyChapters && primary != .chapterCram }

    var hasAnyPracticeRow: Bool {
        showsRapidRecallRow || discriminationDrill > 0 || weakSpots > 0
            || showsChapterCramRow || due > 0
    }
}

/// Reads the Quiz home's six numbers off the main actor -- `WisdomProbe`'s
/// shape, for the same defect. A `@ModelActor` owns a `ModelContext` confined
/// to its own executor, every model read happens there, and only
/// `QuizHomeCounts` comes back.
///
/// EVERY DEFINITION BELOW IS THE OLD ONE, restated so the store can answer it.
/// The old pool was `Collection<Book>.allQuizQuestions` -- the questions
/// reached through `book.chapters[].quizQuestions` -- which as a predicate is
/// `chapter != nil` (the restatement `WatchSyncService.scheduledDueDates`
/// already made and documented; a chapter always has a book, by cascade).
/// The four counts:
///
///   due                  `!isSuspended && dueDate <= now`
///                        (`DailyReviewService.dueQuestions`)          -> COUNT
///   rapidRecall          due && fsrsReps > 0, capped at 15
///                        (`QuizModeService.rapidRecallPool`)          -> min(15, COUNT)
///   discriminationDrill  !isSuspended, not `.application`, has choices,
///                        shares a tag with a missed question
///                        (`QuizModeService.discriminationDrillPool`)   -> predicate for the
///                        first three, then the SAME `isDiscriminationCandidate` test the
///                        pool applies, over three fetched columns
///   weakSpots            !isSuspended && cites a highlight of a weakest theme
///                        (`QuizModeService.weakSpotsPool`)            -> the SAME
///                        `weakHighlights` the pool uses, walked through the
///                        `Highlight.quizQuestions` inverse instead of testing every
///                        question's `sourceHighlights`; the set of questions is identical
///                        because the two relationships are inverses of one another
///
/// `hasAnyChapters` (`books.contains { !$0.chapters.isEmpty }`) is a COUNT of
/// chapters with a book; `hasFigures` (`!figures.isEmpty`) is a COUNT of
/// figures. The date comparison form `($0.dueDate ?? distantFuture) <= now`
/// is the one `DiagnosticsProbe.counts()` already proved against SwiftData's
/// translation.
@ModelActor
actor QuizHomeProbe {
    func counts(now: Date = .now) -> QuizHomeCounts {
        var result = QuizHomeCounts()
        let distantFuture = Date.distantFuture

        result.due = count(FetchDescriptor<QuizQuestion>(
            predicate: #Predicate {
                $0.isSuspended == false && $0.chapter != nil && ($0.dueDate ?? distantFuture) <= now
            }))
        result.rapidRecall = min(QuizModeService.rapidRecallLimit, count(FetchDescriptor<QuizQuestion>(
            predicate: #Predicate {
                $0.isSuspended == false && $0.chapter != nil && $0.fsrsReps > 0
                    && ($0.dueDate ?? distantFuture) <= now
            })))
        result.hasAnyChapters = count(FetchDescriptor<Chapter>(
            predicate: #Predicate { $0.book != nil })) > 0
        result.hasFigures = count(FetchDescriptor<Figure>()) > 0

        // Both remaining pools start from the answer records; fetched once.
        let answerRecords = (try? modelContext.fetch(FetchDescriptor<QuizAnswerRecord>())) ?? []
        result.discriminationDrill = discriminationDrillCount(answerRecords: answerRecords)
        result.weakSpots = weakSpotsCount(answerRecords: answerRecords)
        return result
    }

    private func discriminationDrillCount(answerRecords: [QuizAnswerRecord]) -> Int {
        let missedTags = QuizModeService.missedTopicTags(answerRecords: answerRecords)
        guard !missedTags.isEmpty else { return 0 }
        // `questionType` maps an unknown raw value to `.recallMCQ`, so
        // `questionTypeRaw != "application"` is exactly `questionType !=
        // .application`.
        let application = QuizQuestionType.application.rawValue
        var descriptor = FetchDescriptor<QuizQuestion>(
            predicate: #Predicate {
                $0.isSuspended == false && $0.chapter != nil && $0.questionTypeRaw != application
            })
        descriptor.propertiesToFetch = [\.questionTypeRaw, \.choices, \.topicTags]
        let candidates = (try? modelContext.fetch(descriptor)) ?? []
        return candidates.reduce(into: 0) { total, question in
            if QuizModeService.isDiscriminationCandidate(questionType: question.questionType,
                                                         choices: question.choices,
                                                         topicTags: question.topicTags,
                                                         missedTags: missedTags) {
                total += 1
            }
        }
    }

    /// `theme.highlights` is faulted HERE, on this actor, for the weakest
    /// three themes only -- that fault, for every theme, in `body`, on the
    /// main thread, was the whole cost of the Quiz tab.
    private func weakSpotsCount(answerRecords: [QuizAnswerRecord]) -> Int {
        let themes = (try? modelContext.fetch(FetchDescriptor<Theme>())) ?? []
        let weakHighlights = QuizModeService.weakHighlights(themes: themes, answerRecords: answerRecords)
        guard !weakHighlights.isEmpty else { return 0 }
        var questionIDs: Set<UUID> = []
        for highlight in weakHighlights {
            for question in highlight.quizQuestions where !question.isSuspended && question.chapter != nil {
                questionIDs.insert(question.id)
            }
        }
        return questionIDs.count
    }

    private func count<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> Int {
        (try? modelContext.fetchCount(descriptor)) ?? 0
    }
}

private struct QuizBookRow: View {
    let book: Book

    /// The counts, computed once per appearance in `.task` — never in `body`.
    ///
    /// This is the Quiz shelf's scroll cost, and it was all of it. `body` used
    /// to open with `let counts = makeRowCounts()`, so every re-evaluation of
    /// this row — and SwiftUI re-evaluates a row's body constantly while a
    /// finger is moving — ran, for ONE row: one fault of `book.chapters`, one
    /// fault of `book.highlights` (materialising every highlight the book
    /// owns), a `chapterRef` read per highlight, a sort of every resulting
    /// bucket, then a fault of `chapter.quizQuestions` per chapter, and a
    /// content hash over the chapter's full highlight text for every chapter
    /// that had already been generated. On the two reference textbooks that is
    /// roughly a hundred and twenty SQL queries and a hundred-plus kilobytes of
    /// string building, per row, per frame.
    ///
    /// Nothing about the work changed and no number here is estimated,
    /// sampled or capped — it is the same traversal producing the same
    /// integers. Only *when* it runs changed: once, after this row has already
    /// laid out, on the same `.task` convention `BookCard` uses for its
    /// highlight count and `JournalThumbnailImage` uses for its bitmap.
    @State private var counts: RowCounts?

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

    /// Must stay on the main actor: it reads `@Model` rows bound to the main
    /// context, and reading those from another actor is this codebase's known
    /// crash class. A `nonisolated` async function would NOT inherit the
    /// caller's actor (SE-0338), so the annotation is load-bearing, not
    /// decorative.
    @MainActor
    private func makeRowCounts() -> RowCounts {
        var counts = RowCounts()
        let now = Date.now
        // Bucketed ONCE for the whole book instead of re-filtering every
        // highlight in the book, twice, for each of its chapters -- see
        // `QuizGenerationService.highlightsByChapterID`. This row is the Quiz
        // shelf's per-book row, so the old shape ran that filter for every
        // visible row on every body evaluation of the shelf.
        let highlightsByChapter = QuizGenerationService.highlightsByChapterID(in: book)
        for chapter in book.chapters {
            counts.chapters += 1
            // Read once, used twice below. Also REORDERED: the cheap
            // "has any questions at all" test now comes first, so a chapter
            // that has never been generated skips the content hash entirely --
            // and that is most chapters in most libraries. Both operands are
            // pure reads, so the answer is unchanged; only the work is.
            let questions = chapter.quizQuestions
            if !questions.isEmpty,
               !QuizGenerationService.needsGeneration(
                   chapter: chapter,
                   highlights: highlightsByChapter[chapter.persistentModelID] ?? []) {
                counts.ready += 1
            }
            // FSRS-based, not the legacy per-highlight `HighlightMemory` -- must
            // match `DailyReviewService.dueQuestions`'s exact filter, or this
            // row's badge and the Daily Review count above it show two
            // different due counts.
            for question in questions
            where !question.isSuspended && (question.dueDate.map { $0 <= now } ?? false) {
                counts.due += 1
            }
        }
        return counts
    }

    var body: some View {
        HStack(spacing: 12) {
            // The book's spine: its own cover color, four points wide. This is
            // what un-tables the list -- content carries its own color here
            // (the same law Flow's atmosphere follows), while app machinery
            // stays uniformly accent. Static fill, no per-frame cost.
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: book.coverColorHex))
                .frame(width: 4, height: 36)
            VStack(alignment: .leading, spacing: 4) {
            BookTitleText(title: book.title)
            HStack(spacing: 8) {
                // A single space until the counts land, never a placeholder
                // number and never a collapsed line. Two reasons, both
                // deliberate: "No chapters yet" is a real state this row can
                // report, so showing it before the traversal has run would be
                // stating something false about the book; and a caption that
                // appears out of nothing would re-flow the row's height under
                // a moving finger, which is the exact feeling this whole change
                // exists to remove. One space in this font reserves the line.
                Text(counts?.readyChaptersDescription ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: counts?.ready ?? 0)
                if let counts, counts.due > 0 {
                    // Not `.cobuxWarning` -- Rajan's own note: a due count
                    // reading as a warning sign makes quiz feel like an
                    // obligation with stakes, which isn't this app's purpose.
                    // "To review" over "due" for the same reason --
                    // informational, not a deadline. The same machinery
                    // badge as the mode rows: crimson on a crimson wash (it
                    // was crimson type on a violet wash, a third treatment).
                    Label("\(counts.due) to review", systemImage: "circle.fill")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.cobuxCrimson.opacity(0.14))
                        .foregroundStyle(Color.cobuxCrimson)
                        .clipShape(Capsule())
                }
            }
            }
        }
        .padding(.vertical, 2)
        // After layout, not during it. Keyed on the book so a recycled row
        // recomputes for whichever book it now represents rather than showing
        // the previous one's numbers.
        .task(id: book.id) { counts = makeRowCounts() }
    }
}
