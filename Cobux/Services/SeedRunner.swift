import CoreSpotlight
import Foundation
import SwiftData
import SwiftUI
import UIKit
import WidgetKit

/// The launch-work actor: seeding, repairs, embedding backfills, cover
/// prefetch. Everything here used to be a static on `CobuxApp` -- and that
/// placement was the single root cause of every "first run is laggy" report
/// this app has had, Amal's included.
///
/// The mechanism, because it must never be rebuilt by accident: SwiftUI's
/// `App` protocol is `@MainActor`, and Swift infers that isolation onto every
/// member of a conforming type, statics included. So `seedDatabase` and all
/// four "background" backfills were main-actor functions -- and wrapping the
/// CALLS in `Task.detached` bought nothing, because awaiting a main-actor
/// function hops straight back to the main actor. The "background
/// ModelContext" comments confused where the DATA lived with where the CODE
/// ran: the context was background; every instruction executed on the main
/// thread. A fresh install decoded 6MB of JSON, built ~13,200 model rows, and
/// ran 12,019 NL embedding inferences ON THE UI THREAD, sliced only by
/// yields.
///
/// `@ModelActor` is SwiftData's own answer: this actor owns a serial executor
/// OFF the main thread and a `modelContext` confined to it, so the work is
/// off-main and the context never crosses actors -- the Build-5 crash class
/// is impossible here by construction, not by discipline.
///
/// The repair helpers stay as `nonisolated` statics on `CobuxApp` (tests call
/// them directly); calling them from here keeps their execution on this
/// actor's executor.
@ModelActor
actor SeedRunner {
    /// Version stamp for the REPAIR pass -- everything in `seed` after
    /// `dedupeDuplicateBooks`. Same contract as `CobuxApp.seedContentVersion`:
    /// written only after a successful save, so a crash or a failed save
    /// leaves the gate armed; bump it whenever a repair is added or changed
    /// so the launch that ships the change re-runs the pass once. The repairs
    /// also re-run automatically on any launch that ran the CONTENT pass,
    /// because new seed rows need `backfillChapterRefs` (seeds carry only the
    /// free-text chapter name).
    ///
    /// Why a gate at all: `repairDuplicateIDs` is ten full-table fetches,
    /// `backfillChapterRefs` faults every book's chapters AND highlights,
    /// `migrateLeitnerProgressToFSRS` walks every question -- on EVERY launch,
    /// against a store they had already repaired. Against the real library --
    /// 32,125 highlights across 156 seed books
    /// (`scripts/check-corpus-scale.py`, build 52) -- that is seconds of
    /// background I/O per launch to produce no change.
    /// `dedupeDuplicateBooks` stays ungated: it is one grouped fetch of ~60
    /// rows, and it repairs the duplicate-title state that crashes chat on
    /// every message.
    static let repairPassVersion = 1
    static let repairPassVersionKey = "cobux.seed.completedRepairVersion"

    /// Version stamp for the Spotlight index. The full rebuild deletes the
    /// whole domain and re-indexes every highlight; it used to run on EVERY
    /// launch, unconditionally, after the highlight backfill -- one
    /// `CSSearchableItem` per highlight, 32,125 of them, built and written
    /// for no change. Now it runs when
    /// the library actually changed this launch (content pass or repairs ran:
    /// new rows, or ids rewritten under Spotlight's identifiers) or when this
    /// stamp is missing/old (first launch of a build that changes the index
    /// shape -- bump to force one rebuild). Per-highlight add/delete paths
    /// keep the index current in between.
    static let spotlightIndexVersion = 1
    static let spotlightIndexVersionKey = "cobux.spotlight.indexedVersion"

    func seed(container: ModelContainer) async {
        guard await CobuxApp.SeedGate.shared.begin() else { return }
        defer { Task { await CobuxApp.SeedGate.shared.end() } }

        let context = modelContext
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
        // 32,125 highlights across 156 seed books" case a fresh install
        // actually needs (`scripts/check-corpus-scale.py`, build 52).
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
        // The CONTENT pass. It has to run when this build's seed content has
        // not been applied to this install yet, and it is pure waste on every
        // launch after that. Repairs have their own gate -- see below.
        //
        // `init()` already states this as fact -- "if this build's seed content
        // has already been applied to this install, the pass below is a no-op
        // by construction" -- but it wasn't one. `seedAllBundledBooks` read and
        // JSON-decoded all 54 bundled books, 5.6MB, on EVERY launch, then ran a
        // title-predicate fetch per book, then five migration passes that each
        // fetch and walk the whole store. On a device where the work is already
        // done, all of it produces no change. Rajan: "the app when installed in
        // new builds it is very slow."
        //
        // The gate is the version key itself, which is written only after a
        // full successful pass -- so a crash or an early return part-way
        // through leaves it armed and the next launch redoes the work. Bumping
        // `seedContentVersion` re-arms it for exactly the launch that ships new
        // content, which is the mechanism that was always intended.
        let seedContentAlreadyApplied =
            UserDefaults.standard.integer(forKey: CobuxApp.seedContentVersionKey) == CobuxApp.seedContentVersion
        let contentPassRan = isFirstRun || !seedContentAlreadyApplied
        if contentPassRan {
        if UserPersona(rawValue: UserDefaults.standard.string(forKey: UserPersona.storageKey) ?? "") == .exam
            || UserDefaults.standard.bool(forKey: CobuxApp.medicalSeedKey) {
            SeedData.seedMicrobiology(modelContext: context)
            SeedData.seedRobbins(modelContext: context)
            FigureSeedLoader.seedBundledFigures(modelContext: context)
            UserDefaults.standard.set(true, forKey: CobuxApp.medicalSeedKey)
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
            UserDefaults.standard.set(true, forKey: CobuxApp.medicalSeedKey)
        }
        if UserDefaults.standard.bool(forKey: CobuxApp.medicalSeedKey) {
            if !existingTitles.contains("Essentials of Medical Microbiology") {
                SeedData.seedMicrobiology(modelContext: context)
            }
            if !existingTitles.contains("Robbins & Cotran Pathologic Basis of Disease") {
                SeedData.seedRobbins(modelContext: context)
            }
        }

        } // end of the gated CONTENT pass
        //
        // The one repair that is deliberately OUTSIDE every gate. It is the
        // safety net for a state that corrupts a store after seeding has been
        // marked done -- duplicate titles make `CitationResolver.resolve` trap
        // and crash chat on every single message. Gating a real crash-repair
        // behind "already applied" would trade it for a few milliseconds; and
        // it IS a few milliseconds: one grouped fetch of ~60 book rows, with
        // relationship faults only for an actual duplicate.

        // Devices that already ran the re-entrant-seeding bug (fixed by `SeedGate`
        // above) may already carry duplicate `Book` rows sharing a title -- most
        // urgently because `CitationResolver.resolve`'s `Dictionary(uniqueKeysWithValues:)`
        // traps on a duplicate title, crashing chat on every single message. This
        // repairs devices build 5 already affected, not just future launches.
        CobuxApp.dedupeDuplicateBooks(context: context)

        // The EXPENSIVE repairs, gated on `repairPassVersion` (see its doc
        // comment). They are one-time-per-row passes by design ("safe to run
        // on every launch" in their own doc comments meant idempotent, not
        // free), and each one walks a whole table -- or every relationship of
        // every book -- to find nothing on a store it already repaired. They
        // re-run whenever the content pass ran (new seed rows need
        // `backfillChapterRefs`) and whenever this stamp is missing or old.
        // Restored backups take the same repair through
        // `backfillHighlightEmbeddingsAndReindex`, which `AutoRestoreService`
        // already awaits after an import.
        let repairsAlreadyApplied =
            UserDefaults.standard.integer(forKey: Self.repairPassVersionKey) == Self.repairPassVersion
        let repairsRan = contentPassRan || !repairsAlreadyApplied
        if repairsRan {
            DiagnosticLog.log("seed: running repair pass (contentPassRan=\(contentPassRan))")
            CobuxApp.repairClozeAnswerIndices(context: context)

            // `Book.id`/`Highlight.id`/`Theme.id` used to rely on a `= UUID()` property
            // default, which SwiftData evaluates once at schema-definition time rather
            // than per instance — every existing row ended up sharing the same UUID,
            // which collapses SwiftUI's `ForEach`/`Identifiable` diffing down to a
            // single visible item even though every row is genuinely present in the
            // store. The model initializers now assign `id` explicitly so this can't
            // recur, but rows written before that fix still carry the duplicate value
            // and need a one-time repair.
            CobuxApp.repairDuplicateIDs(context: context)
            CobuxApp.backfillChapterRefs(context: context)
            CobuxApp.migrateLeitnerProgressToFSRS(context: context)
        }

        // The version keys below are gated on THIS save having succeeded. The
        // old code swallowed the error and recorded the content version
        // anyway, which on a fresh install with a failed ~13k-row save (disk
        // full is realistic on this device) marked an EMPTY library as fully
        // seeded -- permanently, silently, until reinstall. The comments
        // promising "recorded only after a full successful pass" were true
        // for crashes and early returns, and false for the one failure the
        // do/catch was written to witness.
        var saveSucceeded = true
        do {
            try context.save()
        } catch {
            saveSucceeded = false
            DiagnosticLog.log("seed save FAILED: \(error)")
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
        // Recorded only after a full successful pass, so a crash or an early
        // return partway through leaves the gate armed for the next launch
        // rather than marking half-applied content as done.
        if saveSucceeded {
            UserDefaults.standard.set(CobuxApp.seedContentVersion, forKey: CobuxApp.seedContentVersionKey)
            if repairsRan {
                UserDefaults.standard.set(Self.repairPassVersion, forKey: Self.repairPassVersionKey)
            }
        }
        DiagnosticLog.log("seed finished, saveSucceeded=\(saveSucceeded), repairsRan=\(repairsRan)")

        #if DEBUG
        let finalBooks = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        print("Cobux seedDatabase: \(finalBooks.count) book(s) in store: \(finalBooks.map(\.title))")
        #endif

        await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }

        // Embedding generation (on-device NL inference, one call per highlight)
        // and Spotlight indexing are cheap for a handful of highlights but
        // CPU-heavy enough at reference-book scale (thousands of highlights,
        // e.g. the medical textbooks) to freeze first launch if run inline
        // here. Both now happen off the main thread, batched with an
        // incremental save so a mid-way kill just resumes next launch
        // (already-embedded highlights are skipped). `SearchService` already
        // degrades to keyword matching for any highlight without a vector yet,
        // so chat stays usable while this runs in the background.
        // ONE background task, running these in sequence -- not three racing.
        //
        // On a fresh install all three are at their most expensive at exactly
        // the same moment: 32,125 highlights to embed (156 seed books;
        // `scripts/check-corpus-scale.py`, build 52), the same 32,125 to
        // hand to Spotlight, and 60 covers to fetch. Three detached tasks meant
        // they competed with each other AND with the person trying to use a
        // brand-new app. Amal's first launch was "really laggy", and this is
        // the whole reason: a first install pays every cost at once.
        //
        // Sequencing costs nothing real -- none of them is urgent, and the app
        // degrades gracefully without all three (SearchService falls back to
        // keyword matching, covers fall back to a gradient, Spotlight simply
        // has nothing yet) -- but it leaves the device's attention on the user.
        let libraryChanged = contentPassRan || repairsRan
        Task(priority: .background) {
            // A first run gets a head start before any of this begins. The
            // first minute of a new app belongs to the person exploring it,
            // not to indexing they cannot see.
            //
            // Plain `Task`, not `Task.detached`: the methods are isolated to
            // THIS actor, so they run on its executor either way -- which is
            // the entire point of SeedRunner. The old detached wrapper around
            // main-actor statics was theatre; this one is real.
            if isFirstRun { try? await Task.sleep(for: .seconds(20)) }
            // Provenance first: if the embedding model changed under this
            // install, every stored vector is discarded here so the backfills
            // below re-embed under the model queries are now made with. If the
            // discard could not complete, the backfills wait for the launch
            // that finishes it rather than mixing two models in one store.
            guard await self.reconcileEmbeddingModel() else { return }
            await self.backfillHighlightEmbeddings()
            await self.reindexSpotlightIfNeeded(libraryChanged: libraryChanged)
            await self.backfillPersonalWritingEmbeddings()
            await self.backfillChatEmbeddings()
            await self.precacheCoverImages()
        }
    }

    // MARK: - Embedding provenance

    /// Reconciles the per-install embedding-model pin against the model this
    /// process actually embeds with (see `EmbeddingService`'s header for why
    /// a stored vector cannot carry that information itself). Returns whether
    /// the store is consistent with `EmbeddingService.activeModel` and the
    /// backfills may proceed.
    ///
    /// - No model available: nothing to reconcile; vectors and pin are left
    ///   exactly as they are and nothing embeds this launch.
    /// - No pin yet: the first launch of a build that records provenance.
    ///   Older builds chose the model by the same rule this one does, so the
    ///   honest record is the current choice. Vectors that were in fact mixed
    ///   before provenance existed cannot be detected; from here on they can.
    /// - Pin matches: nothing to do.
    /// - Pin differs: `embeddingData` is nulled across all three tables in
    ///   bounded pages, each page saved, and the pin is rewritten only once
    ///   every table finished -- so a kill or a failed save mid-way leaves
    ///   the pin pointing at the OLD model and the next launch resumes the
    ///   discard rather than trusting a half-cleared store.
    func reconcileEmbeddingModel() async -> Bool {
        guard EmbeddingService.isAvailable else {
            DiagnosticLog.log("embedding: no on-device model available; nothing embeds this launch")
            return false
        }
        guard EmbeddingService.storedVectorsAreStale() else {
            EmbeddingService.pinActiveModel()
            return true
        }
        let previous = EmbeddingService.pinnedModelID ?? "none"
        let current = EmbeddingService.activeModel.rawValue
        DiagnosticLog.log("embedding model changed \(previous) -> \(current); discarding stored vectors")

        let highlights = await discardVectors(
            FetchDescriptor<Highlight>(predicate: #Predicate { $0.embeddingData != nil })
        ) { $0.embeddingData = nil }
        let writing = await discardVectors(
            FetchDescriptor<PersonalWritingEntry>(predicate: #Predicate { $0.embeddingData != nil })
        ) { $0.embeddingData = nil }
        let chat = await discardVectors(
            FetchDescriptor<ChatMessage>(predicate: #Predicate { $0.embeddingData != nil })
        ) { $0.embeddingData = nil }

        let discarded = highlights.count + writing.count + chat.count
        guard highlights.finished, writing.finished, chat.finished else {
            DiagnosticLog.log("embedding: discard incomplete after \(discarded) rows; pin stays \(previous) so the next launch finishes")
            return false
        }
        EmbeddingService.pinActiveModel()
        DiagnosticLog.log("embedding: discarded \(discarded) stored vectors; pinned to \(current)")
        return true
    }

    /// Nulls one table's vectors in pages of 500, saving each page. Every row
    /// a page clears leaves the predicate's result set, so the loop advances
    /// by construction; a failed save would hand the same page back forever,
    /// so it ends the pass instead (reported as unfinished).
    private func discardVectors<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        clear: (T) -> Void
    ) async -> (count: Int, finished: Bool) {
        var count = 0
        while true {
            var page = descriptor
            page.fetchLimit = 500
            let batch: [T]
            do {
                batch = try modelContext.fetch(page)
            } catch {
                DiagnosticLog.log("embedding: discard fetch failed: \(error)")
                return (count, false)
            }
            if batch.isEmpty { return (count, true) }
            for row in batch { clear(row) }
            do {
                try modelContext.save()
            } catch {
                DiagnosticLog.log("embedding: discard save failed: \(error)")
                return (count, false)
            }
            count += batch.count
            await Task.yield()
        }
    }

    // MARK: - Embedding backfills

    /// Rows embedded per `save()`. It was 25, with the same 120 ms sleep --
    /// and every save re-fires every live `@Query` in all five tabs the shell
    /// keeps alive, so a first-run backfill of the whole library (32,125
    /// highlights across 156 seed books, scripts/check-corpus-scale.py) meant
    /// well over a thousand saves, one every ~120 ms, each re-fetching Flow, Library, Wisdom, Quiz
    /// and More while he was trying to use the app. Eight times fewer saves
    /// for the same work; the sleep between pages is unchanged, so the device
    /// is still handed back between them. The cursor semantics below do not
    /// depend on the page size.
    private static let embeddingBackfillPageSize = 200

    /// The one engine behind all three backfills. It used to be three copies
    /// of the same loop, and all three had the same hang: fetch the first page
    /// of rows with `embeddingData == nil`, embed them, repeat until the fetch is
    /// empty. A row whose text is non-empty but which the model declines
    /// (punctuation-only highlights, a text the contextual model throws on,
    /// memory pressure) was deliberately left nil "so the next launch
    /// retries" -- and the SAME launch immediately re-fetched those same 25
    /// rows and retried them forever, at background priority, taking
    /// `EmbeddingService.inferenceLock` on every attempt, so every chat send
    /// and journal save queued behind a loop that could never end.
    ///
    /// The fix is a cursor: `fetchOffset` is the number of rows this launch
    /// has declined. Embedded rows leave the nil set on their own; declined
    /// rows stay in it and are skipped by the offset. Each batch therefore
    /// removes exactly its size from (nil rows - offset), so the loop ends in
    /// at most ceil(nilRows / pageSize) batches whatever the rows contain, and a
    /// declined row is attempted at most once per launch -- while staying nil
    /// so a later launch does retry it, which is the behaviour the old
    /// comment promised. No sort is requested on purpose: an unsorted fetch
    /// comes back in rowid order, a stable total order that makes the cursor
    /// exact; `dateAdded` would tie across seeded rows and cost a sort per
    /// page. Termination does not depend on the order in any case -- only
    /// how much work is wasted does.
    ///
    /// A failed save also ends the pass (logged): unsaved rows would keep the
    /// in-memory vector, drop out of the fetch, and leave the loop grinding
    /// through the whole table for nothing.
    ///
    /// Cross-model consistency: `embedUncached` embeds with the ONE active
    /// model and returns nil rather than falling back to the other one, so a
    /// declined row is left for keyword search instead of being stored as a
    /// vector no later query can be compared against.
    private func runEmbeddingBackfill<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        text: (T) -> String,
        store: (T, Data) -> Void
    ) async {
        guard EmbeddingService.isAvailable else { return }
        var declined = 0
        while true {
            var page = descriptor
            page.fetchLimit = Self.embeddingBackfillPageSize
            page.fetchOffset = declined
            let batch = (try? modelContext.fetch(page)) ?? []
            if batch.isEmpty { break }
            for row in batch {
                let rowText = text(row)
                if let vector = EmbeddingService.embedUncached(rowText) {
                    store(row, vector.withUnsafeBufferPointer { Data(buffer: $0) })
                } else if rowText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // GENUINELY empty text must leave the nil set for good; an
                    // empty-but-present vector is the honest marker: "tried,
                    // nothing to index". Readers skip empty vectors.
                    store(row, Data())
                } else {
                    // Non-empty text the model declined: a TRANSIENT failure
                    // as far as this launch can tell. Stays nil for a later
                    // launch; the cursor moves past it now.
                    declined += 1
                }
                await Task.yield()
            }
            do {
                try modelContext.save()
            } catch {
                DiagnosticLog.log("embedding backfill save failed: \(error)")
                break
            }
            // A real pause between batches, not just a yield -- the sleep is
            // what hands the device back to the person using it. The ratchet
            // named this for the highlight backfill; the other two had only
            // yields, which was the same bug wearing a smaller table.
            try? await Task.sleep(for: .milliseconds(120))
        }
        if declined > 0 {
            DiagnosticLog.log("embedding backfill: \(declined) \(String(describing: T.self)) row(s) declined this launch; retried next launch")
        }
    }

    func backfillHighlightEmbeddings() async {
        await runEmbeddingBackfill(
            FetchDescriptor<Highlight>(predicate: #Predicate { $0.embeddingData == nil }),
            text: { $0.text },
            store: { $0.embeddingData = $1 }
        )
    }

    func backfillPersonalWritingEmbeddings() async {
        await runEmbeddingBackfill(
            FetchDescriptor<PersonalWritingEntry>(predicate: #Predicate { $0.embeddingData == nil }),
            text: { $0.text },
            store: { $0.embeddingData = $1 }
        )
    }

    func backfillChatEmbeddings() async {
        await runEmbeddingBackfill(
            FetchDescriptor<ChatMessage>(predicate: #Predicate { $0.isUser == true && $0.embeddingData == nil }),
            text: { $0.content },
            store: { $0.embeddingData = $1 }
        )
    }

    /// The post-RESTORE pass, awaited by `AutoRestoreService` (through
    /// `CobuxApp.backfillEmbeddingsAndReindex`) after an iCloud backup lands:
    /// embed the restored rows, resolve their `chapterRef`s, and rebuild
    /// Spotlight unconditionally -- the imported rows are new to this device,
    /// so there is nothing to gate on. `BackupService.importData` builds each
    /// highlight from its DTO with only the free-text chapter name, and the
    /// launch-time repairs that used to resolve it on the next launch are now
    /// gated (see `repairPassVersion`), so a restore does its own repair here
    /// rather than leaving restored highlights un-linked.
    ///
    /// The launch path does NOT use this: `seed` calls
    /// `backfillHighlightEmbeddings` and `reindexSpotlightIfNeeded` separately
    /// so the rebuild can be skipped on the launches that changed nothing.
    func backfillHighlightEmbeddingsAndReindex() async {
        await backfillHighlightEmbeddings()
        CobuxApp.backfillChapterRefs(context: modelContext)
        do {
            try modelContext.save()
        } catch {
            DiagnosticLog.log("post-restore chapterRef save failed: \(error)")
        }
        await rebuildSpotlightIndex()
    }

    // MARK: - Spotlight

    /// See `spotlightIndexVersion`. Skips the rebuild on every launch where
    /// the library did not change and the index stamp is current -- which is
    /// every ordinary launch.
    func reindexSpotlightIfNeeded(libraryChanged: Bool) async {
        let stamped = UserDefaults.standard.integer(forKey: Self.spotlightIndexVersionKey) == Self.spotlightIndexVersion
        guard libraryChanged || !stamped else { return }
        await rebuildSpotlightIndex()
    }

    /// Clears the domain, then pages through the highlight table 500 rows at
    /// a time with `book` prefetched, awaiting Spotlight's confirmation per
    /// page. It used to fetch EVERY highlight into one array (each faulting
    /// `book?.title` one at a time) and hand all 32,125 items to Spotlight at
    /// once (`scripts/check-corpus-scale.py`, build 52).
    /// Paging keeps one page of model objects resident and lets Spotlight's
    /// own completion pace the work. No sort: rowid order is the stable total
    /// order an offset cursor needs (see `runEmbeddingBackfill`). Per-item
    /// add/delete paths keep the index current in between rebuilds, so a
    /// highlight inserted mid-rebuild by the user is simply indexed by its
    /// own path. The stamp is written only after the last page, so a kill
    /// mid-rebuild redoes it next launch.
    func rebuildSpotlightIndex() async {
        guard SpotlightIndexer.isAvailable else { return }
        await SpotlightIndexer.removeAll()
        let pageSize = 500
        var indexed = 0
        while true {
            var page = FetchDescriptor<Highlight>()
            page.fetchLimit = pageSize
            page.fetchOffset = indexed
            page.relationshipKeyPathsForPrefetching = [\.book]
            let batch = (try? modelContext.fetch(page)) ?? []
            if batch.isEmpty { break }
            // Items built HERE, while still isolated to this `@ModelActor`,
            // and only plain values handed across. Passing the rows themselves
            // put every `book?.title`/`.text`/`.chapter`/`.tags` read on the
            // generic executor instead -- see `SpotlightIndexer.indexBatch`.
            let items = batch.map(SpotlightIndexer.makeItem(for:))
            await SpotlightIndexer.indexBatch(items: items)
            indexed += batch.count
            if batch.count < pageSize { break }
            await Task.yield()
        }
        UserDefaults.standard.set(Self.spotlightIndexVersion, forKey: Self.spotlightIndexVersionKey)
        DiagnosticLog.log("spotlight: rebuilt index with \(indexed) highlight(s)")
    }

    /// Free space the cover precache wants before it writes anything.
    /// Covers are a convenience tier (the card falls back to its gradient),
    /// so on a phone this close to full they wait rather than take the last
    /// gigabyte iOS needs for itself. Nothing is deleted to make room.
    private static let precacheRequiredFreeBytes: Int64 = 1_000_000_000

    func precacheCoverImages() async {
        let context = modelContext
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        CoverImageCache.pruneOrphans(validBookIDs: Set(books.map(\.id)))
        // retries: next launch -- `seed(container:)` runs this at the end of
        // every launch's background chain, so a phone that frees space gets
        // its covers on the next open without anyone remembering to ask.
        // `nil` (the volume could not be asked) counts as room.
        if let free = DeviceClass.freeDiskBytes(), free < Self.precacheRequiredFreeBytes {
            DiagnosticLog.log("covers: precache deferred, \(free / 1_000_000) MB free (needs \(Self.precacheRequiredFreeBytes / 1_000_000) MB)")
            return
        }
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
}
