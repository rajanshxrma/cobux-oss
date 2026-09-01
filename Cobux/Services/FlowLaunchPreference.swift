import Foundation

/// Whether Flow opens automatically when the app launches.
///
/// One key, named in one place, because it is read from `ContentView` (which
/// decides whether to present) and written from Settings (which offers the
/// toggle) -- a string literal duplicated across two files is how a preference
/// quietly stops working when one of them is edited.
///
/// Defaults to ON. Rajan asked for Flow-on-open and then asked to be able to
/// turn it off, explicitly keeping the default: "by default flow should be on
/// screen." So this is an escape hatch, not a feature flag.
enum FlowLaunchPreference {
    static let enabledKey = "cobux.flow.openOnLaunch"

    static var isEnabled: Bool {
        // `object(forKey:)` first: `bool(forKey:)` returns false for an absent
        // key, which would silently make the default OFF for everyone who has
        // never touched the toggle -- the opposite of what he asked for.
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}
