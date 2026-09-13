import Foundation

/// The two routes the Messages extension's "Ask Cobux" pane needs, kept out of
/// `CobuxDeepLink.swift` so that file's ownership stays with the app/widget
/// lanes. Both hosts are ALREADY parsed by `ContentView.onOpenURL` --
/// `"chat"` selects the Chat tab, `"settings"` opens Settings -- so nothing on
/// the app side had to change for these to work; they only name what the
/// pane had been unable to reach.
///
/// Why the pane needs them at all: the conversation it holds is deliberately
/// a window onto the app's general thread (each finished turn is written into
/// the shared store, see `MessagesPaneModel.persist`), so "Open in Cobux" is
/// "continue this exact thread with the library attached", and the missing-key
/// line's link lands on the one screen where the key can be entered.
extension CobuxDeepLink {
    /// The general Chat tab.
    static func chatURL() -> URL {
        URL(string: "cobux://chat")!
    }

    /// Settings, where the Anthropic API key lives.
    static func settingsURL() -> URL {
        URL(string: "cobux://settings")!
    }
}
