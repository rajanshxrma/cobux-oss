import SwiftData
import Foundation

@Model
final class ChatMessage {
    var content: String
    var isUser: Bool
    var timestamp: Date
    var referencedBooks: [String]
    /// nil = the general "Cobux" thread; a Book's id = that book's own
    /// persistent, scoped thread. Additive field — every message from
    /// before this existed defaults to nil, which is exactly "general
    /// thread," so no migration or data loss for existing chat history.
    var bookID: UUID?
    /// A `Figure` surfaced alongside this reply, resolved AFTER the reply
    /// itself finished streaming (see `SearchService.relevantFigure` and
    /// `ChatView.completeReveal`) — never part of prompt context or citation
    /// parsing. Additive optional, same pattern as `bookID` above: every
    /// message from before this existed defaults to nil, which is exactly
    /// "no figure," so no migration or data loss for existing chat history.
    var referencedFigureID: UUID?

    init(content: String, isUser: Bool, timestamp: Date = .now, referencedBooks: [String] = [], bookID: UUID? = nil, referencedFigureID: UUID? = nil) {
        self.content = content
        self.isUser = isUser
        self.timestamp = timestamp
        self.referencedBooks = referencedBooks
        self.bookID = bookID
        self.referencedFigureID = referencedFigureID
    }
}
