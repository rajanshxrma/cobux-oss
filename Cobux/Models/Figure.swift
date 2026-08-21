import SwiftData
import Foundation

@Model
final class Figure {
    /// Additive field, same pattern as `Book.id`/`Chapter.id`/`Highlight.id`: a
    /// default-valued stored property needs no migration. Added so a chat
    /// reply can reference a specific figure by a stable id
    /// (`ChatMessage.referencedFigureID`) instead of the object itself.
    var id: UUID = UUID()
    var fileName: String
    var page: Int
    var caption: String
    var dateAdded: Date
    var book: Book?
    var chapter: Chapter?

    init(fileName: String, page: Int, caption: String, dateAdded: Date = .now, book: Book? = nil, chapter: Chapter? = nil) {
        self.id = UUID()
        self.fileName = fileName
        self.page = page
        self.caption = caption
        self.dateAdded = dateAdded
        self.book = book
        self.chapter = chapter
    }
}
