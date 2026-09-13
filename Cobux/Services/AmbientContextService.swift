import CoreLocation
import Foundation
import WeatherKit

/// The weather and place a journal entry was written in.
///
/// Modelled line-for-line on `HealthContextService`, because that feature is
/// the one Rajan singled out as working -- "i love the hours of sleep displayed
/// feaure in ojournals" -- and the properties that make it work are the spec:
/// it is fetched fire-and-forget so nothing ever waits on it, it returns
/// nothing rather than something approximate, it asks exactly one question once
/// and then never again, and it is context beside his writing rather than a
/// dataset the app starts owning.
///
/// **This service never possesses a precise location.** It asks for reduced
/// accuracy only (`kCLLocationAccuracyReduced`, roughly 1-5km), which is enough
/// for both jobs -- the temperature is the same across a few kilometres, and
/// the place is rendered as a city -- and it discards the `CLLocation` the
/// moment it has a temperature and a city name. No coordinate is stored, so no
/// coordinate can be exported, backed up, or subpoenaed out of a journal whose
/// entries are deliberately undeletable.
@MainActor
@Observable
final class AmbientContextService: NSObject {
    static let shared = AmbientContextService()

    /// Alias, not a second definition -- the flag's one name lives on
    /// `AmbientContext`, the file the Messages extension can actually compile.
    /// Every `@AppStorage` that writes this must also be handed
    /// `CobuxSchema.groupDefaults` as its `store:`, or it writes somewhere no
    /// reader looks; see `migrateEnabledFlagIfNeeded` for what that cost.
    static let enabledKey = AmbientContext.enabledKey

    /// The app-group suite, so a stamp written from the Siri intent or from the
    /// Messages extension reads the same cache the app filled.
    private static var defaults: UserDefaults { CobuxSchema.groupDefaults }

    /// Moves an already-made choice into the store that is actually read.
    ///
    /// Until this shipped, `SettingsView`'s and `JournalFirstRunView`'s
    /// `@AppStorage` wrote the enabled flag to `UserDefaults.standard` while
    /// `isEnabled` and `AmbientContext.cached()` read it from the app-group
    /// suite. The toggle looked on and the feature was off: `refreshIfNeeded`
    /// returned at its first guard on every call, nothing was ever fetched, and
    /// no stamp ever carried a temperature or a place. Rajan reported exactly
    /// that -- *"also the temperatiure and location not working even after
    /// turning on settings"*.
    ///
    /// Both sides now name the group suite, which fixes it going forward and
    /// would silently switch the feature back OFF for anyone who already turned
    /// it on -- their `true` is sitting in the store nothing reads any more. So
    /// the choice is carried across, once, and the stale copy removed, leaving
    /// exactly one store holding the flag.
    ///
    /// Idempotent by construction: after one run `standard` no longer has the
    /// key, so the first guard fails on every later launch. Also correct in the
    /// degenerate case where the app group is unavailable and `groupDefaults`
    /// falls back to `.standard` -- then the second guard fails (the key is
    /// visibly present in "both" stores, because they are one store) and
    /// nothing is written or removed.
    static func migrateEnabledFlagIfNeeded() {
        let standard = UserDefaults.standard
        let group = CobuxSchema.groupDefaults
        guard standard.object(forKey: enabledKey) != nil,
              group.object(forKey: enabledKey) == nil else { return }
        group.set(standard.bool(forKey: enabledKey), forKey: enabledKey)
        standard.removeObject(forKey: enabledKey)
    }

    private static let tempKey = "cobux.ambient.temperatureF"
    private static let localityKey = "cobux.ambient.locality"
    private static let conditionKey = "cobux.ambient.condition"
    private static let fetchedKey = "cobux.ambient.fetchedAt"
    /// A rolling count of how often each city has been seen, so "the usual
    /// place" can be derived rather than configured. Cities only -- never a
    /// coordinate, never a timestamped visit, so this cannot reconstruct a
    /// movement history.
    private static let localityTallyKey = "cobux.ambient.localityTally"

    /// How long a reading stays usable. Beyond this the stamp simply omits the
    /// context rather than claiming stale weather.
    private static let freshness: TimeInterval = 60 * 60
    /// Don't re-fetch more often than this.
    private static let minimumInterval: TimeInterval = 30 * 60

    /// Absent means ON (see `AmbientContext.cached()` for his 12 Sep ruling).
    static var isEnabled: Bool { (defaults.object(forKey: enabledKey) as? Bool) ?? true }

    private let manager = CLLocationManager()
    private var isFetching = false

    // ------------------------------------------------------------- the cache

    /// What the stamp reads, synchronously. `nil` whenever there is nothing
    /// true to say -- disabled, never fetched, or stale.
    static func current() -> AmbientContext? { AmbientContext.cached() }

    /// The city seen most often. Derived, never set by the user.
    ///
    /// This is the answer to his "an opiton of user stting home location" idea,
    /// and it is deliberately not that: pinning home means STORING home, and
    /// home is the single place that should never be written down. Deriving the
    /// usual city means the stamp can stay silent about it -- so the everyday
    /// entries never record a location at all, and the place appears only when
    /// it is the interesting fact.
    static func usualLocality() -> String? {
        guard let tally = defaults.dictionary(forKey: localityTallyKey) as? [String: Int]
        else { return nil }
        return tally.max { $0.value < $1.value }?.key
    }

    // ------------------------------------------------------------ refreshing

    /// Fire-and-forget. Never awaited by anything the user is looking at.
    func refreshIfNeeded() {
        guard Self.isEnabled, !isFetching else { return }
        if let fetched = Self.defaults.object(forKey: Self.fetchedKey) as? Date,
           Date.now.timeIntervalSince(fetched) < Self.minimumInterval { return }
        guard CLLocationManager.locationServicesEnabled() else { return }
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        isFetching = true
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        manager.delegate = self
        manager.requestLocation()
    }

    /// Asked once, from Settings, when the toggle is turned on.
    func requestAuthorization() {
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
    }

    /// True when the stamp is on but location has never been asked for. With
    /// the stamp defaulting ON (58), nobody flips a toggle any more, so the
    /// toggle's `onChange` can no longer be where the system prompt comes from.
    /// The compose sheet shows a one-line explanation and asks from there --
    /// after explaining, never before (`R-2026-09-location-asked-before-it-is-explained`).
    var needsAuthorizationPrompt: Bool {
        Self.isEnabled && manager.authorizationStatus == .notDetermined
    }

    var authorizationDenied: Bool {
        manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
    }

    private func store(location: CLLocation) async {
        // Both lookups are allowed to fail independently. A temperature with no
        // city, or a city with no temperature, is still worth saying.
        async let weather = try? WeatherService.shared.weather(for: location, including: .current)
        async let placemarks = try? CLGeocoder().reverseGeocodeLocation(location)

        if let current = await weather {
            let fahrenheit = current.temperature.converted(to: .fahrenheit).value
            Self.defaults.set(Int(fahrenheit.rounded()), forKey: Self.tempKey)
            // Only conditions worth remembering a day by. "Clear" and "Cloudy"
            // are the default state of the world and say nothing.
            let notable: Set<WeatherCondition> = [
                .rain, .heavyRain, .drizzle, .freezingRain, .thunderstorms,
                .snow, .heavySnow, .blizzard, .sleet, .hail, .hurricane,
                .tropicalStorm, .blowingSnow, .flurries, .foggy,
            ]
            Self.defaults.set(notable.contains(current.condition)
                              ? current.condition.description : nil,
                              forKey: Self.conditionKey)
        }
        if let locality = (await placemarks)?.first?.locality {
            Self.defaults.set(locality, forKey: Self.localityKey)
            var tally = Self.defaults.dictionary(forKey: Self.localityTallyKey) as? [String: Int] ?? [:]
            tally[locality, default: 0] += 1
            Self.defaults.set(tally, forKey: Self.localityTallyKey)
        }
        Self.defaults.set(Date.now, forKey: Self.fetchedKey)
        isFetching = false
    }
}

extension AmbientContextService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in await store(location: location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        // Fails soft, like every path in HealthContextService: the stamp simply
        // carries no context this time.
        Task { @MainActor in isFetching = false }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in refreshIfNeeded() }
    }
}
