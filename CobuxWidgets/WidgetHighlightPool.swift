import SwiftData
import Foundation

/// The one place the widget decides *which* highlight to show, shared by
/// `HighlightProvider` and `CycleHighlightIntent` so the two can't diverge.
///
/// Why not simply fetch a pool and call `randomElement()`: this runs in the
/// widget extension, which iOS kills at ~30MB regardless of device, and the
/// library holds thousands of highlights with multi-KB texts plus embedding
/// blobs. The previous implementation squared that circle with
/// `fetchLimit = 300` and no sort descriptor — but an unsorted limited fetch
/// returns the *same* implementation-ordered first 300 rows on every single
/// call, so the random pick was only ever random inside one frozen slice of
/// the library. Shuffling past a few dozen taps started repeating, and
/// highlights outside that slice could never appear at all.
///
/// The fix keeps the memory ceiling and gets real randomness: count the
/// matching rows, then fetch exactly one row at a random offset. Peak
/// materialization is a single `Highlight` (plus its `Book`) instead of 300,
/// so this is both strictly more random and strictly lighter than what it
/// replaces.
enum WidgetHighlightPool {
    /// How many independent draws before giving up on the exclusion/`book`
    /// filters and accepting whatever came back. Bounded so a library that is
    /// entirely orphaned highlights can't spin.
    private static let maxDraws = 5

    private static var reminderPredicate: Predicate<Highlight> {
        #Predicate<Highlight> { $0.isReminder == true }
    }

    // Keyed off `Book.id` (a stable stored `UUID`) rather than
    // `.persistentModelID`, matching `BookCard.loadHighlightCount` — the same
    // traversal, for the same reason its comment gives: persistent-identifier
    // traversal inside `#Predicate` has macro-support quirks across SDK
    // versions, and this form is already proven in this codebase.
    private static func reminderPredicate(bookID: UUID) -> Predicate<Highlight> {
        #Predicate<Highlight> { $0.isReminder == true && $0.book?.id == bookID }
    }

    private static func bookPredicate(bookID: UUID) -> Predicate<Highlight> {
        #Predicate<Highlight> { $0.book?.id == bookID }
    }

    /// A uniformly random highlight from the FULL reminder-flagged set, falling
    /// back to the full library when nothing is flagged — the same
    /// reminders-first, all-highlights-fallback preference the widget has
    /// always had, just sampled across everything that matches instead of a
    /// fixed prefix.
    ///
    /// `bookID` narrows every stage of that ladder to one book, for a widget
    /// the user configured to a single book via `SelectBookIntent`. `nil` (the
    /// default, and what an unconfigured widget always passes) is the whole
    /// library, byte-for-byte the behavior that shipped before this feature.
    ///
    /// If a configured book yields nothing — it was deleted, or it is a book
    /// the user added but hasn't put any highlights in yet — this falls all the
    /// way through to the whole library rather than returning nil. A widget
    /// that quietly shows the wrong scope is recoverable and still useful; a
    /// widget that goes blank looks broken and gives the user nothing to act
    /// on. The citation line names the book every entry actually came from, so
    /// the fallback is visible rather than silent.
    ///
    /// `excluding` keeps two consecutive picks off the identical quote; it is
    /// a preference, not a guarantee, so a one-highlight library still shows
    /// something rather than silently going blank.
    static func randomHighlight(
        in context: ModelContext,
        bookID: UUID? = nil,
        excluding excludedID: UUID? = nil
    ) -> Highlight? {
        if let bookID {
            if let scoped = randomHighlight(in: context, matching: reminderPredicate(bookID: bookID), excluding: excludedID)
                ?? randomHighlight(in: context, matching: bookPredicate(bookID: bookID), excluding: excludedID) {
                return scoped
            }
        } else {
            // Whole-library case: pick a BOOK first, then a highlight inside
            // it. See `randomBookID`'s doc comment for why sampling a
            // highlight directly from the full pool (the previous behavior)
            // is what made "books don't change much" a real bug, not a
            // perception issue.
            if let pickedBookID = randomBookID(in: context, excludingBookID: excludedBookID(for: excludedID, in: context)),
               let picked = randomHighlight(in: context, matching: reminderPredicate(bookID: pickedBookID), excluding: excludedID)
                ?? randomHighlight(in: context, matching: bookPredicate(bookID: pickedBookID), excluding: excludedID) {
                return picked
            }
        }
        return randomHighlight(in: context, matching: reminderPredicate, excluding: excludedID)
            ?? randomHighlight(in: context, matching: nil, excluding: excludedID)
    }

    /// Picks a book uniformly at random from among books that currently have
    /// at least one highlight, instead of sampling a highlight directly from
    /// the combined pool of every book's highlights.
    ///
    /// The old whole-library path drew a random ROW from every matching
    /// highlight, which is uniform per-HIGHLIGHT, not per-BOOK: a book with
    /// 40 highlights was 40x likelier to come up than one with 1. Worse,
    /// `Highlight.init` and `AddHighlightView`'s own toggle both default
    /// `isReminder` to true (unlike `CaptureQuoteIntent`'s Siri/share
    /// capture, which sets it false), so the reminder-flagged pool this
    /// method draws from first skews hard toward whatever book is currently
    /// being read and manually highlighted -- exactly Rajan's report that
    /// "books dont change a lot." Sampling the book first makes every book
    /// equally likely regardless of how many highlights it has.
    ///
    /// `excludingBookID` -- the book the just-shown highlight came from -- is
    /// a preference, not a guarantee: a one-book library still returns that
    /// book rather than nil, the same shape `randomHighlight`'s own
    /// `excluding` already has.
    private static func randomBookID(in context: ModelContext, excludingBookID: UUID?) -> UUID? {
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        guard !books.isEmpty else { return nil }

        // `fetchCount` is a SQL COUNT -- no highlight rows materialize --
        // so this stays well inside the widget extension's memory ceiling
        // even run once per book, the same reasoning `hasHighlights` above
        // already relies on.
        // Books the user switched off in the app must not surface here.
        // Read from App-Group defaults, since `@AppStorage` in the app writes
        // to `UserDefaults.standard`, which this extension is a separate
        // process from and cannot see -- that invisibility is precisely why
        // turned-off books kept appearing in the widget.
        let excluded = BookSourceSharing.excludedBookIDs()
        let eligible = books.filter { book in
            guard !excluded.contains(book.id) else { return false }
            return (try? context.fetchCount(FetchDescriptor<Highlight>(predicate: bookPredicate(bookID: book.id)))).map { $0 > 0 } ?? false
        }
        guard !eligible.isEmpty else { return nil }

        let candidates = eligible.count > 1 ? eligible.filter { $0.id != excludingBookID } : eligible
        return (candidates.isEmpty ? eligible : candidates).randomElement()?.id
    }

    /// The book the just-shown highlight belongs to, if any -- resolved fresh
    /// each call rather than threaded through as a parameter, since every
    /// caller of `randomHighlight` already only has the highlight's `UUID`
    /// (from `WidgetHistoryState.currentID`), not its book.
    private static func excludedBookID(for excludedID: UUID?, in context: ModelContext) -> UUID? {
        guard let excludedID else { return nil }
        var descriptor = FetchDescriptor<Highlight>(predicate: #Predicate<Highlight> { $0.id == excludedID })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.book?.id
    }

    /// Whether a configured book can currently supply the widget at all.
    ///
    /// The provider needs this to tell two situations apart that otherwise look
    /// identical: a book-scoped lane whose stored history is genuinely stale
    /// (the pointer must be rejected and a fresh in-book pick made), versus a
    /// book-scoped lane that has been running on the whole-library fallback
    /// above because the book has nothing in it (the pointer is legitimate and
    /// back/forward must keep working). A `fetchCount` is a SQL COUNT — no rows
    /// materialize — so this costs effectively nothing on a build that already
    /// opens the container.
    static func hasHighlights(bookID: UUID, in context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<Highlight>(predicate: bookPredicate(bookID: bookID))
        return (try? context.fetchCount(descriptor)).map { $0 > 0 } ?? false
    }

    private static func randomHighlight(
        in context: ModelContext,
        matching predicate: Predicate<Highlight>?,
        excluding excludedID: UUID?
    ) -> Highlight? {
        let countDescriptor = FetchDescriptor<Highlight>(predicate: predicate)
        guard let total = try? context.fetchCount(countDescriptor), total > 0 else { return nil }

        // An explicit sort is what makes `fetchOffset` mean anything: it gives
        // the rows a defined order to be the Nth of. Any total order works
        // since the offset itself is the randomness.
        var fallback: Highlight?
        for _ in 0..<maxDraws {
            var descriptor = FetchDescriptor<Highlight>(
                predicate: predicate,
                sortBy: [SortDescriptor(\Highlight.dateAdded, order: .forward)]
            )
            descriptor.fetchOffset = Int.random(in: 0..<total)
            descriptor.fetchLimit = 1
            guard let candidate = (try? context.fetch(descriptor))?.first else { continue }

            // A highlight with no book can't render (title/author/colour all
            // come from it), so it never counts as the fallback either.
            guard let candidateBook = candidate.book else { continue }

            // The exclusion check lives HERE, at the single point every path
            // funnels through, not only in `randomBookID`. It was in the
            // book-picking path alone, so the two paths that skip it -- a
            // book-scoped pick and the final whole-pool fallback -- both went on
            // serving books he had switched off. Reported as "I have two of the
            // biology books turned off for my app, but I still see their
            // highlights in my iOS widget."
            guard !BookSourceSharing.excludedBookIDs().contains(candidateBook.id) else { continue }
            fallback = fallback ?? candidate
            if candidate.id != excludedID { return candidate }
        }
        return fallback
    }

    /// Resolves a specific id — used for the one-shot override armed by the
    /// shuffle/back/forward intents. A single-row fetch, so a stale or deleted
    /// pointer costs nothing and simply returns nil.
    ///
    /// `requiringBookID` is the guard for a book-scoped widget: a lane can hold
    /// ids that no longer belong to its scope (the user configured a widget to
    /// a then-empty book, the lane ran on the whole-library fallback, and the
    /// book has since gained highlights). Rejecting those here means the very
    /// next build makes a fresh in-book pick instead of stepping back onto a
    /// quote from a book the widget is no longer supposed to be showing.
    static func highlight(
        with id: UUID,
        in context: ModelContext,
        requiringBookID requiredBookID: UUID? = nil
    ) -> Highlight? {
        var descriptor = FetchDescriptor<Highlight>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let highlight = (try? context.fetch(descriptor))?.first,
              let book = highlight.book else { return nil }
        if let requiredBookID, book.id != requiredBookID { return nil }
        // Every replay path — the back/forward chevrons and the hold-current
        // rebuild — resolves through here with an id captured BEFORE the book was
        // switched off. Without this, turning a book off stopped it being picked
        // fresh but left it reachable in history, so it kept reappearing and stuck
        // until the lane rotated past it. Rejecting it here makes the next build
        // pick something eligible instead.
        if BookSourceSharing.excludedBookIDs().contains(book.id) { return nil }
        return highlight
    }
}
