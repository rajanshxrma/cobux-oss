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
    @ViewBuilder var content: () -> Content

    @AppStorage(JournalLockStatus.enabledKey) private var lockEnabled = true
    @State private var lockStatus = JournalLockStatus.shared
    @State private var isAuthenticating = false
    @State private var authenticationFailed = false

    private var isLocked: Bool { lockEnabled && !lockStatus.isUnlocked }

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
            message: authenticationFailed
                ? "That didn't work. Try again, or check your device passcode is set up."
                : "Unlock with Face ID to see your entries."
        ) {
            CobuxEmptyStateButton("Unlock", systemImage: "faceid") {
                Task { await attemptUnlock() }
            }
        }
    }

    private func attemptUnlock() async {
        isAuthenticating = true
        let success = await lockStatus.authenticate()
        authenticationFailed = !success
        isAuthenticating = false
    }
}
