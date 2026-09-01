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
        SeedingStatus.shared.isSeeding = true

        // Before anything reads the streak: don't let OUR crashes cost HIS
        // streak. Builds 25-30 crashed on launch for days, which silently
        // reset a real streak because the app couldn't be opened at all.
        StreakTracker.forgiveStreakBreakFromCrashes(CrashReportCollector.crashDates())
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
    private actor SeedGate {
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
    private static func seedDatabase(container: ModelContainer) async {
        guard await SeedGate.shared.begin() else { return }
        defer { Task { await SeedGate.shared.end() } }

        let context = ModelContext(container)

        let isFirstRun = ((try? context.fetch(FetchDescriptor<Book>())) ?? []).isEmpty

        // `isSeeding` now gates EVERY launch's mutating pass below, not just a
        // genuine first run. It used to be first-run-only on the theory that
        // every other launch is "a fast no-op against an already-populated
        // store" -- true for row counts, but false for whether the pass
        // MUTATES anything. Build 5's launch crash was exactly this: on an
        // upgrade (not a fresh install), `FigureSeedLoader` inserted 1,597
        // `Figure` rows and `repairDuplicateIDs`/`backfillChapterRefs`
        // rewrote fields across 8 model types -- a real mutating merge that
        // landed on the main context while `LibraryView` was already
        // rendering live against the store. Showing this banner during any
        // launch that might mutate is the cheap half of the fix (the other
        // half is `BookCard` no longer faulting a live relationship read
        // during that window at all -- see its `.task`-based `fetchCount`).
        // On a normal quiescent launch every seed/repair function below is a
        // guarded no-op, so the banner is on-screen only as long as those
        // full-table scans take -- brief, not the multi-second "populate
        // 1,300 highlights" case a fresh install actually needs.
        DiagnosticLog.log("seed started, isFirstRun=\(isFirstRun)")
        // Durable, write-once record of whether THIS install was ever
        // genuinely fresh (empty store) the first time it was ever seeded --
        // `AutoRestoreService` reads this instead of inferring freshness from
        // `AutoBackupService`'s own throttle key, which is absent on every
        // existing install's first launch of a build that ships automatic
        // backup for the first time, not just on a real fresh install.
        // Written once, first launch only -- later launches (where the store
        // already has books, so `isFirstRun` would read `false`) must never
        // overwrite the true original signal.
        let freshInstallKey = "cobux.install.wasFreshOnFirstSeed"
        if UserDefaults.standard.object(forKey: freshInstallKey) == nil {
            UserDefaults.standard.set(isFirstRun, forKey: freshInstallKey)
        }
        // `isSeeding` itself is already `true` -- set synchronously at the call
        // site in `body` above, before this function's first suspension point,
        // specifically to close the race window other launch-time `.task`s
        // could otherwise win. Only the message (which depends on `isFirstRun`,
        // only known after the fetch above) is new information here.
        await MainActor.run {
            SeedingStatus.shared.message = isFirstRun ? "Setting up your library…" : "Syncing your library…"
        }

        // The two large medical reference books stay as hand-written Swift —
        // they already work and are the exact files a JSON-based approach
        // exists to avoid repeating at that density. Every other book is
        // authored as JSON under Resources/SeedBooks/ and loaded generically
        // (this superseded the old `seed12Rules`/`seedBeyondOrder`/
        // `seedAttached`/`seedValueOfOthers` Swift functions, left in
        // `SeedData.swift`/`SeedDataAttached.swift`/`SeedDataValueOfOthers.swift`
        // as unused dead code pending a cleanup pass, rather than risk
        // touching them further tonight).
        // The two medical textbooks (and their 1,597 clinical figures) exist for
        // Rajan's brother, a med student. Every other install was getting them
        // too, so a new user's Library opened on Robbins and Microbiology and
        // their quizzes drew from pathology -- his own note that "a lot of the
        // other people are not gonna be med students... Utkarsh's desires should
        // be a SUBSET of Cobux, and Cobux should cater to the rest generically."
        //
        // Gated on the persona chosen in onboarding rather than removed: the
        // exam path is exactly who they're for, and existing installs keep them
        // because `hasSeededMedicalReference` is set true for anyone who already
        // has them (see the migration below).
        if UserPersona(rawValue: UserDefaults.standard.string(forKey: UserPersona.storageKey) ?? "") == .exam
            || UserDefaults.standard.bool(forKey: Self.medicalSeedKey) {
            SeedData.seedMicrobiology(modelContext: context)
            SeedData.seedRobbins(modelContext: context)
            FigureSeedLoader.seedBundledFigures(modelContext: context)
            UserDefaults.standard.set(true, forKey: Self.medicalSeedKey)
        }
        SeedLoader.seedAllBundledBooks(modelContext: context)

        // Safety net: each seed function above already guards against duplicates
        // by title, but if the underlying store ever changes out from under us
        // (e.g. moving to a new ModelConfiguration/container) a seed can end up
        // silently missing. Re-run any seed whose book didn't make it in.
        let existingTitles = Set(((try? context.fetch(FetchDescriptor<Book>())) ?? []).map(\.title))
        // Migration: anyone who ALREADY has the medical books keeps them, so an
        // existing library never loses content because of the gate above.
        if existingTitles.contains("Robbins & Cotran Pathologic Basis of Disease")
            || existingTitles.contains("Essentials of Medical Microbiology") {
            UserDefaults.standard.set(true, forKey: Self.medicalSeedKey)
        }
        if UserDefaults.standard.bool(forKey: Self.medicalSeedKey) {
            if !existingTitles.contains("Essentials of Medical Microbiology") {
                SeedData.seedMicrobiology(modelContext: context)
            }
            if !existingTitles.contains("Robbins & Cotran Pathologic Basis of Disease") {
                SeedData.seedRobbins(modelContext: context)
            }
        }

        // Devices that already ran the re-entrant-seeding bug (fixed by `SeedGate`
        // above) may already carry duplicate `Book` rows sharing a title -- most
        // urgently because `CitationResolver.resolve`'s `Dictionary(uniqueKeysWithValues:)`
        // traps on a duplicate title, crashing chat on every single message. This
        // repairs devices build 5 already affected, not just future launches.
        dedupeDuplicateBooks(context: context)
        repairClozeAnswerIndices(context: context)

        // `Book.id`/`Highlight.id`/`Theme.id` used to rely on a `= UUID()` property
        // default, which SwiftData evaluates once at schema-definition time rather
        // than per instance — every existing row ended up sharing the same UUID,
        // which collapses SwiftUI's `ForEach`/`Identifiable` diffing down to a
        // single visible item even though every row is genuinely present in the
        // store. The model initializers now assign `id` explicitly so this can't
        // recur, but rows written before that fix still carry the duplicate value
        // and need a one-time repair.
        repairDuplicateIDs(context: context)
        backfillChapterRefs(context: context)
        migrateLeitnerProgressToFSRS(context: context)

        do {
            try context.save()
        } catch {
            #if DEBUG
            print("Cobux seedDatabase: save failed: \(error)")
            #endif
        }

        // `context.save()` only guarantees the write landed in `container`'s
        // SQLite store -- it says NOTHING about whether `container.mainContext`
        // (the context every `@Query` and every `!SeedingStatus.isSeeding` gate
        // in the app is actually trusting) has finished merging that write in.
        // Every gate downstream (`BookDetailView`, `QuizHomeView`,
        // `ContentView`'s WatchSync/nudges pass) was written as if
        // `isSeeding == false` means "safe to fault a relationship now" -- but
        // until this fix, nothing here ever confirmed the merge had actually
        // landed before flipping the flag. That's the SAME crash class as the
        // documented build-5 incident (see `BookCard`'s doc comment), just one
        // layer removed: this build's seed pass is far larger (10 new books,
        // ~2000+ highlights, on top of the existing repair/migration passes
        // above) than build 5's, which widened a previously-rare race into a
        // reliably-every-launch crash. Forcing a fetch through `mainContext`
        // is a real synchronization point -- unlike a relationship fault, a
        // fetch talks to the persistent store directly -- and the two yields
        // give SwiftData's own cross-context merge notification a turn to
        // fully settle before any gated view is allowed to trust the flag.
        await MainActor.run {
            _ = try? container.mainContext.fetch(FetchDescriptor<Book>())
        }
        await Task.yield()
        await Task.yield()

        // Was still gated on `isFirstRun` after the set above became
        // unconditional -- meaning on every non-first-run launch (every
        // returning user, Utkarsh's very first run of THIS build included,
        // since his store already has books) `isSeeding` was set true and
        // never reset, leaving the "Syncing your library…" banner stuck on
        // screen for the entire session, every session. The set and the reset
        // must be symmetric.
        await MainActor.run { SeedingStatus.shared.isSeeding = false }
        DiagnosticLog.log("seed finished")

        #if DEBUG
        let finalBooks = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        print("Cobux seedDatabase: \(finalBooks.count) book(s) in store: \(finalBooks.map(\.title))")
        #endif

        WidgetCenter.shared.reloadAllTimelines()

        // Embedding generation (on-device NL inference, one call per highlight)
        // and Spotlight indexing are cheap for a handful of highlights but
        // CPU-heavy enough at reference-book scale (thousands of highlights,
        // e.g. the medical textbooks) to freeze first launch if run inline
        // here. Both now happen off the main thread, batched with an
        // incremental save so a mid-way kill just resumes next launch
        // (already-embedded highlights are skipped). `SearchService` already
        // degrades to keyword matching for any highlight without a vector yet,
        // so chat stays usable while this runs in the background.
        Task.detached(priority: .background) {
            await Self.backfillEmbeddingsAndReindex(container: container)
        }
        Task.detached(priority: .background) {
            await Self.backfillPersonalWritingEmbeddings(container: container)
        }
        Task.detached(priority: .background) {
            await Self.precacheCoverImages(container: container)
        }
    }

    // Downloads and caches every book's cover image to disk right after
    // seeding, instead of waiting for `BookCard`/`BookDetailView` to
    // lazily trigger it on first render -- see `CoverImageCache`'s doc
    // comment. Skips anything already cached (idempotent across every
    // non-first-run launch, not just a true first run) and anything with
    // no `coverImageURL` at all (nothing to fetch, gradient fallback is
    // already correct for those). Also skips anything with a bundled
    // `Cover-<slug>` asset that actually resolves -- BOTH render paths
    // (`BookCard.swift`, `BookDetailView.swift`) check `coverAssetName`
    // before ever falling back to the remote URL, so most of this app's
    // ~26 books with a bundled cover were downloading and caching a remote
    // image on every fresh install that would never once be read. Uses the
    // exact same `UIImage(named: "Cover-" + assetName) != nil` check those
    // render paths use, not just `coverAssetName != nil` -- a mismatched
    // asset name must still fall through to the remote fetch, same as it
    // falls through to it at render time. Book count here is small enough
    // (a handful of seeded books) that a plain sequential loop is fine --
    // no batching/throttling needed the way the embedding backfill above
    // needs it at highlight scale.
    private static func precacheCoverImages(container: ModelContainer) async {
        let context = ModelContext(container)
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        CoverImageCache.pruneOrphans(validBookIDs: Set(books.map(\.id)))
        for book in books {
            if let assetName = book.coverAssetName, UIImage(named: "Cover-" + assetName) != nil {
                continue
            }
            guard CoverImageCache.cachedImage(for: book.id) == nil,
                  let urlString = book.coverImageURL,
                  let url = URL(string: urlString) else { continue }
            await CoverImageCache.downloadAndCache(bookID: book.id, remoteURL: url)
        }
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

    static func backfillEmbeddingsAndReindex(container: ModelContainer) async {
        let backgroundContext = ModelContext(container)

        let pending = (try? backgroundContext.fetch(
            FetchDescriptor<Highlight>(predicate: #Predicate { $0.embeddingData == nil })
        )) ?? []

        let batchSize = 25
        var start = 0
        while start < pending.count {
            let end = min(start + batchSize, pending.count)
            for highlight in pending[start..<end] {
                if let vector = EmbeddingService.embed(highlight.text) {
                    highlight.embedding = vector
                }
                await Task.yield()
            }
            try? backgroundContext.save()
            await Task.yield()
            start = end
        }

        let allHighlights = (try? backgroundContext.fetch(FetchDescriptor<Highlight>())) ?? []
        SpotlightIndexer.reindexAll(allHighlights)
    }

    /// Same shape as `backfillEmbeddingsAndReindex` above, scoped to
    /// `PersonalWritingEntry` instead of `Highlight`. `PersonalWritingImportService`
    /// already embeds every entry it inserts directly, so in the common case this
    /// is a no-op fast pass over an already-fully-embedded table — the real target
    /// is a `PersonalWritingEntry` restored via `BackupService`, whose DTO
    /// deliberately omits the embedding vector (see its own doc comment) and so
    /// needs it filled in lazily, exactly like a restored `Highlight` does.
    // Not `private` -- same reasoning as `backfillEmbeddingsAndReindex`
    // above, called directly by `AutoRestoreService` after a restore.
    static func backfillPersonalWritingEmbeddings(container: ModelContainer) async {
        let backgroundContext = ModelContext(container)

        let pending = (try? backgroundContext.fetch(
            FetchDescriptor<PersonalWritingEntry>(predicate: #Predicate { $0.embeddingData == nil })
        )) ?? []

        let batchSize = 25
        var start = 0
        while start < pending.count {
            let end = min(start + batchSize, pending.count)
            for entry in pending[start..<end] {
                if let vector = EmbeddingService.embed(entry.text) {
                    entry.embedding = vector
                }
                await Task.yield()
            }
            try? backgroundContext.save()
            await Task.yield()
            start = end
        }
    }

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
    static func dedupeDuplicateBooks(context: ModelContext) {
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
    static func repairClozeAnswerIndices(context: ModelContext) {
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
    private static func backfillChapterRefs(context: ModelContext) {
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
    static func migrateLeitnerProgressToFSRS(context: ModelContext) {
        let questions = (try? context.fetch(FetchDescriptor<QuizQuestion>())) ?? []
        for question in questions {
            FSRSService.migrateIfNeeded(question)
        }
    }

    /// `internal` (not `private`) so `CobuxAppMigrationTests` can call it directly --
    /// same testability pattern as `ClaudeService.buildRequest`/`SystemContent`.
    static func repairDuplicateIDs(context: ModelContext) {
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
