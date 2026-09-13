import SwiftUI
import SwiftData
import UIKit

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
        let container = modelContext.container
        // (61) The cache first. `TabWarmCache` ran this same probe ~1.2 s
        // after launch, off the main actor, and again after every save that
        // could move a number -- so on the ordinary first tap the counts are
        // already here and this is one dictionary read, no probe. Past
        // `quizMaxAge` the cached numbers stay on screen and the probe runs
        // behind them: cards come due with the clock, not with a save.
        if let cached = TabWarmCache.shared.quizCounts(for: container, maxAge: TabWarmCache.quizMaxAge) {
            counts = cached
            return
        }
        let generation = TabWarmCache.shared.generation
        let fresh = await TabWarmCache.shared.fillQuiz(container: container)
        counts = fresh
        TabWarmCache.shared.storeQuiz(fresh, for: container, ifGeneration: generation)
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
                // `counts ?? cache`: the FIRST body of this tab reads the
                // warm cache synchronously, so the screen's anchor card is
                // drawn with its real numbers on frame one -- no redacted
                // placeholder, no probe -- whenever the cache has them. The
                // `.task` below then either confirms them (a dictionary read)
                // or, when the cache is empty, runs the probe as before.
                quizContent(counts ?? TabWarmCache.shared.quizCounts(for: modelContext.container, maxAge: nil))
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
                // 61: no streak here -- "the streak is already displayed in
                // the more section". The chip's wording moved there.
                if !books.isEmpty && (counts == nil || counts?.primary != nil) {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
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
                //
                // And it breathes (beauty checklist, Quiz 1) -- behind an
                // `.equatable()` barrier, for the reason `QuizPrimaryWell`'s
                // own comment gives: `counts` landing re-evaluates THIS body,
                // and a `repeatForever` re-applied from a re-evaluated body
                // is how the Sigil died three builds running.
                QuizPrimaryWell(icon: primaryIcon(for: recommendation))
                    .equatable()
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

/// The primary card's icon well, alive (beauty checklist, Quiz 1).
///
/// The one card on Quiz that is meant to feel alive -- everything under it is
/// deliberately flat list rows -- and until now its crimson circle was as
/// still as they are. It breathes now: the well swells and settles on a slow
/// 3.4 s ease, the same period as the Sigil's float, and a fainter halo
/// behind it breathes the other way, so the pair reads as light moving
/// through the mark rather than a dot pulsing. The glyph itself holds
/// still; it is the thing being lit, not the light.
///
/// **The Sigil's discipline, copied -- not its rig.** `CobuxSigilView`'s
/// doc comment records exactly how an ambient `repeatForever` dies: a parent
/// re-evaluates the body inside a live transaction, the animatable modifier
/// is re-applied, and the in-flight loop is re-targeted to a one-shot ease
/// to where it already is. The flag stays `true`, so nothing ever restarts
/// it. On this screen the parent transaction is `counts` landing from
/// `loadCounts` -- once per appearance, and again after every save that
/// moves a number -- which re-evaluates `primaryActionCard` every time. So:
///
/// 1. This is its own view whose only input is the icon name, it is
///    `Equatable` on that alone, and the parent applies `.equatable()`. A
///    `counts` update that keeps the same recommendation does not
///    re-evaluate this body at all; one that changes it swaps the icon, and
///    the phase flag is reset properly rather than re-applied.
/// 2. The animation is a literal constant, never a `reduceMotion ? nil :`
///    ternary. Under Reduce Motion the breathing layers are conditionally
///    ABSENT -- the well is the same static circle it was before this
///    change -- exactly as the Sigil's band and `FlowLaunchButton.ground`
///    do it.
/// 3. Restarting is a real reset (`restartBreath`, the Sigil's
///    `restartAmbientMotion` in miniature): force the flag false with
///    animations disabled, then true on the next turn, so a well torn down
///    and rebuilt with its `@State` intact, or one returning from the
///    background, sees an actual change to animate rather than a flag that
///    is already `true`.
///
/// Not a `TimelineView`. The Sigil pays a per-tick redraw because a Canvas
/// cannot read an animated value without its closure re-running; a
/// `scaleEffect` on a `Circle` needs none of that. One state flip on appear,
/// then the render server interpolates two transforms with this body never
/// running again -- no timer, no clock, nothing per frame. The first frame
/// costs what it cost before: two circles and a glyph.
private struct QuizPrimaryWell: View, Equatable {
    let icon: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var breathPhase = false

    /// The icon is the whole identity; `@State` and environment are not
    /// inputs, and comparing them would defeat the barrier.
    static func == (lhs: QuizPrimaryWell, rhs: QuizPrimaryWell) -> Bool {
        lhs.icon == rhs.icon
    }

    var body: some View {
        ZStack {
            if reduceMotion {
                well
            } else {
                // The halo: fainter, wider, breathing against the well so
                // the two never read as one dot growing. It lives inside the
                // card's own 18pt padding at its widest (68pt against a 56pt
                // well) and is never a tap target -- the Button is the card.
                Circle()
                    .fill(Color.cobuxCrimson.opacity(0.07))
                    .frame(width: 68, height: 68)
                    .scaleEffect(breathPhase ? 0.96 : 1.04)
                well
                    .scaleEffect(breathPhase ? 1.05 : 0.95)
            }
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.cobuxCrimson)
        }
        // Applied to the stack, not to each circle: one animation, one phase,
        // both layers move on it. The glyph reads no animatable value.
        .animation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true),
                   value: breathPhase)
        .onAppear(perform: restartBreath)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { restartBreath() }
        }
        // A changed recommendation swaps the glyph and re-evaluates this
        // body; the reset makes that a fresh start rather than a re-applied
        // offset the Sigil's comment warns about.
        .onChange(of: icon) { _, _ in restartBreath() }
    }

    /// The circle exactly as it was before this view existed.
    private var well: some View {
        Circle()
            .fill(Color.cobuxCrimson.opacity(0.14))
            .frame(width: 56, height: 56)
    }

    /// Reduce Motion short-circuits it: the breathing layers are not in the
    /// tree, so there is nothing to restart and flipping the flag would only
    /// cost a body evaluation.
    @MainActor private func restartBreath() {
        guard !reduceMotion else { return }
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { breathPhase = false }
        Task { @MainActor in breathPhase = true }
    }
}

private struct QuizBookRow: View {
    let book: Book
    @Environment(\.modelContext) private var modelContext

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
    ///
    /// (61) And now WHERE: the traversal runs on `QuizBookRowProbe`'s own
    /// executor, not the main actor. It faults the book's whole highlight
    /// array -- for a reference text, ~700 rows with a 2 KB vector each --
    /// and `.task`'s closure runs on the main actor, so a synchronous
    /// `makeRowCounts()` there still blocked the frame after the row laid
    /// out, once per visible row, on every first appearance. The first
    /// screen's rows are also in `TabWarmCache`, filled ~1.2 s after launch,
    /// so on the ordinary first tap this is a dictionary read.
    @State private var counts: QuizBookRowCounts?

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
                    //
                    // The mark before the words is the app's own capsule,
                    // not SF's `circle.fill` (beauty checklist, Quiz 2): the
                    // calendar's day bars and the streak underline mark a
                    // day or a count with a `Capsule()`, and this was the
                    // one place a stock dot did that job. Same crimson,
                    // same words, same meaning; only the shape joined the
                    // family. Still a `Label`, so VoiceOver reads it as one
                    // element exactly as before.
                    Label {
                        Text("\(counts.due) to review")
                    } icon: {
                        Capsule()
                            .fill(Color.cobuxCrimson)
                            .frame(width: 10, height: 4)
                    }
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
        .task(id: book.id) { await loadRowCounts() }
    }

    /// `@MainActor` explicitly, the way `QuizHomeView.loadCounts` is: this
    /// assigns `@State`, and only a `Sendable` value comes back from the
    /// probe. The book's id crosses, never the `Book`.
    @MainActor
    private func loadRowCounts() async {
        let container = modelContext.container
        let bookID = book.id
        if let cached = TabWarmCache.shared.quizRowCounts(bookID: bookID, for: container) {
            counts = cached
            return
        }
        // The probe faults `book.highlights` on its executor; never against
        // a store the seed merge is mutating (the Build-5 crash class). The
        // shelf is behind a "Syncing" placeholder while seeding, so this is
        // belt to that braces.
        guard !SeedingStatus.shared.isSeeding else { return }
        let generation = TabWarmCache.shared.generation
        // One probe per row, released with this task -- so the rows it
        // registered (that book's highlights) do not stay resident.
        let probe = QuizBookRowProbe(modelContainer: container)
        guard let loaded = await probe.counts(bookID: bookID, now: .now), !Task.isCancelled else { return }
        counts = loaded
        TabWarmCache.shared.storeQuizRow(loaded, bookID: bookID, for: container, ifGeneration: generation)
    }
}

/// One Quiz shelf row's numbers, as a value. Same one-pass treatment as
/// `QuizHomeCounts`, at row scale: the two counts below were computed
/// properties read seven times between them per row render
/// (`readyChaptersDescription` alone touches `readyChapterCount` three
/// times), each one re-walking this book's chapters — and `readyChapterCount`
/// re-ran `QuizGenerationService.needsGeneration` per chapter while it was at
/// it. `Sendable`, so it is the only thing that crosses back from
/// `QuizBookRowProbe`.
struct QuizBookRowCounts: Equatable, Sendable {
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

/// Reads one shelf row's counts off the main actor -- `QuizHomeProbe`'s
/// shape, one level down. The traversal is `QuizBookRow.makeRowCounts` as it
/// was through build 60, moved onto this actor's own context: the `Book` it
/// walks is this context's row, resolved by stored id (`$0.id == bookID`,
/// the shape `WisdomBookDestination` and `ContentView.shareText` ship), and
/// nothing but `QuizBookRowCounts` comes back.
@ModelActor
actor QuizBookRowProbe {
    func counts(bookID: UUID, now: Date) -> QuizBookRowCounts? {
        var descriptor = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.id == bookID })
        descriptor.fetchLimit = 1
        guard let book = (try? modelContext.fetch(descriptor))?.first else { return nil }
        return rowCounts(for: book, now: now)
    }

    /// The rows the shelf shows first -- `QuizHomeView`'s `@Query` order,
    /// newest book first -- for `TabWarmCache` to fill before the tab is
    /// ever opened. `limit` is the cache's own budget, not this probe's.
    func firstScreenCounts(limit: Int, now: Date) -> [UUID: QuizBookRowCounts] {
        var descriptor = FetchDescriptor<Book>(sortBy: [SortDescriptor(\Book.dateAdded, order: .reverse)])
        descriptor.fetchLimit = limit
        var result: [UUID: QuizBookRowCounts] = [:]
        for book in (try? modelContext.fetch(descriptor)) ?? [] {
            result[book.id] = rowCounts(for: book, now: now)
        }
        return result
    }

    private func rowCounts(for book: Book, now: Date) -> QuizBookRowCounts {
        var counts = QuizBookRowCounts()
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
}

// MARK: - The warm cache

/// Wisdom's per-theme counts, the hero card's one boolean, and the book
/// scope they were computed under -- as values. A snapshot is served only
/// when the tab's own `excludedBookIDs` is exactly this set; otherwise it is
/// as if nothing were cached.
struct WisdomCountsSnapshot: Sendable, Equatable {
    let hasAnyVisibleHighlight: Bool
    let counts: [UUID: Int]
    let excludedBookIDs: Set<UUID>
}

/// The numbers the Quiz and Wisdom tabs show on their first frame, read
/// before the tabs are ever opened and kept as values independent of any
/// view's lifetime.
///
/// WHY 60's WARM FRAMES DID NOT REACH THESE TWO TABS. `PagingTabView`'s
/// warm-up gives each unloaded host one frame in the window so its
/// `.onAppear`/`.task` fire -- and then removes it, which CANCELS every
/// `.task` the appearance started (SwiftUI cancels a `.task` on disappear).
/// Library's and More's first frames are cheap and their tasks are short, so
/// they came out warm. Quiz's `QuizHomeProbe` and Wisdom's `WisdomProbe` are
/// the two tasks that take longer than a frame, so they were cancelled every
/// launch and ran again, from zero, under the thumb on the real first tap:
/// "moving onto the quiz and the wisdom tabs is still pretty slow at the
/// first". The warm frames stay (they pre-render layout); the WORK now runs
/// here, on the probes' own executors, ~1.2 s after launch and after the
/// shell's warm-up, and the tabs read the answer synchronously in their
/// first body -- no placeholder, no probe -- falling back to the probe only
/// when the cache is empty.
///
/// WHAT IS CACHED. `QuizHomeCounts` (the four counts and two booleans), the
/// first screen's `QuizBookRowCounts` (`rowWarmBudget` rows, newest book
/// first -- the shelf's own order), and `WisdomCountsSnapshot`. All values,
/// all small: a few hundred integers. So every phone class fills the whole
/// cache; what `DeviceClass.compact` changes is only the heavy part -- how
/// many shelf rows are walked (each faults one book's highlights) -- never
/// whether the tabs get their numbers.
///
/// INVALIDATION mirrors `FlowWarmCache` and `SemanticVectorCache`: a
/// `ModelContext.didSave` from any context whose payload names a watched
/// table drops everything and re-warms `saveDebounce` later while the app is
/// active and no seed merge is writing. A save that DELETES `Highlight` or
/// `Book` rows also marks the stored theme counts for verification
/// (`Theme.cachedHighlightCount` can only go stale by a deletion -- a new
/// highlight carries no theme until the next rebuild, which rewrites the
/// counts), persisted in `UserDefaults` so a kill between the deletion and
/// the repair cannot lose it. The repair is `WisdomProbe.visibleCounts`'s
/// relationship read, once, which writes the corrected columns back; its
/// own save is ignored here through `writeBackGate` so it cannot re-trigger
/// itself.
///
/// Nothing here grades anything: these are the same numbers the tabs
/// showed on 60, read earlier.
@MainActor
final class TabWarmCache {
    static let shared = TabWarmCache()

    struct Stamped<Value: Sendable>: Sendable {
        let value: Value
        let at: Date
    }

    /// After the launch tab's first frame and the shell's warm-up passes
    /// (`PagingTabView.Coordinator.scheduleWarmUp` starts at 0.9 s and this
    /// also waits for `shellWarmUpInFlight` to clear), before Flow's own deck
    /// at 1.5 s.
    nonisolated static let launchDelay: Duration = .milliseconds(1200)
    /// How long after a store save the cache is rebuilt. The seed merge and
    /// the embedding backfill save in bursts; this folds a burst into one.
    nonisolated static let saveDebounce: Duration = .milliseconds(1500)
    /// Past this age the Quiz tab's appearance re-probes behind the cached
    /// numbers: cards come due with the clock, and no save marks that.
    nonisolated static let quizMaxAge: TimeInterval = 5 * 60
    /// The shelf rows walked at warm time. Ten is more than a first screen
    /// holds at any text size; six on a compact phone, where each row's
    /// fault of a reference text's highlights is the heavy part.
    nonisolated static var rowWarmBudget: Int { DeviceClass.current.isCompact ? 6 : 10 }
    /// Every table a cached number is read from. `QuizAttempt` is not here:
    /// an attempt row changes no count on either tab.
    nonisolated static let watchedEntities: Set<String> = [
        "QuizQuestion", "QuizAnswerRecord", "Theme", "Highlight", "Chapter", "Figure", "Book"
    ]
    /// Whether a deletion since the last repair means the stored theme
    /// counts must be re-read from the relationship once. Persisted, not a
    /// flag in memory: see the type comment.
    nonisolated static let verificationKey = "cobux.wisdom.themeCountsNeedVerification"

    private(set) var quiz: Stamped<QuizHomeCounts>?
    private(set) var wisdom: Stamped<WisdomCountsSnapshot>?
    private var quizRows: [UUID: QuizBookRowCounts] = [:]
    private var container: ModelContainer?
    private var warmTask: Task<Void, Never>?
    /// Bumped on every invalidation. A probe result is stored only if the
    /// cache was not invalidated while the probe ran, so a save that landed
    /// mid-probe cannot be papered over by the probe's older answer.
    private(set) var generation = 0
    /// Set by the tab shell around its warm-up passes, so the probes here
    /// do not contend with the tabs' first bodies for the store.
    var shellWarmUpInFlight = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: nil
        ) { note in
            guard !Self.writeBackGate.isWritingBack, Self.touchesWatchedTables(note) else { return }
            if Self.deletesHighlightRows(note) {
                UserDefaults.standard.set(true, forKey: Self.verificationKey)
            }
            Task { @MainActor in
                TabWarmCache.shared.invalidate(rebuildAfter: TabWarmCache.saveDebounce)
            }
        })
    }

    // MARK: Reading

    /// The Quiz home's counts, if cached for this store and, when `maxAge`
    /// is given, no older than that.
    func quizCounts(for container: ModelContainer, maxAge: TimeInterval?) -> QuizHomeCounts? {
        guard self.container === container, let quiz else { return nil }
        if let maxAge, Date.now.timeIntervalSince(quiz.at) > maxAge { return nil }
        return quiz.value
    }

    /// Wisdom's counts, if cached for this store under exactly this scope.
    func wisdomCounts(for container: ModelContainer, excluding excludedBookIDs: Set<UUID>) -> WisdomCountsSnapshot? {
        guard self.container === container, let wisdom,
              wisdom.value.excludedBookIDs == excludedBookIDs else { return nil }
        return wisdom.value
    }

    func quizRowCounts(bookID: UUID, for container: ModelContainer) -> QuizBookRowCounts? {
        guard self.container === container else { return nil }
        return quizRows[bookID]
    }

    /// Whether the next Wisdom count must take the relationship path once.
    var themeCountsNeedVerification: Bool {
        UserDefaults.standard.bool(forKey: Self.verificationKey)
    }

    // MARK: Storing -- the tabs' own probe results feed the cache too

    func storeQuiz(_ counts: QuizHomeCounts, for container: ModelContainer, ifGeneration expected: Int) {
        guard generation == expected, self.container === container || self.container == nil else { return }
        self.container = container
        quiz = Stamped(value: counts, at: .now)
    }

    /// `verified` says the snapshot came from the relationship read that
    /// repairs the stored counts; the verification flag is cleared only if
    /// no deletion landed while that read ran (every deletion invalidates,
    /// so `generation` is the witness).
    func storeWisdom(_ snapshot: WisdomCountsSnapshot, for container: ModelContainer,
                     ifGeneration expected: Int, verified: Bool) {
        guard generation == expected, self.container === container || self.container == nil else { return }
        self.container = container
        wisdom = Stamped(value: snapshot, at: .now)
        // `verified` is informational now: the flag is read and cleared
        // BEFORE a verifying probe starts (see `fillWisdom`).
        _ = verified
    }

    func storeQuizRow(_ counts: QuizBookRowCounts, bookID: UUID, for container: ModelContainer, ifGeneration expected: Int) {
        guard generation == expected, self.container === container || self.container == nil else { return }
        self.container = container
        quizRows[bookID] = counts
    }

    // MARK: Shared fills

    /// One probe per question at a time. The tab's own `.task` and the
    /// launch warm both want the same counts; on the first launch after 61,
    /// with every `Theme.cachedHighlightCount` still nil, two Wisdom probes
    /// running at once each walked the whole join in their own context --
    /// twice the peak memory on a compact phone. Callers await the fill
    /// that is already running instead of starting a second one.
    private var quizFill: Task<QuizHomeCounts, Never>?
    private var quizFillID = 0
    private var wisdomFill: Task<WisdomCountsSnapshot, Never>?
    private var wisdomFillID = 0
    private var wisdomFillKey = ""

    func fillQuiz(container: ModelContainer, now: Date = .now) async -> QuizHomeCounts {
        if let quizFill { return await quizFill.value }
        quizFillID += 1
        let id = quizFillID
        let task = Task<QuizHomeCounts, Never> {
            await QuizHomeProbe(modelContainer: container).counts(now: now)
        }
        quizFill = task
        let value = await task.value
        if quizFillID == id { quizFill = nil }
        return value
    }

    /// The verification flag is read AND CLEARED before the probe starts:
    /// a deletion that lands while it runs re-arms the flag (every deletion
    /// does), so the next fill verifies again. Read after the probe, a
    /// deletion in the last main-actor hop went unverified.
    func fillWisdom(container: ModelContainer, excludedRaw: String, includedRaw: String) async -> WisdomCountsSnapshot {
        let key = excludedRaw + "|" + includedRaw
        if let wisdomFill, wisdomFillKey == key { return await wisdomFill.value }
        wisdomFillID += 1
        let id = wisdomFillID
        wisdomFillKey = key
        let verify = themeCountsNeedVerification
        if verify { UserDefaults.standard.set(false, forKey: Self.verificationKey) }
        let task = Task<WisdomCountsSnapshot, Never> {
            await WisdomProbe(modelContainer: container)
                .countsSnapshot(excludedRaw: excludedRaw, includedRaw: includedRaw, verifyCache: verify)
        }
        wisdomFill = task
        let value = await task.value
        if wisdomFillID == id { wisdomFill = nil }
        return value
    }

    // MARK: Warming

    /// Fills whatever is empty after `delay`, replacing any pending warm.
    /// The call site that matters is `ContentView`'s launch chain; every
    /// invalidation re-schedules it.
    func scheduleWarm(container: ModelContainer, after delay: Duration = TabWarmCache.launchDelay) {
        if self.container !== container {
            quiz = nil
            wisdom = nil
            quizRows = [:]
        }
        self.container = container
        warmTask?.cancel()
        warmTask = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            // Never while a seed/upgrade merge is writing (the Build-5
            // crash class), never in the background, never under the
            // shell's own warm-up. Re-checked at the moment of use.
            while SeedingStatus.shared.isSeeding || !Self.appIsActive || self.shellWarmUpInFlight {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            await self.warm(container: container)
        }
    }

    /// Drops everything; rebuilds after `delay` when a store is known.
    func invalidate(rebuildAfter delay: Duration) {
        generation += 1
        quiz = nil
        wisdom = nil
        quizRows = [:]
        guard let container else { return }
        scheduleWarm(container: container, after: delay)
    }

    /// Cheapest first, and each step re-checks the world before it runs:
    /// the Quiz counts (four `COUNT`s and the answer records), then Wisdom's
    /// (one `Theme` fetch of stored columns), then the shelf's first rows
    /// (the only step that faults highlight rows, bounded by
    /// `rowWarmBudget`). A step whose result arrives after an invalidation
    /// is discarded; the re-warm that invalidation scheduled fills it.
    private func warm(container: ModelContainer) async {
        let now = Date.now
        if quiz == nil {
            guard Self.mayRead(self, container: container) else { return }
            let expected = generation
            let counts = await fillQuiz(container: container, now: now)
            guard !Task.isCancelled, generation == expected, self.container === container else { return }
            quiz = Stamped(value: counts, at: now)
        }
        if wisdom == nil {
            guard Self.mayRead(self, container: container) else { return }
            let expected = generation
            let excludedRaw = UserDefaults.standard.string(forKey: BookSourceFilter.excludedKey) ?? ""
            let includedRaw = UserDefaults.standard.string(forKey: BookSourceFilter.includedKey) ?? ""
            let snapshot = await fillWisdom(container: container, excludedRaw: excludedRaw, includedRaw: includedRaw)
            guard !Task.isCancelled, generation == expected, self.container === container else { return }
            wisdom = Stamped(value: snapshot, at: now)
        }
        if quizRows.isEmpty {
            guard Self.mayRead(self, container: container) else { return }
            let expected = generation
            // A fresh probe, released with this call: the highlight rows it
            // registers walking the first books do not stay resident on
            // any phone, compact or not.
            let rows = await QuizBookRowProbe(modelContainer: container)
                .firstScreenCounts(limit: Self.rowWarmBudget, now: now)
            guard !Task.isCancelled, generation == expected, self.container === container else { return }
            quizRows = rows
        }
    }

    private static func mayRead(_ cache: TabWarmCache, container: ModelContainer) -> Bool {
        !Task.isCancelled && !SeedingStatus.shared.isSeeding && appIsActive && cache.container === container
    }

    private static var appIsActive: Bool {
        #if canImport(UIKit)
        // Not `scenePhase`: a process-wide cache has no view to read it
        // from. `applicationState` is the same fact for a single-scene app.
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }

    // MARK: The save listener's reading of the payload

    /// `SemanticVectorCache.touchesHighlights`' defensive reading:
    /// identifiers under the enum key or its raw string, as an array or a
    /// set; a payload with no identifier lists, or one that says everything
    /// was invalidated, counts as touching. A needless re-warm costs
    /// background time; a stale count is a wrong number on screen.
    nonisolated static func touchesWatchedTables(_ note: Notification) -> Bool {
        guard let info = note.userInfo else { return true }
        if identifiers(in: info, for: .invalidatedAllIdentifiers) != nil { return true }
        var sawAnyKey = false
        for key in [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers] {
            guard let ids = identifiers(in: info, for: key) else { continue }
            sawAnyKey = true
            if ids.contains(where: { watchedEntities.contains($0.entityName) }) { return true }
        }
        return !sawAnyKey
    }

    /// Whether the save deleted rows that a stored theme count could have
    /// counted. Same conservatism: an unreadable payload reads as yes.
    nonisolated static func deletesHighlightRows(_ note: Notification) -> Bool {
        guard let info = note.userInfo else { return true }
        if identifiers(in: info, for: .invalidatedAllIdentifiers) != nil { return true }
        guard let deleted = identifiers(in: info, for: .deletedIdentifiers) else { return false }
        return deleted.contains { $0.entityName == "Highlight" || $0.entityName == "Book" }
    }

    private nonisolated static func identifiers(in info: [AnyHashable: Any],
                                                for key: ModelContext.NotificationKey) -> [PersistentIdentifier]? {
        let value = info[key] ?? info[key.rawValue]
        if let array = value as? [PersistentIdentifier] { return array }
        if let set = value as? Set<PersistentIdentifier> { return Array(set) }
        return nil
    }

    // MARK: The write-back gate

    /// Raised by `WisdomProbe` around the save that repairs
    /// `Theme.cachedHighlightCount`, on the probe's own thread, so the
    /// listener above -- which runs synchronously inside that save -- can
    /// tell the repair from a real change and leave the cache alone. A lock,
    /// not an actor: the listener is not on any actor.
    nonisolated static let writeBackGate = ThemeCountWriteBackGate()
}

/// See `TabWarmCache.writeBackGate`. Top-level on purpose: it is raised on
/// `WisdomProbe`'s executor and read inside the save notification, neither
/// of which is the main actor, so it must not live under the cache's
/// `@MainActor`. `NSLock`, the lock this codebase already uses
/// (`SemanticVectorCache`, `DiagnosticLog`).
final class ThemeCountWriteBackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var depth = 0

    var isWritingBack: Bool {
        lock.lock()
        defer { lock.unlock() }
        return depth > 0
    }

    func withWriteBack<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        depth += 1
        lock.unlock()
        defer {
            lock.lock()
            depth -= 1
            lock.unlock()
        }
        return try body()
    }
}
