import Foundation

/// The one place `cobux://book/<uuid>/highlight/<uuid>` gets built, shared
/// between the main app's widget-tap handling (`ContentView.onOpenURL`), the
/// widget's own `.widgetURL` (`CobuxWidgetEntryView.tapDestination`), and now
/// the Flow/widget share buttons -- three call sites had been hand-building
/// this exact string independently before this existed, which is exactly how
/// a future path change (adding a query param, say) silently updates two of
/// three and breaks the third. Lives in `Cobux/Shared` (not `Cobux/Services`)
/// because the widget extension target needs it too, same reasoning as
/// `WatchPayload.swift` already living here for the Watch target.
enum CobuxDeepLink {
    static func highlightURL(bookID: UUID, highlightID: UUID) -> URL {
        URL(string: "cobux://book/\(bookID.uuidString)/highlight/\(highlightID.uuidString)")!
    }

    static func bookURL(bookID: UUID) -> URL {
        URL(string: "cobux://book/\(bookID.uuidString)")!
    }
}
