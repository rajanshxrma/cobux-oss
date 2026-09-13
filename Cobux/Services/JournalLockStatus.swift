import Foundation
import LocalAuthentication

/// Gates the Journal tab behind Face ID/Touch ID -- biometrics ONLY, no
/// passcode fallback -- the one thing this app was missing most: journal
/// entries are the single most personal content type Cobux can hold, and
/// nothing else in the app is locked at all.
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

    /// Chat's "use my journal in replies" switch (`SettingsView`/`ChatView`
    /// read it through `@AppStorage` under this same string).
    static let contextEnabledKey = "personalWritingContextEnabled" // lint:unused-ok the Chat lane adopts this constant in ChatView/SettingsView in place of its literal
    /// Set the moment he turns that switch OFF himself, and never cleared by
    /// this class. See `grantChatContextIfNeverRefused()`.
    static let contextExplicitlyOffKey = "personalWritingContextExplicitlyOff"

    var isUnlocked = false

    func relock() {
        isUnlocked = false
    }

    /// `.deviceOwnerAuthenticationWithBiometrics`, and no fallback button.
    ///
    /// This used to be `.deviceOwnerAuthentication`, with a paragraph here
    /// arguing FOR the passcode: Face ID fails for reasons that have nothing
    /// to do with who is holding the phone, so a biometrics-only gate on his
    /// actual journal could turn bad lighting into a lockout. Rajan overruled
    /// it on 2026-09-12: "I want Journal to only use Face ID. I don't want it
    /// to use the typed passcode ... if it doesn't use Face ID just shows
    /// error whatever ... I don't want Cobux to show specific error or
    /// something, but I just don't want the passcode as the second option."
    /// A typed passcode is the thing someone standing next to him can watch;
    /// a face is not. So: Face ID, or the gate stays shut, quietly.
    ///
    /// `localizedFallbackTitle = ""` is what removes the "Enter Password"
    /// button from the system sheet after a failed match -- the policy alone
    /// still offers it.
    @discardableResult
    func authenticate() async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            // A device with NO biometry -- none enrolled, no sensor, or no
            // passcode set (biometrics require one) -- has nothing this policy
            // can enforce, and the honest response is "there's nothing to
            // unlock this behind," not a lockout on a device that was never
            // going to have this protection regardless of what Cobux does.
            //
            // A biometry LOCKOUT (too many failed faces) is the opposite case:
            // the sensor exists and is refusing, and the journal stays shut
            // until the device itself is unlocked again. Any other evaluation
            // failure stays locked too, silently -- his words, "just shows
            // error whatever", and the gate's copy is already neutral.
            switch (error as? LAError)?.code {
            case .biometryNotEnrolled?, .biometryNotAvailable?, .passcodeNotSet?:
                // No grant here: the chat-context grant below is keyed to a
                // real Face ID success, and this branch is the absence of one.
                isUnlocked = true
                return true
            default:
                isUnlocked = false
                return false
            }
        }
        let success = (try? await context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Unlock your journal"
        )) ?? false
        isUnlocked = success
        if success { grantChatContextIfNeverRefused() }
        return success
    }

    /// The first successful journal Face ID turns chat's journal context ON,
    /// persistently. Rajan's model, 2026-09-12: unlocking the journal IS the
    /// consent -- he has just proved it is him and opened his own writing, so
    /// chat may read it too. But an explicit Turn off in chat is remembered
    /// (`contextExplicitlyOffKey`, written by the Chat surface), and a later
    /// unlock must never undo a choice he made on purpose. So this only ever
    /// flips the switch on, and only while he has never flipped it off.
    private func grantChatContextIfNeverRefused() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.contextExplicitlyOffKey) {
            defaults.set(true, forKey: Self.contextEnabledKey)
        }
    }
}
