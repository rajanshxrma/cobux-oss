import Foundation

/// Cross-process access to "which books has the user switched off."
///
/// Lives in `Cobux/Shared` (not next to `BookSourceFilter`) for one concrete
/// reason: the widget extension needs to read this, and `BookSourceFilter.swift`
/// also contains `BookSourceFilterView`, a SwiftUI view depending on
/// `CobuxFormSection`. Compiling that into an app-extension target fails
/// outright -- which is exactly what happened on the first attempt at this fix.
/// Same reasoning `CobuxDeepLink.swift` and `WatchPayload.swift` already live
/// here under.
///
/// **The bug this exists to fix**, reported from real use: *"I have my books and
/// wisdom like two of the biology books turned off for my app, but I still see
/// their highlights in my iOS widget."* Two independent causes:
///
/// 1. The app stores the filter via `@AppStorage(BookSourceFilter.excludedKey)`,
///    which writes to `UserDefaults.standard` — per-process, and completely
///    invisible to the widget extension.
/// 2. The widget never consulted the filter at all.
///
/// Mirroring into the App-Group suite fixes (1) without the migration that would
/// fix it destructively: pointing `@AppStorage` at the shared suite instead
/// would silently reset every choice already made, the precise quiet data loss
/// `excludedKey`'s own doc comment warns against. So the app publishes, and the
/// widget reads.
enum BookSourceSharing {
    static let sharedExcludedKey = "cobux.bookSource.excludedIDs"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: CobuxSchema.appGroupID) ?? .standard
    }

    /// Same comma-joined-sorted-UUID encoding `BookSourceFilter` already uses,
    /// duplicated rather than shared because this file must not depend on that
    /// one (see the type doc above). Three lines, no behavior of its own.
    private static func encode(_ ids: Set<UUID>) -> String {
        ids.map(\.uuidString).sorted().joined(separator: ",")
    }

    private static func decode(_ raw: String) -> Set<UUID> {
        guard !raw.isEmpty else { return [] }
        return Set(raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    /// Call from the app whenever the resolved exclusion set changes. Cheap and
    /// idempotent -- safe to call on every launch as well, which is what keeps
    /// installs that set their filter before this shipped from waiting for the
    /// next toggle to sync.
    static func publish(_ ids: Set<UUID>) {
        defaults.set(encode(ids), forKey: sharedExcludedKey)
    }

    /// Read side, safe from any process. Empty means "nothing excluded", which
    /// is also the correct fallback for a device that hasn't published yet.
    static func excludedBookIDs() -> Set<UUID> {
        decode(defaults.string(forKey: sharedExcludedKey) ?? "")
    }
}
