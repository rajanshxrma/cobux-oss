import AppIntents
import Foundation
import SwiftData
import WidgetKit

enum JournalEntryIntentError: LocalizedError {
    case noContainer
    var errorDescription: String? {
        "Couldn't open your Cobux journal. Try again from the app."
    }
}

/// "Hey Siri, journal in Cobux" — speak an entry, it lands in the Journal.
///
/// This is the answer to Rajan wanting to text Cobux like an official Apple
/// business contact. That specific thing (Apple Messages for Business) is not
/// available to him: it needs a registered business, a paid Messages Service
/// Provider, Apple's approval, and it exists for customer support, not for a
/// person messaging their own app — and registering a business is exactly the
/// wrong move on an F-1 visa.
///
/// A Siri intent gets the thing he actually wanted and skips the parts he
/// disliked. Nothing to save as a contact, nothing to set up, no message sitting
/// ungated in a Messages thread forever. It works from the Watch, from CarPlay,
/// from a HomePod, hands-free, which is where the "I need to get this down right
/// now" thought usually happens.
///
/// `requestValueDialog` is what makes it feel conversational: invoked with no
/// text, Siri ASKS what to journal and waits for dictation, so the whole
/// interaction is one phrase and then talking.
struct JournalEntryIntent: AppIntent {
    static var title: LocalizedStringResource = "Journal in Cobux"
    static var description = IntentDescription("Speak or type a journal entry straight into Cobux.")
    /// False so it never has to bring the app forward — the point is capture
    /// without opening anything.
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "Entry",
        requestValueDialog: IntentDialog("What do you want to journal?")
    )
    var entry: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let body = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return .result(dialog: "Nothing to save.")
        }
        guard let container = CobuxSchema.makeAppGroupContainer() else {
            throw JournalEntryIntentError.noContainer
        }

        // Same App-Group store the app, widgets, Share Extension and Messages
        // extension all write, so a dictated entry is a first-class journal
        // entry and rides the existing immediate iCloud export.
        let context = ModelContext(container)
        // Was a bare "h:mm a": an entry dictated to Siri never carried the
        // date, unlike one written in the app.
        let stamped = JournalSessionStamp.text(at: .now, previousSessionDate: nil,
                                                  ambient: AmbientContext.cached()) + "\n" + body
        context.insert(PersonalWritingEntry(
            source: "journal",
            title: "",
            text: stamped,
            modifiedDate: .now
        ))
        try context.save()

        StreakTracker.markJournalEntryWritten()
        StreakTracker.recordActivityToday()
        // Push to iCloud immediately, exactly like the compose screen does. An
        // entry dictated to Siri is still an entry: without this it sat only on
        // the device until something else happened to trigger an export.
        await JournalAutoExportService.export(modelContext: context, force: true)
        WidgetCenter.shared.reloadAllTimelines()
        CrossProcessSync.markDirty()

        return .result(dialog: "Saved to your journal.")
    }
}
