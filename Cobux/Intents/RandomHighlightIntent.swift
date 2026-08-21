import AppIntents
import SwiftData
import Foundation

enum RandomHighlightIntentError: LocalizedError {
    case noContainer

    var errorDescription: String? {
        switch self {
        case .noContainer:
            return "Couldn't open your Cobux library. Try again from the app."
        }
    }
}

struct RandomHighlightIntent: AppIntent {
    static var title: LocalizedStringResource = "Random Highlight from Cobux"
    static var description = IntentDescription("Get a random highlight from your book library.")

    @Parameter(title: "Book", description: "Optional: limit to one book")
    var book: BookEntity?

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let container = CobuxSchema.makeAppGroupContainer() else {
            throw RandomHighlightIntentError.noContainer
        }

        let context = ModelContext(container)
        let allHighlights = (try? context.fetch(FetchDescriptor<Highlight>())) ?? []

        let pool: [Highlight]
        if let bookID = book?.id {
            pool = allHighlights.filter { $0.book?.id == bookID }
        } else {
            pool = allHighlights
        }

        guard let highlight = pool.randomElement() else {
            let message = "You don't have any highlights saved yet."
            return .result(value: message, dialog: IntentDialog(stringLiteral: message))
        }

        var citation = ""
        if let bookTitle = highlight.book?.title {
            citation = " — \(bookTitle)"
            if let chapter = highlight.chapter {
                citation += ", \(chapter)"
            }
        }

        let response = "\(highlight.text)\(citation)"
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}
