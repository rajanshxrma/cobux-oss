import Foundation
import WidgetKit

/// Everything the Book Wisdom widget needs to DRAW one highlight, as a plain
/// value with no store behind it: the quote, its citation, its colour, and the
/// two ids the tap targets carry. Parked in App-Group defaults by
/// `WidgetHighlightHistory`, in two roles:
///
/// - **the pre-drawn next cards** (`storeNext`), so that a cycle tap is served
///   entirely from here -- the intent moves the pointer and the provider
///   builds the entry from this payload -- with no SwiftData container, no
///   context and no fetch anywhere between the tap and the new quote;
/// - **the card last shown** (`storeShown`), which is the provider's fallback
///   when a build fails: the last good entry, never the placeholder, once one
///   real quote has been on screen.
///
/// # Why a payload and not an id (61)
///
/// 58 pre-drew the next quote's ID so the intent could skip the store. That
/// fixed the tap; it did not fix the wait. His report on 60: "it blinks and
/// then it changes to a new one, that blinking is taking a little bit of
/// time". The blink is `invalidatableContent` dimming from the tap until the
/// new timeline lands, and the time was `timeline(for:)`: with only an ID in
/// hand it still had to open the app-group container, resolve that ID, and
/// draw the FOLLOWING card with random-offset fetches -- all before it could
/// return. Storing the whole display payload is what lets that build return
/// without touching the store at all. See `HighlightProvider.fastEntry`.
///
/// Deliberately `Codable` over `NSSecureCoding`: a JSON blob under one
/// defaults key per lane, a few KB at most (the text of two quotes), and a
/// decode failure is a `nil` that falls to the ordinary store path -- never a
/// crash in the widget process.
struct WidgetHighlightCard: Codable, Equatable {
    let highlightID: UUID
    let text: String
    let chapter: String?
    let bookID: UUID
    let title: String
    let author: String
    let coverColorHex: String

    init(highlightID: UUID, text: String, chapter: String?, bookID: UUID,
         title: String, author: String, coverColorHex: String) {
        self.highlightID = highlightID
        self.text = text
        self.chapter = chapter
        self.bookID = bookID
        self.title = title
        self.author = author
        self.coverColorHex = coverColorHex
    }

    /// Captures a fetched highlight while the store is open. `book` is passed
    /// explicitly rather than read off `highlight.book` here, so the one
    /// relationship fault this costs happens at the call site that already
    /// paid it, never a second time.
    init(highlight: Highlight, book: Book) {
        self.init(
            highlightID: highlight.id,
            text: highlight.text,
            chapter: highlight.chapter,
            bookID: book.id,
            title: book.title,
            author: book.author,
            coverColorHex: book.coverColorHex
        )
    }

    /// The timeline entry for this card. `state` is the lane's history at the
    /// moment of the build, so the chevrons describe the real position -- a
    /// card-built entry carries exactly the `canGoBack`/`canGoForward` a
    /// store-built one would.
    func entry(scopeBookID: UUID?, state: WidgetHistoryState, at date: Date = .now) -> HighlightEntry {
        HighlightEntry(
            date: date,
            quote: text,
            bookTitle: title,
            author: author,
            chapter: chapter,
            coverColorHex: coverColorHex,
            isPlaceholder: false,
            bookID: bookID,
            highlightID: highlightID,
            scopeBookID: scopeBookID,
            canGoBack: state.canGoBack,
            canGoForward: state.canGoForward
        )
    }

    /// Whether this card may still be shown, judged from defaults alone: the
    /// book has not been switched off in the app and the line has not been
    /// hidden in Flow since it was drawn. The two exclusions the pool applies
    /// at draw time, re-applied at show time without opening the store, so a
    /// pre-drawn card cannot resurrect either. (A highlight deleted or edited
    /// in the app between the draw and the tap shows its drawn text once; the
    /// next store build resolves the id afresh.)
    var isShowableWithoutStore: Bool {
        !WidgetHighlightPool.isHiddenWithoutStore(bookID: bookID, highlightID: highlightID)
    }
}
