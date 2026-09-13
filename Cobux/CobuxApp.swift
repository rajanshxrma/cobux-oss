import SwiftUI
import SwiftData
import WidgetKit

@main
struct CobuxApp: App {
    init() {
        // Register for MetricKit crash diagnostics as early as possible —
        // iOS delivers a crash's diagnostic payload on the launch AFTER the
        // crash, so the subscriber must exist before anything else can fail.
        CrashReportCollector.shared.start()

        // Must exist before the app finishes launching, which is why it is
        // here rather than in a `.task`. Without it iOS silently discards
        // every local notification that fires while Cobux is open — the
        // reason "Cobux AI is back" has never appeared for anyone. See
        // `NotificationPresenter` for what it does and does not present.
        NotificationPresenter.shared.install()

        // Set here, synchronously, in `init()` — before `body` is ever
        // evaluated and before any view's `.task` anywhere in the app could
        // possibly start — rather than relying on SwiftUI's `.task`
        // scheduling order between two independently-created tasks (this
        // one and `ContentView`'s own launch `.task`, which reads this same
        // flag). `App` conformance is `@MainActor`-isolated by inference
        // (confirmed by `CrashReportCollector.shared.start()` above already
        // running here with no `await`/`MainActor.run`), so this is a plain
        // synchronous main-actor write, not a race with anything. `body`'s
        // own `.task` still does the ACTUAL seeding work and resolves this
        // back to `false` once it determines there's nothing to mutate —
        // this only closes the window where it could ever read `false`
        // while a mutating pass is about to start.
        // Only claim "seeding" when this launch can actually MUTATE the store.
        //
        // This used to be unconditional, for a real reason: build 5 crashed
        // when an upgrade's mutating merge (1,597 Figure inserts, field
        // rewrites across 8 model types) landed on the main context while the
        // UI was already rendering against it, so every launch was gated to be
        // safe. The cost was that every launch also showed "Setting up your
        // library…" over Flow until a full pass of guarded no-op table scans
        // finished -- which is what Rajan is looking at, and his ask is
        // absolute: he never wants to see it, and no user should either.
        //
        // A persisted content version settles it without giving up the guard.
        // It is a UserDefaults integer read, so it resolves synchronously in
        // `init` with no fetch and no suspension: if this build's seed content
        // has already been applied to this install, the pass below is a no-op
        // by construction and there is nothing to gate. Ship new seed books or
        // a new migration -> bump `seedContentVersion` -> the gate comes back
        // for exactly the launch that needs it.
        SeedingStatus.shared.isSeeding =
            UserDefaults.standard.integer(forKey: Self.seedContentVersionKey) != Self.seedContentVersion

        // Before anything reads the streak: don't let OUR crashes cost HIS
        // streak. Builds 25-30 crashed on launch for days, which silently
        // reset a real streak because the app couldn't be opened at all.
        StreakTracker.forgiveStreakBreakFromCrashes(CrashReportCollector.crashDates())

        // Before any view binds the ambient toggle, and before any stamp is
        // built: carry an already-made "on" into the store that is now the only
        // one read. Two synchronous `UserDefaults` reads on a key that is
        // absent for almost everyone, and a no-op on every launch after the
        // first. See `AmbientContextService.migrateEnabledFlagIfNeeded` for the
        // bug this repairs -- without it, fixing the store would have quietly
        // switched the feature back off for the one person who had turned it
        // on, and he would have reported it a second time.
        AmbientContextService.migrateEnabledFlagIfNeeded()
    }

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @AppStorage("themePreference") private var themeRaw: String = ThemePreference.system.rawValue

    var sharedModelContainer: ModelContainer = {
        let (container, isDegraded) = ModelContainerFactory.make()
        if isDegraded {
            DiagnosticLog.log("store degraded: falling back to in-memory container")
            Task { @MainActor in StoreHealthStatus.shared.isDegraded = true }
        }
        return container
    }()

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    ContentView()
                        // `.onAppear` can fire more than once for the same view instance
                        // (SwiftUI re-diffing, tab/transition edge cases) with no built-in
                        // dedup -- that let two `seedDatabase` passes run concurrently,
                        // each on its own background `ModelContext`, both inserting the
                        // same seed books ("duplicate Book rows with identical titles").
                        // `.task` only (re)starts when its identity changes and SwiftUI
                        // itself won't double-invoke it for an unchanged view, and
                        // `SeedGate` below is a second, explicit belt-and-braces guard so
                        // this can't recur even if some future edge case re-triggers it.
                        //
                        // `isSeeding` is already `true` by the time this runs -- set
                        // synchronously in `init()` above, before `body` (and therefore
                        // this `.task`, and every other `.task` in the app) is ever
                        // evaluated. See `init()`'s doc comment for why that's the real
                        // fix, not just this `.task` setting it early.
                        .task {
                            await Self.seedDatabase(container: sharedModelContainer)
                        }
                } else {
                    OnboardingView()
                }
            }
            .preferredColorScheme(ThemePreference(rawValue: themeRaw)?.colorScheme)
        }
        .modelContainer(sharedModelContainer)
    }

    /// Explicit single-flight guard for `seedDatabase`. `.task` above already makes
    /// re-entrancy unlikely, but this makes it structurally impossible: a second call
    /// while one is in flight returns immediately instead of racing a second background
    /// `ModelContext` against the first's in-flight inserts/repairs.
    actor SeedGate {
        static let shared = SeedGate()
        private var isSeeding = false

        func begin() -> Bool {
            guard !isSeeding else { return false }
            isSeeding = true
            return true
        }

        func end() {
            isSeeding = false
        }
    }

    // Seeding used to run synchronously on the main thread via `mainContext`
    // in `.onAppear`. That was fine at the original scale (a handful of
    // self-help books, ~50 highlights total) but became a real first-launch
    // freeze once the two full medical textbooks were added (~1,300
    // highlights, ~116 chapters) — creating and saving that many model
    // objects plus the ID-repair full-table scans is genuinely slow, and
    // blocking the main thread with it froze the UI on every fresh install
    // until it finished. Now the whole pass (seeding, repair, save) runs on
    // a background context; `ContentView`'s `@Query` picks up the results
    // automatically once they land, same as any other store mutation.
    /// Bump whenever seed CONTENT or a migration changes -- new seed books, a
    /// new repair pass, anything that makes `seedDatabase` mutate an install it
    /// has already run against. Forgetting to bump means returning users skip
    /// the new content until a reinstall; bumping unnecessarily costs one
    /// gated launch. Bump when unsure.
    /// Bumped to 2 for the six-book batch (Art of War, The Prince, On Liberty,
    /// Common Sense, Beyond Good and Evil, the Analects).
    ///
    /// This is the whole reason the gate below exists, and forgetting it is
    /// silent: the content pass is skipped on any device that already applied
    /// version 1, so the books would simply never appear on his phone while the
    /// release notes announced them. The gate that made launches fast is the
    /// same gate that makes this bump mandatory -- ship new seed content, bump
    /// this, every time.
    // 4: the six-book batch (Ptah-Hotep, Book of Tea, Arabian Wisdom,
    // Cynic's Breviary, Twilight of the Idols, Al-Ghazzali). Build 51 already
    // stamped 3 onto devices -- without this bump, any phone that launched 51
    // (TestFlight auto-updates internal testers, so that includes the
    // acceptance device) would skip the content pass and silently never seed
    // them. The gate's own contract: bump re-arms it for exactly the launch
    // that ships new content.
    static let seedContentVersion = 4
    static let seedContentVersionKey = "cobux.seed.completedContentVersion"

    // ------------------------------------------------------------------
    // The launch work itself lives on `SeedRunner` (a @ModelActor), NOT on
    // this type -- see its header for the isolation-inference bug that made
    // "background" work here run on the main thread. These shims keep the
    // call sites and the test seams stable; each await hops to the actor's
    // own executor, so from here on "calling it from anywhere" is safe.
    // ------------------------------------------------------------------

    private static func seedDatabase(container: ModelContainer) async {
        await SeedRunner(modelContainer: container).seed(container: container)
    }

    static func backfillEmbeddingsAndReindex(container: ModelContainer) async {
        await SeedRunner(modelContainer: container).backfillHighlightEmbeddingsAndReindex()
    }

    static func backfillPersonalWritingEmbeddings(container: ModelContainer) async {
        await SeedRunner(modelContainer: container).backfillPersonalWritingEmbeddings()
    }

    static func backfillChatEmbeddings(container: ModelContainer) async {
        await SeedRunner(modelContainer: container).backfillChatEmbeddings()
    }

    private static func precacheCoverImages(container: ModelContainer) async {
        await SeedRunner(modelContainer: container).precacheCoverImages()
    }




    // `NLContextualEmbedding` inference is genuinely CPU-heavy per call — fine
    // for a handful of short quotes, but with ~1,300 dense highlights across
    // the two medical textbooks, only yielding once every 150 highlights left
    // long, uninterrupted stretches of ML inference that visibly starved the
    // UI thread (tab switches hanging for minutes after a fresh install).
    // Yielding after EVERY highlight, plus a much smaller batch/save size and
    // a lower `.background` task priority, gives the scheduler far more
    // frequent chances to service UI work in between embedding calls, at the
    // cost of the backfill itself taking a bit longer to finish overall.
    // Not `private` -- `AutoRestoreService` calls this directly after a
    // successful restore, since a restore produces exactly the "rows with a
    // nil embedding" case this already exists to handle, and there's no
    // reason to make a just-recovered library wait for the next cold launch
    // to become fully searchable again.
    /// Set once for anyone who has the medical textbooks -- either because they
    /// chose the exam persona, or because they already had them before the gate
    /// existed. Keyed separately from the persona so switching persona later
    /// never deletes books out from under someone.
    static let medicalSeedKey = "cobux.seed.medicalReference"






    /// Repairs the specific data corruption the re-entrant-seeding bug (fixed by
    /// `SeedGate`) already wrote to some devices: two `Book` rows sharing the same
    /// title, from two concurrent `seedDatabase` passes each independently seeding
    /// the same book. `CitationResolver.resolve`'s `Dictionary(uniqueKeysWithValues:)`
    /// traps on a duplicate title -- that IS the chat crash, firing on every message
    /// once a device has a duplicate. Safe to run on every launch: a store with no
    /// duplicates makes this a single grouped fetch and nothing else.
    ///
    /// The older of a duplicate pair is kept as canonical (first byte-identical
    /// seed content should have landed first). Before deleting a loser, any
    /// highlight carrying a `personalNote` is re-parented onto the canonical book
    /// instead of being cascade-deleted with it -- `personalNote` is the one
    /// field no seed path (`SeedData*.swift`, `SeedLoader.swift`) ever writes, so
    /// a non-empty one is unambiguous evidence of real user authorship. (`isReminder`
    /// was considered and rejected as a signal: seed content sets it explicitly,
    /// true on most highlights, so it doesn't distinguish user content at all.)
    /// Bare seed-duplicate content is deleted along with the loser via the
    /// existing `.cascade` delete rule on `Book.highlights`.
    /// `internal` (not `private`) so a test can seed two same-titled books
    /// directly and assert this repairs them, same testability pattern as
    /// `repairDuplicateIDs` below.
    nonisolated static func dedupeDuplicateBooks(context: ModelContext) {
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        let grouped = Dictionary(grouping: books) { $0.title.lowercased() }

        for (_, group) in grouped where group.count > 1 {
            let sorted = group.sorted { $0.dateAdded < $1.dateAdded }
            guard let canonical = sorted.first else { continue }

            for loser in sorted.dropFirst() {
                for highlight in loser.highlights where !(highlight.personalNote ?? "").isEmpty {
                    highlight.book = canonical
                }
                context.delete(loser)
            }
        }
    }

    /// Repairs `QuizQuestion` rows already corrupted by the `ClozeService`
    /// double-shuffle bug (fixed separately): `correctAnswerIndex` was computed
    /// from an independent `Int.random` shuffle than the one actually stored in
    /// `choices`, so most existing on-device cloze MCQs point at the wrong
    /// answer. Recoverable without regenerating anything -- `explanation` was
    /// always stored as `"Answer: \(card.answer)"`, so the real answer text
    /// survives even on an already-corrupted row; this finds that text's real
    /// position in `choices` and corrects `correctAnswerIndex` to match. Any
    /// row that was already reviewed under the wrong answer key has its FSRS
    /// state reset to fresh (never-reviewed, due now) rather than left with
    /// scheduling built on possibly-wrong grades -- silently leaving that state
    /// in place would be worse than losing the review history. Idempotent
    /// (a row already correct is a no-op), safe on every launch. `internal` for
    /// the same testability reason as the other repair passes.
    nonisolated static func repairClozeAnswerIndices(context: ModelContext) {
        let descriptor = FetchDescriptor<QuizQuestion>(predicate: #Predicate { $0.generationSourceRaw == "cloze" })
        let clozeQuestions = (try? context.fetch(descriptor)) ?? []
        let answerPrefix = "Answer: "

        for question in clozeQuestions {
            guard let storedIndex = question.correctAnswerIndex,
                  question.explanation.hasPrefix(answerPrefix) else { continue }
            let answerText = String(question.explanation.dropFirst(answerPrefix.count))
            guard let realIndex = question.choices.firstIndex(of: answerText), realIndex != storedIndex else { continue }

            question.correctAnswerIndex = realIndex

            if question.fsrsReps > 0 {
                question.fsrsStability = 0
                question.fsrsDifficulty = 0
                question.fsrsReps = 0
                question.fsrsLapses = 0
                question.lastReviewedAt = nil
                question.dueDate = .now
            }
        }
    }

    /// One-time-per-highlight backfill for the `Highlight.chapterRef` relationship
    /// added in 2.0.0 -- resolves the old free-text `chapter` string against the
    /// book's real `Chapter.title`s once, so every future lookup uses the stable
    /// relationship instead of a string match that a chapter rename could silently
    /// break. Only touches highlights that don't have a `chapterRef` yet, so this is
    /// safe to run on every launch (existing backfilled highlights are skipped).
    nonisolated static func backfillChapterRefs(context: ModelContext) {
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        for book in books {
            guard !book.chapters.isEmpty else { continue }
            let chaptersByTitle = Dictionary(book.chapters.map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })
            for highlight in book.highlights where highlight.chapterRef == nil {
                guard let chapterName = highlight.chapter, let chapter = chaptersByTitle[chapterName] else { continue }
                highlight.chapterRef = chapter
            }
        }
    }

    /// One-time-per-question bulk pass calling `FSRSService.migrateIfNeeded` — without this,
    /// a pre-2.0.0 question's Leitner progress only ever migrated to FSRS the moment it was
    /// individually reviewed (`migrateIfNeeded`'s only call site is inside `recordReview`).
    /// That's fine for chapter/book-scoped quizzing, which pools every question in scope
    /// regardless of `dueDate`, but `DailyReviewService.dueQuestions` -- the flagship "home
    /// mode" -- filters out any question with `dueDate == nil`, which is every single
    /// pre-2.0.0 question until it's individually touched. Net effect: existing quiz history
    /// was invisible to Daily Review, contradicting 2.0.0's own changelog promise that
    /// progress "carried over automatically." Safe to run on every launch --
    /// `migrateIfNeeded` already guards on `fsrsReps == 0 && dueDate == nil`, a no-op for any
    /// question already migrated or genuinely new. `internal` (not `private`) so
    /// `MigrationTests` can verify it directly.
    nonisolated static func migrateLeitnerProgressToFSRS(context: ModelContext) {
        let questions = (try? context.fetch(FetchDescriptor<QuizQuestion>())) ?? []
        for question in questions {
            FSRSService.migrateIfNeeded(question)
        }
    }

    /// `internal` (not `private`) so `CobuxAppMigrationTests` can call it directly --
    /// same testability pattern as `ClaudeService.buildRequest`/`SystemContent`.
    nonisolated static func repairDuplicateIDs(context: ModelContext) {
        var seenBookIDs = Set<UUID>()
        for book in (try? context.fetch(FetchDescriptor<Book>())) ?? [] {
            if seenBookIDs.contains(book.id) {
                book.id = UUID()
            }
            seenBookIDs.insert(book.id)
        }

        var seenHighlightIDs = Set<UUID>()
        for highlight in (try? context.fetch(FetchDescriptor<Highlight>())) ?? [] {
            if seenHighlightIDs.contains(highlight.id) {
                highlight.id = UUID()
            }
            seenHighlightIDs.insert(highlight.id)
        }

        var seenThemeIDs = Set<UUID>()
        for theme in (try? context.fetch(FetchDescriptor<Theme>())) ?? [] {
            if seenThemeIDs.contains(theme.id) {
                theme.id = UUID()
            }
            seenThemeIDs.insert(theme.id)
        }

        // `Chapter.id` had the identical bug but was missed when the fix above
        // landed -- its initializer never assigned `self.id` explicitly, so
        // every chapter ever created (not just a migration artifact) shared
        // one schema-level default UUID. This is exactly what collapsed
        // `BookDetailView`'s chapter list down to showing only one chapter per
        // book: SwiftUI's `ForEach`/`Identifiable` diffing treats same-`id`
        // rows as the same item. `QuizQuestion`/`HighlightMemory`/
        // `QuizAttempt`/`QuizAnswerRecord` already had the init-time fix, but
        // never got this backfill pass for rows created before that fix
        // landed -- covering all five here so this can't recur piecemeal
        // again.
        var seenChapterIDs = Set<UUID>()
        for chapter in (try? context.fetch(FetchDescriptor<Chapter>())) ?? [] {
            if seenChapterIDs.contains(chapter.id) {
                chapter.id = UUID()
            }
            seenChapterIDs.insert(chapter.id)
        }

        var seenQuizQuestionIDs = Set<UUID>()
        for question in (try? context.fetch(FetchDescriptor<QuizQuestion>())) ?? [] {
            if seenQuizQuestionIDs.contains(question.id) {
                question.id = UUID()
            }
            seenQuizQuestionIDs.insert(question.id)
        }

        var seenHighlightMemoryIDs = Set<UUID>()
        for memory in (try? context.fetch(FetchDescriptor<HighlightMemory>())) ?? [] {
            if seenHighlightMemoryIDs.contains(memory.id) {
                memory.id = UUID()
            }
            seenHighlightMemoryIDs.insert(memory.id)
        }

        var seenQuizAttemptIDs = Set<UUID>()
        for attempt in (try? context.fetch(FetchDescriptor<QuizAttempt>())) ?? [] {
            if seenQuizAttemptIDs.contains(attempt.id) {
                attempt.id = UUID()
            }
            seenQuizAttemptIDs.insert(attempt.id)
        }

        var seenQuizAnswerRecordIDs = Set<UUID>()
        for record in (try? context.fetch(FetchDescriptor<QuizAnswerRecord>())) ?? [] {
            if seenQuizAnswerRecordIDs.contains(record.id) {
                record.id = UUID()
            }
            seenQuizAnswerRecordIDs.insert(record.id)
        }

        // `Figure.id` is a NEW field (2.2.0, added so chat replies can reference
        // a specific figure by stable id) with the identical schema-default-
        // evaluated-once risk as every field above: `FigureSeedLoader` already
        // inserted 1,597 Figure rows on devices running earlier builds, and
        // SwiftData's lightweight migration backfills a NEW default-valued
        // property by evaluating `= UUID()` once, not per row -- every
        // pre-existing Figure would otherwise collide on one shared id the
        // instant this update installs. Covered here from day one instead of
        // waiting to discover it the way Chapter's version was (see above).
        var seenFigureIDs = Set<UUID>()
        for figure in (try? context.fetch(FetchDescriptor<Figure>())) ?? [] {
            if seenFigureIDs.contains(figure.id) {
                figure.id = UUID()
            }
            seenFigureIDs.insert(figure.id)
        }

        // `PersonalWritingEntry.id` is a brand-new type (2.2.0, personal-writing
        // context feature) with the identical schema-default-evaluated-once risk
        // as every field above. There are zero rows before this ships, but any
        // future migration path (e.g. a device restoring an old store) would hit
        // the same collision the instant more than one row landed under an old
        // schema version -- covered here from day one rather than waiting to
        // discover it later.
        var seenPersonalWritingEntryIDs = Set<UUID>()
        for entry in (try? context.fetch(FetchDescriptor<PersonalWritingEntry>())) ?? [] {
            if seenPersonalWritingEntryIDs.contains(entry.id) {
                entry.id = UUID()
            }
            seenPersonalWritingEntryIDs.insert(entry.id)
        }
    }
}
