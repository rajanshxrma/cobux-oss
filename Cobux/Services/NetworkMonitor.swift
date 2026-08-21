import Foundation
import Network

/// Watches device-level network reachability so a fully offline user gets an
/// immediate, honest failure instead of waiting through `ClaudeService`'s
/// intentional 120s idle timeout (see that file's own doc comment -- that
/// timeout is a legitimate backstop for a genuinely cold prompt cache, not a
/// bug, and is NOT touched by this file). Before this, there was no
/// reachability check anywhere in the codebase: an offline chat send, quiz
/// generation, or tag merge just sat on a spinner for up to two minutes
/// before any error ever surfaced -- indistinguishable from "stuck" to the
/// person looking at it.
///
/// `@Observable` + `static let shared`, matching the convention already
/// established by `SeedingStatus` for shared app-wide state (rather than
/// `ObservableObject`/`@Published`, which nothing else in `Services/` uses
/// for this kind of singleton).
@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    /// Defaults to `true` (assume online) until the monitor's first path
    /// update arrives. `NWPathMonitor`'s initial callback is asynchronous --
    /// defaulting to `false` would flash a false "offline" state on every
    /// normal, actually-connected launch for the brief window before that
    /// first callback fires. A false negative here (briefly still assuming
    /// online while genuinely offline) just means the very first network
    /// call falls back to the existing timeout/error path -- unchanged from
    /// today's behavior. A false positive (flashing "offline" while online)
    /// would be a new, self-inflicted regression, so `true` is the only safe
    /// default direction.
    var isConnected: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.cobux.networkmonitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor in
                self?.isConnected = connected
            }
        }
        monitor.start(queue: queue)
    }
}
