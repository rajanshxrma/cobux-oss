import AppIntents
import Foundation
import SwiftData

enum JournalArchiveIntentError: LocalizedError {
    case noContainer
    case needsStartDate
    case locked

    var errorDescription: String? {
        switch self {
        case .noContainer:
            return "Couldn't open your Cobux journal. Try again from the app."
        case .needsStartDate:
            return "Pick a date for \u{201C}Written after a date\u{201D}, or choose Everything."
        case .locked:
            // Names the way through AND the way out, because a shortcut that
            // fails at 3am with "locked" and nothing else is a shortcut he
            // deletes. The toggle is quoted exactly as `SettingsView` labels
            // it, and Settings really does live behind More.
            return "Your journal is locked, so Cobux won't hand it over. Run this with the phone in front of you and unlock with Face ID — or, to let it run unattended, turn off \u{201C}Require Face ID for Journal\u{201D} in More \u{203A} Settings."
        }
    }
}

/// Which entries to hand over.
///
/// "at minimum: everything, or everything since a date" is the requirement.
/// `sinceLastRun` is the third case because it is the one that makes a
/// *scheduled* automation work without arithmetic: a nightly shortcut set to
/// "Everything" re-appends the whole archive every night, and asking someone to
/// edit a date into a shortcut every day is not an automation.
enum JournalArchiveRange: String, AppEnum {
    case everything
    case sinceDate
    case sinceLastRun

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Entries to include"

    static var caseDisplayRepresentations: [JournalArchiveRange: DisplayRepresentation] = [
        .everything: "Everything",
        .sinceDate: "Written after a date",
        .sinceLastRun: "New since the last time this ran"
    ]
}

/// Hands the journal over as plain text so Apple's own Shortcuts actions can put
/// it in Apple Notes.
///
/// Rajan's ask: "there should be an option to create adn sincu cobux journals to
/// apple notes. a separte cobux folder that cobux app creates so if by chance the
/// ocbux journals are lost misatkenly thhey still in apple notes."
///
/// **The folder half is not buildable, and this file does not pretend otherwise.**
/// Verified against the iPhoneOS26.5 SDK: there is no `Notes` module, AppIntents
/// exposes no note entity or `.notes` assistant schema (`AppIntents.IntentNote`
/// exists as a symbol in the stub library but is absent from the swiftinterface —
/// Apple-internal, not importable), and `Intents.INCreateNoteIntent` is a protocol
/// an app *implements to be asked* by Siri, not one an app can send to Notes. No
/// third-party app can create a folder in Apple Notes or write into it.
///
/// So the bridge runs the other way. Cobux produces the words; Apple's "Create
/// Note" / "Append to Note" actions, which already exist in Shortcuts and which
/// the user points at whichever Notes folder they like, do the writing. That is
/// one shortcut the user accepts once — it is not automatic, and no copy anywhere
/// in this app says it is.
///
/// Returns a `String` so the value drops straight into those actions' body field
/// with nothing in between. The spoken dialog is a one-line receipt, never the
/// journal: `ReturnsValue` is what Shortcuts pipes, `ProvidesDialog` is what Siri
/// says out loud, and reading someone's journal aloud is the opposite of this
/// feature. Same split `RandomHighlightIntent` uses, where the two happen to
/// coincide.
struct JournalArchiveIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Journal Entries as Text"
    static var description = IntentDescription(
        "Every Cobux journal entry as plain text, oldest first — ready for Shortcuts' Create Note or Append to Note.",
        categoryName: "Journal"
    )

    // `openAppWhenRun` is deliberately absent, unlike `JournalEntryIntent`
    // which spells out its `false`. The default IS `false`, which is what this
    // needs, and on the iOS 26 SDK writing it out is a deprecation warning for
    // no behaviour change. Face ID does not need the app in front either:
    // `LAContext` presents a system-owned sheet over whatever is on screen,
    // and when it genuinely cannot present one it fails -- which is the
    // correct outcome here. See `passesJournalLock()`.

    @Parameter(title: "Include", default: .everything)
    var range: JournalArchiveRange

    @Parameter(
        title: "Written After",
        description: "Only used when Include is \u{201C}Written after a date\u{201D}."
    )
    var startDate: Date?

    /// Where `sinceLastRun` counts from. `UserDefaults.standard`, like every
    /// other watermark in this app (`JournalAutoExportService.lastExportKey`,
    /// `AutoBackupService.lastBackupDateKey`) — an intent declared in the app
    /// target runs in the app's own process, so this is the same suite the app
    /// reads.
    private static let lastRunKey = "cobux.journalArchive.lastHandoffDate"

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // ORDER IS THE CONTRACT, not a preference. This is the only `await` in
        // the function and it comes FIRST, before a `ModelContext` exists.
        // `perform()` is nonisolated and `async`, so it can resume on a
        // different thread after any suspension point (SE-0338); a context
        // created before this hop and read after it is the Build-5 SwiftData
        // crash class this codebase already carries five separate warnings
        // about. `JournalAutoExportService.writeExport` is ordered this way for
        // the identical reason.
        guard await Self.passesJournalLock() else {
            throw JournalArchiveIntentError.locked
        }

        let cutoff: Date?
        switch range {
        case .everything:
            cutoff = nil
        case .sinceDate:
            guard let startDate else { throw JournalArchiveIntentError.needsStartDate }
            cutoff = startDate
        case .sinceLastRun:
            // Absent on the first run: no watermark means "everything so far",
            // which is exactly right — the first append IS the seed.
            cutoff = UserDefaults.standard.object(forKey: Self.lastRunKey) as? Date
        }

        guard let container = CobuxSchema.makeAppGroupContainer() else {
            throw JournalArchiveIntentError.noContainer
        }

        // From here to `render` there is no suspension point, so this context
        // and its rows never leave the thread that made them. Flattened to
        // `JournalPlainTextArchive.Entry` immediately: plain values are all that
        // continue past this block.
        let context = ModelContext(container)
        let rows = (try? context.fetch(FetchDescriptor<PersonalWritingEntry>())) ?? []
        var entries = rows.map { row in
            JournalPlainTextArchive.Entry(
                date: row.modifiedDate ?? row.dateImported,
                title: row.title,
                source: row.source,
                text: row.text
            )
        }
        // Filtered in Swift rather than in a `#Predicate`, because the date that
        // orders this archive is `modifiedDate ?? dateImported` and a coalesced
        // optional is not something to trust a predicate compiler with on the
        // path whose whole job is not losing entries. The archive is thousands of
        // rows, not millions. Same call `JournalListView.sortedEntries` makes.
        if let cutoff {
            // Strictly after, so the entry that set the watermark last time is
            // not appended a second time.
            entries = entries.filter { $0.date > cutoff }
        }

        let newest = entries.map(\.date).max()
        // Advance on `everything` too, not only on `sinceLastRun`. The intended
        // flow is "seed the note once with Everything, then schedule the
        // appends", and if Everything left the watermark unset, that first
        // scheduled append would duplicate the entire archive into the note —
        // the failure that hits the normal path rather than an experiment.
        // `sinceDate` is a deliberate one-off query and never moves it.
        //
        // The dialog below says the new watermark out loud. A stored date that
        // silently changes what a later run returns is exactly the kind of
        // hidden state this app refuses to keep.
        if range != .sinceDate, let newest {
            UserDefaults.standard.set(newest, forKey: Self.lastRunKey)
        }

        guard !entries.isEmpty else {
            // Empty text, not an error. A nightly automation that throws on a
            // quiet day is a nightly failure notification; Shortcuts' own "If
            // <text> has any value" is the one line that skips the append, and
            // the setup notes say to add it.
            return .result(value: "", dialog: "Nothing new in your journal since then.")
        }

        return .result(
            value: JournalPlainTextArchive.render(entries),
            dialog: IntentDialog(stringLiteral: Self.receipt(count: entries.count, newest: newest))
        )
    }

    /// One line, spoken. Says what was handed over and where the next
    /// "since the last time" run will start from.
    private static func receipt(count: Int, newest: Date?) -> String {
        let noun = count == 1 ? "entry" : "entries"
        guard let newest else { return "\(count) journal \(noun)." }
        let through = newest.formatted(date: .abbreviated, time: .omitted)
        return "\(count) journal \(noun), through \(through). Next time, \u{201C}new since the last time\u{201D} starts after that."
    }

    /// The journal lock, honoured exactly as the app honours it — never a second
    /// implementation of it.
    ///
    /// This intent hands over the single most personal content the app holds, to
    /// a caller that has passed no gate at all, so it takes the same door
    /// `JournalLocked` takes and in the same order.
    ///
    /// `JournalLocked` also has an `armed` flag, so a journal with nothing in it
    /// never prompts. This deliberately does not take that door: knowing whether
    /// the journal is empty means fetching before authenticating, which would put
    /// SwiftData work on both sides of the one suspension point above. Always
    /// gating costs an unnecessary prompt in one harmless case and removes a
    /// whole class of ordering mistake.
    ///
    /// A background automation with nobody holding the phone cannot present Face
    /// ID, so `evaluatePolicy` fails, this returns `false`, and the intent
    /// refuses. That is the intended behaviour, not a gap: fail closed, and say
    /// in the error how to run it attended or how to turn the lock off.
    @MainActor
    private static func passesJournalLock() async -> Bool {
        // Five views read this as `@AppStorage(JournalLockStatus.enabledKey)
        // private var lockEnabled = true`, so an ABSENT key means the lock is
        // ON. `bool(forKey:)` reads absent as `false` — which would silently
        // open this gate on exactly the install where nothing has ever written
        // the key, i.e. a fresh one.
        let enabled = UserDefaults.standard.object(forKey: JournalLockStatus.enabledKey) as? Bool ?? true
        guard enabled else { return true }

        let status = JournalLockStatus.shared
        // Same short-circuit as `JournalLocked.isLocked`: unlocking anywhere
        // unlocks the Journal for the rest of that foreground session, so a
        // shortcut run seconds after he unlocked the tab does not re-prompt.
        // When the app is not already running, the intent launches it fresh,
        // `isUnlocked` is `false`, and the prompt happens — correct both ways.
        if status.isUnlocked { return true }

        // Never `status.authenticate()` directly. `JournalUnlockCoordinator`'s
        // own doc comment states that as the rule and records that one direct
        // caller re-opens the two-concurrent-`LAContext` race for the whole app.
        return await JournalUnlockCoordinator.authenticate(status)
    }
}
