import Foundation
import LocalAuthentication

/// Gates the Journal tab behind Face ID/Touch ID (falling back to the device
/// passcode) -- the same protection Apple's own Journal app offers, and
/// arguably the one thing this app was missing most: journal entries are the
/// single most personal content type Cobux can hold, and nothing else in the
/// app is locked at all.
///
/// Same shape as `SeedingStatus`/`StoreHealthStatus`/`UpdateAvailabilityStatus`
/// -- a `@MainActor @Observable` singleton a view reads directly. `ContentView`
/// resets `isUnlocked` on backgrounding, so re-opening the app always re-locks,
/// but switching tabs or pushing/popping within one continuous foreground
/// session does NOT re-prompt -- matching Apple's own Journal app rather than
/// re-authenticating on every single visit, which would just train someone to
/// dismiss the prompt on reflex instead of actually reading it.
@MainActor
@Observable
final class JournalLockStatus {
    static let shared = JournalLockStatus()
    private init() {}

    /// Defaults ON (see `SettingsView`'s matching toggle) -- content this
    /// personal should be protected by default, with an explicit opt-out for
    /// anyone who'd rather skip it, the same posture already taken for
    /// `personalWritingContextEnabled`/`useRealNamesInLifeExamples`.
    static let enabledKey = "journalLockEnabled"

    var isUnlocked = false

    func relock() {
        isUnlocked = false
    }

    /// `.deviceOwnerAuthentication`, not `.deviceOwnerAuthenticationWithBiometrics`
    /// -- the passcode fallback matters specifically here because Face ID can
    /// fail for reasons that have nothing to do with who's holding the phone
    /// (poor lighting, a mask, an obstructed camera), and a Face-ID-only gate
    /// on the one screen holding someone's actual journal would turn a bad
    /// lighting moment into a real lockout with no way through.
    @discardableResult
    func authenticate() async -> Bool {
        let context = LAContext()
        var error: NSError?
        // No passcode configured on the device at all means there's nothing
        // this policy can actually enforce -- `canEvaluatePolicy` returns
        // false here, and the honest response is "there's nothing to unlock
        // this behind," not a lockout on a device that was never going to
        // have this protection regardless of what Cobux does.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isUnlocked = true
            return true
        }
        let success = (try? await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Unlock your journal"
        )) ?? false
        isUnlocked = success
        return success
    }
}
