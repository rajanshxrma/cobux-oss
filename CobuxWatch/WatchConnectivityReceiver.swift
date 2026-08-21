import Foundation
import WatchConnectivity
import WidgetKit
import Observation

/// Watch-side half of the transport. Decodes the `WatchPayload` the phone pushes via
/// `updateApplicationContext`, writes the streak fields into this App Group's *watch-local*
/// copy of `StreakTracker`'s exact keys (so `StreakTracker.currentStreak` — compiled unmodified
/// into this target — reads the synced value), stores the full payload for the widget
/// provider, and reloads the complication timelines. Read-only: this app never sends anything
/// back to the phone.
@Observable
final class WatchConnectivityReceiver: NSObject, WCSessionDelegate {
    private(set) var latestPayload: WatchPayload?
    private let defaults = UserDefaults(suiteName: "group.com.rajansharma.Cobux") ?? .standard
    private var didActivate = false

    func activateIfNeeded() {
        guard WCSession.isSupported(), !didActivate else { return }
        didActivate = true
        latestPayload = WatchPayload.loadCached(from: defaults)
        let session = WCSession.default
        session.delegate = self
        session.activate()

        // `didReceiveApplicationContext` only fires for a NEW push delivered while
        // this delegate is attached -- it does nothing for context the phone
        // already delivered to the session before this watch process activated
        // (e.g. the watch app was killed and relaunched, or this is the first
        // activation since the phone's last sync). `receivedApplicationContext`
        // is WatchConnectivity's own durable record of the last-delivered
        // context regardless of process lifetime -- reading it here is what
        // makes a freshly (re)launched watch app show real data on its very
        // first screen instead of the App-Group disk cache's possibly-stale
        // snapshot (or nothing, on a device that's never synced to disk yet).
        applyContext(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        applyContext(applicationContext)
    }

    private func applyContext(_ applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchPayloadKeys.payloadData] as? Data,
              let payload = try? JSONDecoder().decode(WatchPayload.self, from: data) else { return }

        defaults.set(data, forKey: WatchPayloadKeys.payloadData)
        defaults.set(payload.streakCount, forKey: StreakTracker.currentStreakKey)
        if let lastActive = payload.streakLastActiveDate {
            defaults.set(lastActive, forKey: StreakTracker.lastActiveDateKey)
        }

        DispatchQueue.main.async { [weak self] in
            self?.latestPayload = payload
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
