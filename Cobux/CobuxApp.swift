import SwiftUI
import SwiftData
import WidgetKit

@main
struct CobuxApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @AppStorage("themePreference") private var themeRaw: String = ThemePreference.system.rawValue

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Book.self, Highlight.self, Chapter.self, ChatMessage.self, Theme.self, Figure.self,
            QuizQuestion.self, HighlightMemory.self, QuizAttempt.self, QuizAnswerRecord.self
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .identifier("group.com.rajansharma.Cobux")
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    ContentView()
                        .onAppear {
                            let container = sharedModelContainer
                            Task.detached(priority: .userInitiated) {
                                await Self.seedDatabase(container: container)
                            }
                        }
                } else {
                    OnboardingView()
                }
            }
            .preferredColorScheme(ThemePreference(rawValue: themeRaw)?.colorScheme)
        }
        .modelContainer(sharedModelContainer)
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
        let context = ModelContext(container)

        // Only surface the "setting up your library" banner on a genuine
        // first run -- every other launch also calls this function (it's
        // the safety net that re-seeds anything missing), but is a fast
        // no-op against an already-populated store and shouldn't flash a
        // banner the user has no reason to see.
        let isFirstRun = ((try? context.fetch(FetchDescriptor<Book>())) ?? []).isEmpty
        if isFirstRun {
            await MainActor.run { SeedingStatus.shared.isSeeding = true }
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
        SeedData.seedMicrobiology(modelContext: context)
        SeedData.seedRobbins(modelContext: context)
        SeedLoader.seedAllBundledBooks(modelContext: context)

        // Safety net: each seed function above already guards against duplicates
        // by title, but if the underlying store ever changes out from under us
        // (e.g. moving to a new ModelConfiguration/container) a seed can end up
        // silently missing. Re-run any seed whose book didn't make it in.
        let existingTitles = Set(((try? context.fetch(FetchDescriptor<Book>())) ?? []).map(\.title))
        if !existingTitles.contains("Essentials of Medical Microbiology") {
            SeedData.seedMicrobiology(modelContext: context)
        }
        if !existingTitles.contains("Robbins & Cotran Pathologic Basis of Disease") {
            SeedData.seedRobbins(modelContext: context)
        }

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

        if isFirstRun {
            await MainActor.run { SeedingStatus.shared.isSeeding = false }
        }

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
    private static func backfillEmbeddingsAndReindex(container: ModelContainer) async {
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

    private static func repairDuplicateIDs(context: ModelContext) {
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
    }
}
