import AppIntents
import SwiftData
import WidgetKit
import Foundation

enum CaptureQuoteIntentError: LocalizedError {
    case noContainer
    case bookNotFound

    var errorDescription: String? {
        switch self {
        case .noContainer:
            return "Couldn't open your Cobux library. Try again from the app."
        case .bookNotFound:
            return "Couldn't find that book in your Cobux library."
        }
    }
}

struct CaptureQuoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture Quote to Cobux"
    static var description = IntentDescription("Save a quote to a book in your Cobux library.")

    @Parameter(title: "Quote")
    var quote: String

    @Parameter(title: "Book")
    var book: BookEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let container = try? ModelContainer(
            for: Book.self, Highlight.self, Chapter.self, ChatMessage.self, Theme.self,
            configurations: ModelConfiguration(groupContainer: .identifier("group.com.rajansharma.Cobux"))
        ) else {
            throw CaptureQuoteIntentError.noContainer
        }

        let context = ModelContext(container)
        let bookID = book.id
        var bookDescriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookID })
        bookDescriptor.fetchLimit = 1
        guard let fetchedBook = (try? context.fetch(bookDescriptor))?.first else {
            throw CaptureQuoteIntentError.bookNotFound
        }

        let highlight = Highlight(text: quote, isReminder: false)
        highlight.book = fetchedBook
        fetchedBook.highlights.append(highlight)

        try context.save()

        SpotlightIndexer.index(highlight)

        WidgetCenter.shared.reloadAllTimelines()
        CrossProcessSync.markDirty()

        let message = "Saved to \(fetchedBook.title)."
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}
