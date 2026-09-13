import Foundation

/// What was true outside while he was writing.
struct AmbientContext: Equatable {
    let temperatureF: Int?
    let locality: String?
    let condition: String?
    /// True when this is the city he writes from most. The stamp stays silent
    /// about the usual place -- naming it every day is noise, and not naming it
    /// is what keeps ordinary entries from accumulating a location log.
    let isUsualPlace: Bool

    /// The tail appended to a session stamp, or `nil` when there is nothing
    /// worth adding.
    var stampTail: String? {
        var parts: [String] = []
        if let temperatureF { parts.append("\(temperatureF)°") }
        if let condition { parts.append(condition) }
        if let locality, !isUsualPlace { parts.append(locality) }
        guard !parts.isEmpty else { return nil }
        return " · " + parts.joined(separator: " · ")
    }
}

extension AmbientContext {
    /// The one name for the on/off flag.
    ///
    /// It lives HERE, in the file both the app and the Messages extension
    /// compile, rather than on `AmbientContextService` -- that type imports
    /// WeatherKit and CoreLocation, so an extension cannot see it, which is why
    /// this file used to carry a hand-typed copy of the key string. A second
    /// copy of a key is a second chance to disagree with the first, and this
    /// feature has already been broken once by exactly that shape of mistake
    /// (see `CobuxSchema.groupDefaults`). `AmbientContextService.enabledKey`
    /// is now an alias for this, not a peer of it.
    static let enabledKey = "cobux.ambient.contextEnabled"

    /// Reads the app-group cache the app fills, WITHOUT importing WeatherKit or
    /// CoreLocation -- so the Siri intent and the Messages extension can stamp
    /// the same context the composer does.
    ///
    /// That parity is not a nicety. `JournalSessionStamp`'s own doc comment
    /// records that the three entry doors once drifted apart on the stamp
    /// format, and shipping context in only one of them would recreate exactly
    /// that bug on day one.
    static func cached() -> AmbientContext? {
        let defaults = CobuxSchema.groupDefaults
        // Absent means ON. His words, 12 Sep 2026, after five days of the toggle
        // sitting off and untold: "no temperature yet in journals". The stamp
        // he asked for on 3 Sep ("the temperature right next to the time") is
        // the default now; Settings can still turn it off, and the location
        // prompt is still asked only after it has been explained.
        guard (defaults.object(forKey: enabledKey) as? Bool) ?? true,
              let fetched = defaults.object(forKey: "cobux.ambient.fetchedAt") as? Date,
              Date.now.timeIntervalSince(fetched) < 60 * 60
        else { return nil }
        let temperature = defaults.object(forKey: "cobux.ambient.temperatureF") as? Int
        let locality = defaults.string(forKey: "cobux.ambient.locality")
        guard temperature != nil || locality != nil else { return nil }
        let tally = defaults.dictionary(forKey: "cobux.ambient.localityTally") as? [String: Int]
        let usual = tally?.max { $0.value < $1.value }?.key
        return AmbientContext(temperatureF: temperature,
                              locality: locality,
                              condition: defaults.string(forKey: "cobux.ambient.condition"),
                              isUsualPlace: locality != nil && locality == usual)
    }
}
