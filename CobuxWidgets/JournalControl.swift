import AppIntents
import SwiftUI
import WidgetKit

/// Opens straight into a new journal entry when the Lock Screen / Control
/// Center / Action Button control is pressed.
///
/// `openAppWhenRun = true` is what brings Cobux to the foreground at all --
/// without it a Control's `perform()` runs headless, the way
/// `GradeQuickCheckIntent` grades a Quick Check card with the app never
/// appearing. Returning `opensIntent: OpenURLIntent(...)` is what then steers
/// that foreground launch to `cobux://journal/new` specifically, rather than
/// wherever the app last was -- the exact URL `JournalWidgetView`'s
/// `.widgetURL` already uses, so the existing `ContentView.onOpenURL` ->
/// `JournalListView.startingNewEntry` handling (Face ID gate included, if the
/// lock is on) is the only place that has to know what this URL means. This
/// intent adds no new destination, only a new way to reach the one that
/// already exists.
struct OpenJournalComposeIntent: AppIntent {
    static var title: LocalizedStringResource = "New Journal Entry"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result(opensIntent: OpenURLIntent(CobuxDeepLink.journalURL(newEntry: true)))
    }
}

/// The control Rajan asked for by name: "on the lock screen, not the
/// widgets, but where the torch/flashlight and the default camera are
/// positioned -- bottom right camera, bottom left flashlight ... those are
/// now interchangeable with the new iOS software ... I would rather have my
/// Journal there, you press and hold it and then it opens." That is the iOS
/// 18+ Lock Screen CONTROLS system (`ControlWidget`), a different mechanism
/// from a Lock Screen WIDGET -- `JournalWidgetView`'s `.accessoryCircular` /
/// `.accessoryRectangular` / `.accessoryInline` families already cover the
/// widget stack above the clock; this is the two corner slots below it,
/// which only a `ControlWidget` can occupy.
///
/// This declaration does not put itself in either corner -- nothing can. He
/// adds it himself, once, from Customize Lock Screen (tap a corner slot,
/// pick "Cobux Journal"), exactly as he would swap in a different flashlight
/// or camera replacement today. Once added it is not lock-screen-only: the
/// same control also appears in Control Center and can be assigned to the
/// Action button, all for free from this one `ControlWidget` -- no separate
/// registration for each surface.
struct CobuxJournalControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.rajansharma.Cobux.journalControl"
        ) {
            // "square.and.pencil" -- the same glyph
            // `JournalWidgetView.lockScreenBody`'s `.accessoryCircular` case
            // already uses for "one glyph, nothing else. Tap here and you
            // are already writing," the shape he asked for by naming Snap's
            // camera control. Two different Lock Screen mechanisms, same
            // glyph, so the journal reads as one idea wherever he finds it.
            ControlWidgetButton(action: OpenJournalComposeIntent()) {
                Label("New Entry", systemImage: "square.and.pencil")
            }
        }
        .displayName("Cobux Journal")
        .description("Start a new journal entry")
    }
}
