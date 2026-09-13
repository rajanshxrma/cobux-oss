import Foundation
import SwiftData
import WatchConnectivity

/// Phone-side half of the Watch companion's data transport. Per Fable's ruling: read-only,
/// phone→watch only, `WCSession.updateApplicationContext` (not `transferUserInfo` — that's
/// reserved for a future watch-to-phone voice-capture feature, not this one). Push points are
/// exactly the four Fable specified: app foreground/background, end of a quiz/review session,
/// after a highlight save — call `sync(books:)` or `sync(modelContext:)` from each.
enum WatchSyncService {
    private static let activator = SessionActivator()
    private static var lastSyncDate: Date?
    /// Guards the one-shot activation retry above so it cannot recurse.
    private static var hasScheduledActivationRetry = false
    /// A coalescing debounce, not a "don't sync too often" cap -- short enough that no genuine
    /// call site (quiz results, a journal save, adding a highlight) ever feels delayed, long
    /// enough to collapse `ContentView`'s own near-simultaneous scenePhase/seeding-transition
    /// calls into one real payload build instead of running the same fetches two or three
    /// times for the same underlying event.
    private static let minimumSyncInterval: TimeInterval = 3

    /// Idempotent — safe to call repeatedly; `WCSession` no-ops a redundant `activate()`.
    static func activateIfNeeded() {
        activator.activateIfNeeded()
    }

    /// The original entry point, kept for the call sites that hold a `books`
    /// array (quiz results, spoken quiz, highlight save, journal save). The
    /// payload no longer walks those books at all -- it needs their
    /// `ModelContext`, which any inserted model carries. An empty array (no
    /// context to reach) still pushes the streak with empty due/quote fields,
    /// exactly what an empty library produced before.
    @MainActor
    static func sync(books: [Book]) {
        sync(modelContext: books.first?.modelContext)
    }

    // @MainActor: every phone-side caller is a SwiftUI view already on the
    // main actor, the context is the main context, and the seeding guard
    // below reads main-actor-isolated `SeedingStatus`.
    @MainActor
    static func sync(modelContext: ModelContext?) {
        // Belt-and-suspenders for the Build-5 crash class: this used to fault
        // every chapter, question, and highlight, which is lethal while the
        // background seed/upgrade merge is mid-transaction. The payload is
        // built from indexed fetches now, but reading across a mutating merge
        // is still not something to do on purpose. Callers gate too, but any
        // future call site added without thinking about the merge window
        // (that's how the crash shipped the first time) stays safe. A skipped
        // sync self-heals — ContentView re-syncs when seeding ends and on
        // every scenePhase change.
        guard !SeedingStatus.shared.isSeeding else { return }  // retries: ContentView's onChange(of: seedingStatus.isSeeding)
        // Activate FIRST. This used to run after the debounce stamp, so the
        // launch-time sync -- the one that fires before WCSession has finished
        // activating -- burned the window and pushed nothing, leaving the
        // complication on "Not synced" until the app was backgrounded and
        // reopened.
        activateIfNeeded()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.isPaired, session.isWatchAppInstalled else { return }
        // Nothing can be sent before activation completes. Retry once rather
        // than dropping the push: this is exactly the cold-launch case.
        guard session.activationState == .activated else {
            guard !hasScheduledActivationRetry else { return }
            hasScheduledActivationRetry = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                hasScheduledActivationRetry = false
                sync(modelContext: modelContext)
            }
            return
        }
        if let lastSyncDate, Date.now.timeIntervalSince(lastSyncDate) < minimumSyncInterval { return }
        // Stamped only once a real push is actually going out, so a call that
        // sends nothing no longer consumes the debounce window.
        lastSyncDate = .now

        let payload = buildPayload(modelContext: modelContext)
        guard let data = try? JSONEncoder().encode(payload) else { return }

        try? session.updateApplicationContext([WatchPayloadKeys.payloadData: data])
    }

    /// Two indexed fetches, in place of `books.flatMap(\.chapters)
    /// .flatMap(\.quizQuestions)` plus `books.flatMap(\.highlights)` -- every
    /// chapter, every question and EVERY HIGHLIGHT faulted onto the main
    /// actor -- 32,125 highlights across 156 seed books
    /// (scripts/check-corpus-scale.py, build 52) -- at launch, on every
    /// scenePhase transition and again when seeding ended, to produce two
    /// counts, a short list of dates and ONE random quote.
    private static func buildPayload(modelContext: ModelContext?) -> WatchPayload {
        let now = Date.now
        let dueDates = scheduledDueDates(modelContext: modelContext)
        let dueNow = dueDates.filter { $0 <= now }.count
        let upcomingDates = dueDates
            .filter { $0 > now }
            .prefix(WatchPayload.maxUpcomingDueDates)

        let featured = randomFeaturedHighlight(modelContext: modelContext)

        return WatchPayload(
            streakCount: StreakTracker.currentStreak,
            streakLastActiveDate: .now,
            dueCount: dueNow,
            upcomingDueDates: Array(upcomingDates),
            quoteText: featured?.text,
            quoteBook: featured?.book?.title,
            quoteCoverColorHex: featured?.book?.coverColorHex,
            generatedAt: now
        )
    }

    /// Every unsuspended, scheduled question's due date, ascending -- one
    /// fetch of one column. Shared with `ContentView.updateEngagementNudges`,
    /// which derives its two counts from the same list, so the Watch's due
    /// count and the phone's badge/nudge can never disagree.
    ///
    /// `chapter != nil` keeps the pool identical to `Collection<Book>
    /// .allQuizQuestions` (chapters' questions), which every other due count
    /// in the app derives from. The predicate uses only the comparison forms
    /// this codebase has already proven against SwiftData's translation
    /// (`== false`, `!= nil` on an attribute, `!= nil` on a to-one
    /// relationship); the date comparison itself happens in Swift on the
    /// returned column. `propertiesToFetch` limits the row to that column.
    static func scheduledDueDates(modelContext: ModelContext?) -> [Date] {
        guard let modelContext else { return [] }
        var descriptor = FetchDescriptor<QuizQuestion>(
            predicate: #Predicate<QuizQuestion> {
                $0.isSuspended == false && $0.dueDate != nil && $0.chapter != nil
            }
        )
        descriptor.propertiesToFetch = [\.dueDate]
        let scheduled = (try? modelContext.fetch(descriptor)) ?? []
        return scheduled.compactMap(\.dueDate).sorted()
    }

    /// One random highlight that belongs to a book: a COUNT, then a fetch of
    /// exactly one row at a random offset. `book != nil` matches the old
    /// `books.flatMap(\.highlights)` pool, which by construction never held an
    /// unsorted (book-less) highlight.
    private static func randomFeaturedHighlight(modelContext: ModelContext?) -> Highlight? {
        guard let modelContext else { return nil }
        let attached = FetchDescriptor<Highlight>(predicate: #Predicate<Highlight> { $0.book != nil })
        guard let total = try? modelContext.fetchCount(attached), total > 0 else { return nil }
        var pick = attached
        pick.fetchOffset = Int.random(in: 0..<total)
        pick.fetchLimit = 1
        return try? modelContext.fetch(pick).first
    }

    /// `WCSessionDelegate` requires an `NSObject` subclass — this is the smallest possible
    /// wrapper, since `WatchSyncService` itself stays a plain `enum` (no instance state beyond
    /// "has the session been activated").
    private final class SessionActivator: NSObject, WCSessionDelegate {
        private var didActivate = false

        func activateIfNeeded() {
            guard WCSession.isSupported(), !didActivate else { return }
            didActivate = true
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }

        func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

        #if os(iOS)
        func sessionDidBecomeInactive(_ session: WCSession) {}
        func sessionDidDeactivate(_ session: WCSession) {
            session.activate()
        }
        #endif
    }
}
