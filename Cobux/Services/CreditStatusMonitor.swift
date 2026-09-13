import Foundation

/// Knows whether the shared API key has funds, and says so when that changes.
///
/// Rajan's ask: "whenever i add funds to the key every user of the app should
/// receive a Cobux app notification." The literal form of that -- Rajan tops up
/// the key, and every installed copy of Cobux buzzes a moment later -- needs a
/// server he can tell, and APNs to fan it out. Cobux has neither: there is no
/// backend, and every notification in this app is a local one. Adding CloudKit
/// to get push for free is specifically off the table, because introducing an
/// iCloud container is what silently switched SwiftData into a mirroring mode
/// it was never built for and killed the app on launch for three builds.
///
/// So this delivers the same OUTCOME by the only honest route available: the
/// app finds out for itself. It remembers that the key ran dry, and the first
/// time a request succeeds afterwards, that is proof the key was topped up --
/// and it says so. No server, no new entitlement, no polling cost.
///
/// The limitation is real and worth naming: this fires when the app next
/// reaches the API, not the instant funds land. What it reliably prevents is
/// the failure that actually costs users -- hitting a dead key, giving up, and
/// never learning it came back.
@MainActor
enum CreditStatusMonitor {
    private static var defaults: UserDefaults { CobuxSchema.groupDefaults }
    /// When the key was first seen to be out of funds; absent means healthy.
    private static let exhaustedSinceKey = "cobux.credits.exhaustedSince"

    /// True while the last thing the API told us was "no funds".
    static var isExhausted: Bool { defaults.object(forKey: exhaustedSinceKey) != nil }

    static var exhaustedSince: Date? {
        defaults.object(forKey: exhaustedSinceKey) as? Date
    }

    /// Call with every API failure. Only a genuine funding failure latches the
    /// flag -- a 500, a timeout or a dropped connection says nothing about the
    /// balance, and treating those as exhaustion would produce a "credits are
    /// back" notification for a key that never went anywhere.
    static func recordFailure(_ error: Error) {
        guard case ClaudeError.creditsExhausted = error else { return }
        guard !isExhausted else { return }
        defaults.set(Date.now, forKey: exhaustedSinceKey)
        DiagnosticLog.log("credits: key reported exhausted")
    }

    /// Call with every API success. A success is the only trustworthy evidence
    /// that funds exist, which is why recovery is detected here rather than by
    /// probing: a probe would be a second request that costs the same as the
    /// real one and can only tell us what the real one already did.
    static func recordSuccess(notifier: NotificationManager? = nil) {
        guard let since = exhaustedSince else { return }
        defaults.removeObject(forKey: exhaustedSinceKey)
        DiagnosticLog.log("credits: restored after \(Int(Date.now.timeIntervalSince(since) / 60))m")
        // Only worth interrupting someone over if the outage lasted long enough
        // that they plausibly hit it and walked away. A blip that resolved in
        // two minutes is noise, and a notification for it teaches people to
        // ignore the channel.
        guard Date.now.timeIntervalSince(since) >= minimumOutageForNotice else { return }
        (notifier ?? NotificationManager()).notifyCreditsRestored()
    }

    /// Ten minutes. Below this, nobody was meaningfully blocked.
    static let minimumOutageForNotice: TimeInterval = 600
}
