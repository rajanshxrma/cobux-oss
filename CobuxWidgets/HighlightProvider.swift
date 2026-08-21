import WidgetKit
import SwiftData
import SwiftUI
import AppIntents
import Foundation

struct HighlightEntry: TimelineEntry {
    let date: Date
    let quote: String
    let bookTitle: String
    let author: String
    let chapter: String?
    let coverColorHex: String
    let isPlaceholder: Bool
    /// nil for the placeholder entry (no real book behind it). A real entry
    /// always has one -- carried into the tap target so opening the widget
    /// lands on the book the shown quote actually came from, not just the
    /// generic Chat tab.
    let bookID: UUID?
    /// The specific highlight being shown, carried into the tap target so the
    /// app can pre-fill the composer with this exact quote. The ID travels,
    /// not the text: it keeps the URL short and lets the main app look the
    /// quote up in the real store rather than trusting a string round-tripped
    /// through a URL. nil for the placeholder entry.
    let highlightID: UUID?
    /// The book THIS widget was configured to via `SelectBookIntent`, or nil
    /// for the whole library. Distinct from `bookID`, which is whatever book
    /// the shown quote happens to come from — on an all-books widget `bookID`
    /// changes every rotation while this stays nil.
    ///
    /// It rides on the entry because the entry is the only channel the view has
    /// to the configuration, and the view is where the interactive intents are
    /// constructed with their scope baked in. See `CobuxWidgetEntryView`.
    var scopeBookID: UUID? = nil
    /// Whether `WidgetHighlightHistory` has entries behind/ahead of the current
    /// position at build time -- drives the visibility of the back/forward
    /// chevrons so they only appear when tapping them would actually do
    /// something.
    var canGoBack: Bool = false
    var canGoForward: Bool = false
}

/// Builds the Book Wisdom widget's timeline, now per-configuration.
///
/// `AppIntentTimelineProvider` rather than `TimelineProvider` is what gives the
/// build access to the user's own `SelectBookIntent` — the book they chose in
/// the widget's edit sheet — so a widget scoped to one book draws every entry
/// from that book, while an unconfigured widget behaves exactly as it always
/// did. Both live side by side on the same home screen without interfering,
/// because every piece of state this provider reads or writes is keyed by
/// `configuration.scopeKey`.
struct HighlightProvider: AppIntentTimelineProvider {
    typealias Entry = HighlightEntry
    typealias Intent = SelectBookIntent

    static let refreshInterval: TimeInterval = 2 * 60 * 60

    /// A defensive bound on how many per-book variants the widget gallery
    /// offers. Newest books first, because the case Rajan described — "maybe
    /// it's a new book, and they only want highlights from that book" — is
    /// exactly the one where scrolling a long alphabetical list is the worst.
    private static let recommendationLimit = 8

    func placeholder(in context: Context) -> HighlightEntry {
        HighlightEntry(
            date: .now,
            quote: "To stand up straight with your shoulders back is to accept the terrible responsibility of life, with eyes wide open.",
            bookTitle: "12 Rules for Life",
            author: "Jordan B. Peterson",
            chapter: "Rule 1",
            coverColorHex: "#D97706",
            isPlaceholder: true,
            bookID: nil,
            highlightID: nil
        )
    }

    func snapshot(for configuration: SelectBookIntent, in context: Context) async -> HighlightEntry {
        makeEntry(for: configuration, isSnapshot: true) ?? placeholder(in: context)
    }

    /// One entry per timeline, refreshed on the rotation interval.
    ///
    /// This used to pre-build eight entries spaced two hours apart, and that is
    /// what broke the chevrons. History lives in App-Group defaults and can
    /// only be written while the extension is running, so entries 1...7 -- the
    /// quotes actually on screen for fourteen of every sixteen hours -- were
    /// never recorded anywhere. Their `canGoBack`/`canGoForward` stayed false,
    /// so the arrows simply vanished after the first two hours, and the stored
    /// index went on pointing at entry 0's quote, so a Back tap jumped relative
    /// to something the user hadn't seen since that morning.
    ///
    /// A single entry makes every rotation a real build, which is the only
    /// moment history can be kept honest. The cost is one timeline reload every
    /// two hours (twelve a day, comfortably inside WidgetKit's budget for a
    /// widget that's actually on a Home Screen) instead of one every sixteen.
    ///
    /// The refresh date is measured from when this lane's quote last moved, not
    /// from now — see `WidgetHistoryState.nextRotationDate`. Every reload of the
    /// kind (including ones triggered by a *different* widget's shuffle tap)
    /// lands here, and anchoring to "now" would let those reloads push the real
    /// rotation indefinitely into the future.
    func timeline(for configuration: SelectBookIntent, in context: Context) async -> Timeline<HighlightEntry> {
        guard let entry = makeEntry(for: configuration, isSnapshot: false) else {
            // Nothing renderable yet — an empty library, or a container that
            // wouldn't open. Retry on the ordinary cadence rather than backing
            // off, so the widget fills itself in once content exists.
            return Timeline(
                entries: [placeholder(in: context)],
                policy: .after(Date().addingTimeInterval(Self.refreshInterval))
            )
        }
        let state = WidgetHighlightHistory.load(scope: configuration.scopeKey)
        return Timeline(
            entries: [entry],
            policy: .after(state.nextRotationDate(now: .now, interval: Self.refreshInterval))
        )
    }

    /// The widget gallery's pre-configured variants: the whole library first
    /// (the default, and what plain "Book Wisdom" has always meant), then one
    /// ready-made per-book widget for the most recently added books. Picking
    /// one of these is the "choose the book at the beginning of adding" path;
    /// the edit sheet's `Book` picker remains the way to reach any other book
    /// or to change one later.
    func recommendations() -> [AppIntentRecommendation<SelectBookIntent>] {
        var recommendations = [
            AppIntentRecommendation(intent: SelectBookIntent(), description: Text("Whole Library"))
        ]
        guard let container = CobuxSchema.makeAppGroupContainer() else { return recommendations }
        let context = ModelContext(container)

        var descriptor = FetchDescriptor<Book>(
            sortBy: [SortDescriptor(\Book.dateAdded, order: .reverse)]
        )
        descriptor.fetchLimit = Self.recommendationLimit
        let books = (try? context.fetch(descriptor)) ?? []
        for book in books {
            let entity = BookEntity(id: book.id, title: book.title, author: book.author)
            recommendations.append(
                AppIntentRecommendation(
                    intent: SelectBookIntent(book: entity),
                    description: Text(book.title)
                )
            )
        }
        return recommendations
    }

    private func makeEntry(for configuration: SelectBookIntent, isSnapshot: Bool) -> HighlightEntry? {
        guard let container = CobuxSchema.makeAppGroupContainer() else { return nil }
        let context = ModelContext(container)
        let scopeKey = configuration.scopeKey

        guard let resolved = resolveHighlight(for: configuration, in: context, isSnapshot: isSnapshot),
              let book = resolved.highlight.book else { return nil }
        let highlight = resolved.highlight

        // Chevron visibility is read AFTER the resolution above has settled
        // history, so it always describes the quote being returned here -- and
        // is suppressed outright in the one case where it can't
        // (`describesShownHighlight == false`), rather than rendering arrows
        // that point somewhere off screen.
        let state = resolved.describesShownHighlight
            ? WidgetHighlightHistory.load(scope: scopeKey)
            : WidgetHistoryState()
        return HighlightEntry(
            date: .now,
            quote: highlight.text,
            bookTitle: book.title,
            author: book.author,
            chapter: highlight.chapter,
            coverColorHex: book.coverColorHex,
            isPlaceholder: false,
            bookID: book.id,
            highlightID: highlight.id,
            scopeBookID: configuration.scopeBookID,
            canGoBack: state.canGoBack,
            canGoForward: state.canGoForward
        )
    }

    /// Picks the highlight this build will render, and leaves this
    /// configuration's `WidgetHighlightHistory` lane pointing at exactly that
    /// highlight.
    ///
    /// Four cases, in order:
    ///
    /// 1. **An override is armed on this lane** -- the user just tapped
    ///    shuffle, back, or forward on a widget with this configuration.
    ///    History is already at the right position; show it and touch nothing.
    ///    A stale/deleted/out-of-scope pointer falls through.
    /// 2. **A warm forward tail** -- the user stepped Back recently and a
    ///    rebuild fired underneath them (the app calls `reloadAllTimelines` on
    ///    ordinary events like saving a highlight). Re-show where they are
    ///    rather than rotating away, so the tail they're standing in survives.
    /// 3. **The rotation interval hasn't elapsed** -- this rebuild is not this
    ///    lane's scheduled rotation. It is somebody else's: another Book Wisdom
    ///    widget's shuffle tap reloads the whole kind, and so does the app on
    ///    ordinary events. Re-show rather than rotate, which is what keeps two
    ///    differently-configured widgets from yanking each other's quote around.
    /// 4. **A passive rotation** -- pick fresh from this configuration's pool,
    ///    excluding what's showing, and record it. Recording is not conditional
    ///    on the history's shape: this pick is going on screen, so the stored
    ///    position must move with it or the chevrons start describing a
    ///    different quote. (The lone no-op is re-landing on the highlight
    ///    already showing, which leaves the position correct by definition.)
    ///
    /// Snapshot builds never mutate history at all -- a gallery render must not
    /// consume an override or push a rotation the user never saw. That is the
    /// single case where history cannot describe what's rendered, and it
    /// reports `describesShownHighlight: false` so the caller hides the
    /// chevrons instead of showing stale ones.
    private func resolveHighlight(
        for configuration: SelectBookIntent,
        in context: ModelContext,
        isSnapshot: Bool,
        now: Date = .now
    ) -> (highlight: Highlight, describesShownHighlight: Bool)? {
        let scopeKey = configuration.scopeKey
        let scopeBookID = configuration.scopeBookID

        // Membership in the configured book is only enforced while that book
        // can actually supply highlights. A widget pointed at a book with none
        // yet runs on the whole-library fallback (see
        // `WidgetHighlightPool.randomHighlight`), and its lane legitimately
        // holds ids from other books -- rejecting those would break its
        // back/forward for no gain.
        let requiredBookID: UUID? = {
            guard let scopeBookID,
                  WidgetHighlightPool.hasHighlights(bookID: scopeBookID, in: context) else { return nil }
            return scopeBookID
        }()

        if let targetID = WidgetHighlightHistory.overrideTarget(scope: scopeKey, peek: isSnapshot),
           let target = WidgetHighlightPool.highlight(with: targetID, in: context, requiringBookID: requiredBookID) {
            return (target, true)
        }

        let state = WidgetHighlightHistory.load(scope: scopeKey)
        let currentID = state.currentID.flatMap(UUID.init(uuidString:))

        let holds = state.shouldHoldForwardTail(now: now)
            || state.shouldHoldRecentRotation(now: now, interval: Self.refreshInterval)
        if holds,
           let heldID = currentID,
           let held = WidgetHighlightPool.highlight(with: heldID, in: context, requiringBookID: requiredBookID) {
            return (held, true)
        }

        guard let picked = WidgetHighlightPool.randomHighlight(
            in: context,
            bookID: scopeBookID,
            excluding: currentID
        ) else { return nil }

        guard !isSnapshot else { return (picked, false) }
        WidgetHighlightHistory.recordRotation(picked.id, scope: scopeKey, at: now)
        return (picked, true)
    }
}
