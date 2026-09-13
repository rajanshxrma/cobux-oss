import SwiftUI

/// Wraps a Journal screen's real content behind Face ID, showing a lock gate
/// instead until unlocked. One shared implementation for every Journal
/// screen (`JournalListView`, `JournalEntryDetailView`,
/// `JournalEntryComposeView`) instead of triplicating the same authenticate/
/// gate/auto-prompt logic three times -- see `JournalLockStatus` for what
/// "locked" means and why the shared `isUnlocked` flag, not a per-screen one,
/// is correct: unlocking anywhere unlocks the whole Journal tab for the rest
/// of that foreground session, matching Apple's own Journal app.
///
/// Originally only `JournalListView` checked the lock at all -- backgrounding
/// the app while reading an entry (`JournalEntryDetailView`, pushed on top of
/// the list) or mid-compose (`JournalEntryComposeView`, sheeted over
/// whichever screen presented it) left that screen's real content fully
/// visible on return, no prompt at all. The lock was bypassed by simply not
/// being on the list screen when the app backgrounded.
struct JournalLocked<Content: View>: View {
    /// Whether THIS screen should auto-prompt Face ID the instant it detects
    /// a lock. Must be `false` on a screen that currently has one of its own
    /// sheets/covers presented on top of it -- otherwise a covered screen
    /// pops a system Face ID dialog over whatever's actually on top of it
    /// (concretely: background mid-typing in the compose sheet, and the LIST
    /// underneath used to auto-prompt anyway, throwing a Face ID dialog over
    /// the still-open compose sheet with no warning). The topmost visible
    /// screen at any given moment is the only one that should ever pass
    /// `true` here; a parent presenting a sheet passes `false` while that
    /// sheet is up, letting the sheet's own `JournalLocked` (always `true`,
    /// since nothing is ever presented on top of a sheet) own the prompt.
    var autoPromptsWhenTopmost: Bool = true
    /// Whether there is anything behind this gate worth a Face ID prompt.
    /// The lock is armed by CONTENT, not by install: `lockEnabled` defaults
    /// on, and a brand-new install used to demand biometrics to see the
    /// first-run carousel -- sample cards protecting zero entries -- then, on
    /// the cancelled system sheet, told the person "That didn't work." That
    /// was the first-run path shown to a potential investor. A caller with
    /// nothing to protect passes `false`; the content renders and nothing
    /// prompts. `JournalListView` passes `!entries.isEmpty`; the composer
    /// passes whether the journal already has an entry.
    var armed: Bool = true
    @ViewBuilder var content: () -> Content

    @AppStorage(JournalLockStatus.enabledKey) private var lockEnabled = true
    @State private var lockStatus = JournalLockStatus.shared
    @State private var isAuthenticating = false
    @State private var authenticationFailed = false

    private var isLocked: Bool { lockEnabled && armed && !lockStatus.isUnlocked }

    var body: some View {
        Group {
            if isLocked {
                lockGate
            } else {
                content()
            }
        }
        // `id: isLocked` re-runs this exactly once per lock/unlock transition
        // (not on every re-render) -- prompts Face ID automatically the
        // moment this screen appears locked AND is actually the topmost
        // visible one, rather than making a tester find and tap "Unlock"
        // every single time.
        .task(id: isLocked) {
            guard autoPromptsWhenTopmost, isLocked, !isAuthenticating else { return }
            await attemptUnlock()
        }
    }

    private var lockGate: some View {
        CobuxEmptyStateView(
            icon: "faceid",
            title: "Journal Locked",
            // True whether the system sheet was cancelled or Face ID genuinely
            // failed -- `authenticate()` reports only a Bool, so this copy
            // must not guess. It used to say "That didn't work. Try again, or
            // check your device passcode is set up" to someone who had simply
            // tapped Cancel. It then offered the passcode as the way through;
            // there is no passcode any more (Rajan, 2026-09-12: "I just don't
            // want the passcode as the second option" -- see
            // `JournalLockStatus.authenticate`), so the copy names the one
            // path that exists and nothing else.
            message: authenticationFailed
                ? "Not unlocked yet. Tap Unlock to try Face ID again."
                : "Unlock with Face ID to see your entries."
        ) {
            CobuxEmptyStateButton("Unlock", systemImage: "faceid") {
                Task { await attemptUnlock() }
            }
        }
    }

    private func attemptUnlock() async {
        isAuthenticating = true
        let success = await JournalUnlockCoordinator.authenticate(lockStatus)
        authenticationFailed = !success
        isAuthenticating = false
    }
}

/// One in-flight authentication for every gate in the app.
///
/// Two `JournalLocked` gates can be live at once -- a detail screen under a
/// compose sheet, say -- and both watch the same `isUnlocked`. A relock then
/// used to make each one call `authenticate()`, racing two concurrent
/// `LAContext.evaluatePolicy` calls: the second is rejected by the system
/// while the first is up, so one gate reported a failure nobody caused. The
/// `autoPromptsWhenTopmost` discipline is the first line against that; this
/// is the second, so that no ordering mistake in any caller can ever produce
/// two prompts. Every caller joins the prompt already in progress and gets
/// its real answer.
///
/// **Anything that offers an unlock calls this, never `status.authenticate()`
/// directly.** That is not a style note: a single direct caller re-opens the
/// race for the whole app, and one had drifted back in (chat's journal-weave
/// unlock notice), which is how this line came to be written down.
@MainActor
enum JournalUnlockCoordinator {
    private static var inFlight: Task<Bool, Never>?

    static func authenticate(_ status: JournalLockStatus) async -> Bool {
        if let inFlight { return await inFlight.value }
        let task = Task<Bool, Never> {
            defer { inFlight = nil }
            return await status.authenticate()
        }
        inFlight = task
        return await task.value
    }
}
