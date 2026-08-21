import Foundation

/// Cobux is TestFlight-only, invite-based, with no push notification pipeline and no
/// backend of any kind. Apple exposes nothing to a running app about newer TestFlight
/// builds -- the only signals a tester gets today are whatever Apple itself sends
/// (email, TestFlight app push), and both are opt-in and easy to miss. This closes that
/// gap without standing up a server: `release/latest.json` in the PUBLIC `cobux-oss`
/// repo (see `scripts/publish-release.sh`) is a hand-published "what's the newest build"
/// signal, fetched here and compared against the build actually running.
///
/// Same shape as `SeedingStatus`/`StoreHealthStatus`: a `@MainActor @Observable`
/// singleton `ContentView` reads directly to drive its bottom banner overlay.
@MainActor
@Observable
final class UpdateAvailabilityStatus {
    static let shared = UpdateAvailabilityStatus()
    private init() {}

    var updateAvailable = false
    var latestVersion: String?
    var latestBuild: String?

    /// The `cobux-oss` repo is public specifically so this can be fetched with no
    /// auth and no rate-limit risk beyond GitHub's normal unauthenticated IP limits
    /// (a 429 there is handled identically to being offline, below).
    private static let manifestURL = URL(
        string: "https://raw.githubusercontent.com/rajanshxrma/cobux-oss/main/release/latest.json"
    )!

    private static let checkThrottle: TimeInterval = 60 * 60 // 1 hour
    @ObservationIgnored private var lastCheckDate: Date? {
        get { UserDefaults.standard.object(forKey: "updateAvailability.lastCheckDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "updateAvailability.lastCheckDate") }
    }

    /// Called opportunistically on launch and every foreground, same cadence as
    /// `ContentView`'s other "cheap, safe to call often" passes (`WatchSyncService.sync`,
    /// `updateEngagementNudges`). Throttled so two testers foregrounding repeatedly
    /// doesn't hammer GitHub, and every failure path (offline, 404, 429, malformed
    /// JSON, unparsceable build number) fails CLOSED -- a tester must never see a
    /// network error, or a false "update available," from this.
    func checkForUpdate() async {
        if let lastCheckDate, Date.now.timeIntervalSince(lastCheckDate) < Self.checkThrottle {
            return
        }
        lastCheckDate = .now

        var request = URLRequest(url: Self.manifestURL)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let manifest = try? JSONDecoder().decode(ReleaseManifest.self, from: data) else {
            return
        }

        let runningBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        guard BuildVersion.isNewer(manifest.latestBuild, than: runningBuild) else { return }

        latestVersion = manifest.latestVersion
        latestBuild = manifest.latestBuild
        updateAvailable = true
    }
}

private struct ReleaseManifest: Decodable {
    let latestVersion: String
    let latestBuild: String
}

/// Where the update banner sends a tapping tester. `itms-beta://` is undocumented
/// but does open the TestFlight app -- its real limitation is that it can only land
/// on TestFlight's own home list, not Cobux's specific page, since there's no
/// TestFlight public link for Cobux yet (see `docs/going-public.md`). Once one
/// exists, swap this for `https://testflight.apple.com/join/<code>` -- a universal
/// link straight to Cobux's page that also degrades gracefully to a web page if
/// TestFlight isn't installed. Kept as one named constant so that's a one-line change
/// with nothing else in the app to touch.
enum AppReleaseInfo {
    static let testFlightURL = URL(string: "itms-beta://")!
}
