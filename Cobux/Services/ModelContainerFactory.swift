import SwiftData
import Foundation

/// Real recovery path for container-init failure, replacing a bare `fatalError` that
/// permanently bricked a tester's install with no way back but deleting the app and
/// losing all quiz history. Not tonight's actual crash (the real .ips log points
/// elsewhere -- see `BookCard.swift`), but a `fatalError` here means ANY future
/// migration failure has zero recovery path, so it's worth closing regardless.
///
/// Two tiers, not three: the real on-disk App-Group store, and -- only if that
/// throws -- an in-memory store so the app can still launch and function for this
/// session instead of dying at the splash screen. A more ambitious third tier
/// (move the corrupt store's files aside and let SwiftData rebuild fresh in place)
/// was considered and deliberately left out: it would require guessing SwiftData's
/// internal store/WAL/SHM file naming, which isn't documented and would be
/// speculative to encode -- the two-tier version already fully closes the "can this
/// ever permanently brick a tester" gap, which is the actual requirement.
enum ModelContainerFactory {
    static func make() -> (container: ModelContainer, isDegraded: Bool) {
        let schema = Schema(CobuxSchema.all)
        let groupConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .identifier(CobuxSchema.appGroupID)
        )

        if let container = try? ModelContainer(for: schema, configurations: [groupConfig]) {
            return (container, false)
        }

        let inMemoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        guard let fallback = try? ModelContainer(for: schema, configurations: [inMemoryConfig]) else {
            // Both tiers failed, including in-memory -- this isn't a storage/migration
            // problem retrying or falling back could ever fix (e.g. the schema itself
            // doesn't compile against the installed SwiftData runtime). No recovery
            // path exists for that class of failure.
            fatalError("Could not create even an in-memory ModelContainer")
        }
        return (fallback, true)
    }
}

/// Surfaces the in-memory fallback to the UI as an honest "nothing you do right now
/// will be saved" warning, rather than letting the app run in a silently degraded
/// mode the user has no way to notice until they force-quit and lose everything.
@MainActor
@Observable
final class StoreHealthStatus {
    static let shared = StoreHealthStatus()
    private init() {}

    var isDegraded = false
}
