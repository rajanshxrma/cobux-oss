import SwiftUI

@main
struct CobuxWatchApp: App {
    var body: some Scene {
        WindowGroup {
            CobuxWatchContentView()
                // `CobuxWatchGlanceEntryView`'s `.widgetURL` alone already makes a
                // complication tap launch this app (that's what actually fixes
                // "tap does nothing") -- this handler exists so a future
                // multi-screen version has somewhere to route to instead of a
                // silent no-op. Deliberately does nothing further today: the app
                // is one screen, and `CobuxWatchContentView` is already that
                // screen regardless of how it was opened.
                .onOpenURL { _ in }
        }
    }
}
