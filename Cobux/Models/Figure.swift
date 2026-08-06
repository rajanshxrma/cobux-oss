import SwiftData
import Foundation

@Model
final class Figure {
    var fileName: String
    var page: Int
    var caption: String
    var dateAdded: Date
    var book: Book?
    var chapter: Chapter?

    init(fileName: String, page: Int, caption: String, dateAdded: Date = .now, book: Book? = nil, chapter: Chapter? = nil) {
        self.fileName = fileName
        self.page = page
        self.caption = caption
        self.dateAdded = dateAdded
        self.book = book
        self.chapter = chapter
    }
}
