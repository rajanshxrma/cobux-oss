import Foundation
import WatchConnectivity

/// Phone-side half of the Watch companion's data transport. Per Fable's ruling: read-only,
/// phone→watch only, `WCSession.updateApplicationContext` (not `transferUserInfo` — that's
/// reserved for a future watch-to-phone voice-capture feature, not this one). Push points are
/// exactly the four Fable specified: app foreground/background, end of a quiz/review session,
/// after a highlight save — call `sync(books:)` from each.
enum WatchSyncService {
    private static let activator = SessionActivator()

    /// Idempotent — safe to call repeatedly; `WCSession` no-ops a redundant `activate()`.
    static func activateIfNeeded() {
        activator.activateIfNeeded()
    }

    static func sync(books: [Book]) {
        activateIfNeeded()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.isPaired, session.isWatchAppInstalled else { return }

        let payload = buildPayload(books: books)
        guard let data = try? JSONEncoder().encode(payload) else { return }

        try? session.updateApplicationContext([WatchPayloadKeys.payloadData: data])
    }

    private static func buildPayload(books: [Book]) -> WatchPayload {
        let allQuestions = books.flatMap(\.chapters).flatMap(\.quizQuestions)
        let now = Date.now

        let dueNow = allQuestions.filter { !$0.isSuspended && ($0.dueDate.map { $0 <= now } ?? false) }
        let upcomingDates = allQuestions
            .filter { !$0.isSuspended }
            .compactMap(\.dueDate)
            .filter { $0 > now }
            .sorted()
            .prefix(WatchPayload.maxUpcomingDueDates)

        let allHighlights = books.flatMap(\.highlights)
        let featured = allHighlights.randomElement()

        return WatchPayload(
            streakCount: StreakTracker.currentStreak,
            streakLastActiveDate: .now,
            dueCount: dueNow.count,
            upcomingDueDates: Array(upcomingDates),
            quoteText: featured?.text,
            quoteBook: featured?.book?.title,
            quoteCoverColorHex: featured?.book?.coverColorHex,
            generatedAt: now
        )
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
