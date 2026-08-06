import AppIntents

struct CobuxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
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
    }
}
