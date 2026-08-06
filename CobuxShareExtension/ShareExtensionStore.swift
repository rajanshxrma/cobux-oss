import SwiftData

/// Opens the same App-Group `ModelContainer` the host app and `CaptureQuoteIntent` use —
/// factored out so `ShareViewController`/`ShareQuoteView` don't each carry their own copy of
/// the schema list.
enum ShareExtensionStore {
    static func makeContainer() -> ModelContainer? {
        try? ModelContainer(
            for: Book.self, Highlight.self, Chapter.self, ChatMessage.self, Theme.self,
            configurations: ModelConfiguration(groupContainer: .identifier("group.com.rajansharma.Cobux"))
        )
    }
}
