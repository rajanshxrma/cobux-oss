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

        // A COUNT, then ONE row at a random offset -- `WatchSyncService.
        // randomFeaturedHighlight`'s primitive. This used to fetch the entire
        // highlight table (~33,000 rows, each with a 2 KB embedding) into the
        // Siri intents extension -- a process with a memory ceiling a fraction
        // of the app's -- and filter it in Swift to pick one line. The pool is
        // unchanged: every highlight, or every highlight of the named book
        // (`$0.book?.id == bookID` is the form `WisdomProbe` already proved).
        let pool: FetchDescriptor<Highlight>
        if let bookID = book?.id {
            pool = FetchDescriptor<Highlight>(predicate: #Predicate<Highlight> { $0.book?.id == bookID })
        } else {
            pool = FetchDescriptor<Highlight>()
        }

        var highlight: Highlight?
        if let total = try? context.fetchCount(pool), total > 0 {
            var draw = pool
            draw.fetchOffset = Int.random(in: 0..<total)
            draw.fetchLimit = 1
            highlight = try? context.fetch(draw).first
        }

        guard let highlight else {
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
