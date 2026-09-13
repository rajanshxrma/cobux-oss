import WidgetKit
import SwiftUI

@main
struct CobuxWidgetBundle: WidgetBundle {
    var body: some Widget {
        CobuxHighlightWidget()
        CobuxQuickCheckWidget()
        CobuxJournalWidget()
        CobuxQuizLiveActivity()
        // Lock Screen Controls / Control Center / Action Button -- a
        // `ControlWidget` is a distinct mechanism from the widgets above but
        // registers the same way, straight in this bundle. See
        // `JournalControl.swift` for the "bottom-right camera, bottom-left
        // flashlight" ask this answers.
        CobuxJournalControl()
    }
}
