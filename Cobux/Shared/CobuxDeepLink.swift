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

    /// A book thread with the composer pre-filled.
    ///
    /// The existing prefill path only works by fetching a `Highlight` by id,
    /// so anything that is not a highlight -- a chapter's key lesson, a quiz
    /// question -- had no way to carry its text into chat. Those cards opened
    /// an empty book thread instead, which looks like the button did nothing
    /// useful. Percent-encoded as a query item so the existing
    /// `/book/<uuid>` path parsing is untouched.
    static func bookURL(bookID: UUID, prefill: String) -> URL {
        var components = URLComponents(string: "cobux://book/\(bookID.uuidString)")!
        components.queryItems = [URLQueryItem(name: "prefill", value: prefill)]
        return components.url ?? bookURL(bookID: bookID)
    }

    /// Share a specific highlight.
    ///
    /// The widget cannot present a share sheet itself: a WidgetKit extension
    /// only hosts `Button(intent:)`, `Link` and `.widgetURL`, and `ShareLink`
    /// inside one renders perfectly and does nothing at all. So the widget
    /// links here, the app opens, and the app does the sharing.
    static func shareHighlightURL(bookID: UUID, highlightID: UUID) -> URL {
        URL(string: "cobux://share/\(bookID.uuidString)/\(highlightID.uuidString)")!
    }

    /// The Quiz tab. Flow's "worth revisiting" card tells the user a Weak
    /// Spots session would hit the topic directly, then offered no way to get
    /// there -- a card whose whole content is an instruction to navigate
    /// should carry the navigation.
    static func quizURL() -> URL {
        URL(string: "cobux://quiz")!
    }

    /// Journal. `newEntry: true` opens the compose sheet on arrival rather
    /// than the list -- what the Journal widget's tap uses, so writing is one
    /// tap from the home screen instead of app → More → Journal → compose.
    /// Takes a passage of his own writing into the journal chat thread.
    ///
    /// Its own route rather than reusing the book prefill: `ContentView` parses
    /// `?prefill=` only under `host == "book"`, so a journal passage sent that
    /// way would silently lose its text and open an empty thread.
    static func journalChatURL(prefill: String) -> URL {
        var components = URLComponents()
        components.scheme = "cobux"
        components.host = "journal"
        components.path = "/chat"
        components.queryItems = [URLQueryItem(name: "prefill", value: prefill)]
        return components.url ?? URL(string: "cobux://journal")!
    }

    static func journalURL(newEntry: Bool = false) -> URL {
        URL(string: newEntry ? "cobux://journal/new" : "cobux://journal")!
    }
}


extension Notification.Name {
    /// "Open Flow, in place." Posted by any screen with a Flow button;
    /// handled by `ContentView`'s overlay so there is one open path and no
    /// system slide (build 60).
    static let cobuxOpenFlow = Notification.Name("com.rajansharma.Cobux.openFlow")
}
