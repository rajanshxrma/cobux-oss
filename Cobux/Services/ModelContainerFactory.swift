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
    /// `cloudKitDatabase: .none` on EVERY configuration here is the fix for the
    /// build 25-28 launch crash (all four real-device crash logs: `fatalError`
    /// below, 0.12s after launch, both tiers failing). `ModelConfiguration`
    /// defaults to `cloudKitDatabase: .automatic`, which silently enables
    /// SwiftData's CloudKit mirroring the moment ANY iCloud container appears
    /// in the app's entitlements -- and build 25 added
    /// `iCloud.com.rajansharma.Cobux` for CloudDocuments (journal auto-export
    /// files), never for CloudKit. CloudKit-backed SwiftData requires every
    /// non-optional attribute to carry a default value, which this schema
    /// deliberately doesn't (e.g. `Book.title`), so BOTH container inits threw
    /// -- including in-memory, since `.automatic` applies to it equally.
    /// Verified: the identical 12-model schema builds both containers fine in
    /// a harness binary with no entitlements, and the crashes began at exactly
    /// the build where the entitlement went live. This app's sync story is
    /// `AutoBackupService` (documents in the same container), NOT SwiftData-
    /// CloudKit -- `.none` is the permanently correct setting, not a workaround.
    static func make() -> (container: ModelContainer, isDegraded: Bool) {
        let schema = Schema(CobuxSchema.all)
        let groupConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .identifier(CobuxSchema.appGroupID),
            cloudKitDatabase: .none
        )

        do {
            return (try ModelContainer(for: schema, configurations: [groupConfig]), false)
        } catch {
            // The error text is the difference between root-causing a launch
            // failure from a real device log in minutes and inferring it from
            // circumstantial evidence across days -- `try?` here swallowed
            // exactly the CloudKit-requirements error that would have named
            // this bug immediately.
            DiagnosticLog.log("app-group ModelContainer failed: \(error)")
        }

        let inMemoryConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        do {
            return (try ModelContainer(for: schema, configurations: [inMemoryConfig]), true)
        } catch {
            DiagnosticLog.log("in-memory ModelContainer failed: \(error)")
            // Both tiers failed, including in-memory with every external
            // dependency (group container, CloudKit) explicitly disabled --
            // this isn't a storage/migration problem retrying or falling back
            // could ever fix. No recovery path exists for that class of failure.
            fatalError("Could not create even an in-memory ModelContainer: \(error)")
        }
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
