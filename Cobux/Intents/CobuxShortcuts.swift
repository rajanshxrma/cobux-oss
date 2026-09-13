import AppIntents

struct CobuxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: JournalEntryIntent(),
            phrases: [
                "Journal in \(.applicationName)",
                "New journal entry in \(.applicationName)",
                "Write in my \(.applicationName) journal"
            ],
            shortTitle: "Journal",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: AskCobuxIntent(),
            phrases: [
                "Ask \(.applicationName) a question"
            ],
            shortTitle: "Ask Cobux",
            systemImageName: "book.pages"
        )
        AppShortcut(
            intent: RandomHighlightIntent(),
            phrases: [
                "Give me a highlight from \(.applicationName)",
                "Random wisdom from \(.applicationName)"
            ],
            shortTitle: "Random Highlight",
            systemImageName: "quote.opening"
        )
        AppShortcut(
            intent: CaptureQuoteIntent(),
            phrases: [
                "Save a quote to \(.applicationName)",
                "Capture a quote in \(.applicationName)"
            ],
            shortTitle: "Capture Quote",
            systemImageName: "plus.circle"
        )
        // The durability bridge. iOS gives no app a way to write into Apple
        // Notes -- no Notes framework, no note entity in AppIntents -- so this
        // does the half that is possible: it hands the journal over as plain
        // text, and Apple's own "Create Note"/"Append to Note" actions put it
        // wherever the user points them. Listing it here is what makes it
        // findable at all: an App Intent with no `AppShortcut` is reachable
        // only by someone already searching Shortcuts for the app by name.
        AppShortcut(
            intent: JournalArchiveIntent(),
            // Both phrases describe what the intent ACTUALLY does, which is
            // hand back text. "Save my Cobux journal to Notes" was written here
            // first and removed: spoken bare to Siri it runs this intent, gets
            // a string, and saves nothing anywhere -- a phrase that promises the
            // destination while only producing the payload.
            phrases: [
                "Get my \(.applicationName) journal as text",
                "Get my \(.applicationName) journal entries as text"
            ],
            shortTitle: "Journal as Text",
            systemImageName: "note.text"
        )
    }
}
