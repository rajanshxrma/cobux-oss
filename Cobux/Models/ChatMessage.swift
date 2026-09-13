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
    /// Sentence vector for cross-conversation retrieval, set at send time.
    ///
    /// Only ever populated for USER messages, and that is a design decision
    /// rather than an optimization. Indexing Cobux's own replies would mean
    /// two things it must not do: a reply written while the real-names toggle
    /// was on has the name spelled out, so retrieving it later re-injects that
    /// name regardless of the current setting; and feeding the app its own past
    /// opinions about him lets one bad framing reinforce itself until it
    /// becomes his permanent record. Cobux remembers what he told it, not what
    /// it told him.
    ///
    /// Additive optional, same pattern as `bookID` and `referencedFigureID`
    /// above: every message from before this existed defaults to nil, which is
    /// exactly "not indexed yet," so no migration and no data loss.
    var embeddingData: Data?
    /// Images attached to this (user) message, as `ChatImageStore` ids.
    /// Additive optional, the standing migration pattern -- old rows decode
    /// nil, meaning "no images", which is exactly true of them.
    var imageIDs: [UUID]?

    init(content: String, isUser: Bool, timestamp: Date = .now, referencedBooks: [String] = [], bookID: UUID? = nil, referencedFigureID: UUID? = nil) {
        self.content = content
        self.isUser = isUser
        self.timestamp = timestamp
        self.referencedBooks = referencedBooks
        self.bookID = bookID
        self.referencedFigureID = referencedFigureID
    }

    /// Packs/unpacks `embeddingData` as a `[Float]`, identical to
    /// `PersonalWritingEntry.embedding` and `Highlight.embedding` --
    /// deliberately not reinvented.
    var embedding: [Float]? {
        get {
            guard let embeddingData else { return nil }
            // See `Highlight.embedding` -- one shared, unaligned-safe bulk
            // decoder rather than three copies of a per-element load.
            return EmbeddingCodec.decode(embeddingData)
        }
        set {
            guard let newValue else {
                embeddingData = nil
                return
            }
            embeddingData = newValue.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }
}
