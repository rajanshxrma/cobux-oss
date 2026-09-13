import AppIntents
import WidgetKit
import SwiftData
import Foundation

/// Backs every tap on the highlight widget's home families
/// (`CobuxWidgetEntryView`) -- the quote, the citation, the accent bar, the
/// opening-quote glyph, the divider, and every inset and gap around them, each
/// its own adjacent, non-overlapping cycle button -- swapping the displayed
/// highlight in place without leaving the home screen. There is deliberately no
/// full-frame catch-all behind the content: builds 52 and 53 both shipped one
/// as a `.background` Button labelled `Color.clear`, and he reported the tap
/// dead on both. See `CobuxWidgetEntryView.body` for why, and for what replaced
/// it. Only the arrow in `controlCluster` and the
/// Share link open the app; the home families deliberately set no `.widgetURL`,
/// since that is what turns every pixel no Button covers into a launch. (The
/// lock-screen accessory families do keep `.widgetURL`: too small for two
/// targets. That is a ruling, not a leftover.) Pushes the newly-picked highlight onto this
/// widget's `WidgetHighlightHistory` lane (truncating any forward tail,
/// browser-style, and arming the one-shot override `HighlightProvider` honors on
/// its next timeline build), then asks WidgetKit to reload immediately so the
/// change is visible right away instead of waiting for the next 2-hour rotation.
///
/// # How this tap knows which book it was for
///
/// This is the part of a configurable interactive widget that is easy to get
/// subtly wrong. An `AppIntent` fired from a widget button runs detached from
/// any timeline build: `perform()` gets no `Context`, no configuration, and no
/// identifier for the widget that was tapped. Reading the "current book" from
/// shared storage would be a guess, and a wrong one the moment a user has an
/// all-books widget and a book-scoped one on the same screen.
///
/// The mechanism that actually works is `Button(intent:)`'s own parameter
/// capture. WidgetKit serializes the *instance* passed to `Button(intent:)` —
/// including its `@Parameter` values — into the rendered timeline entry, and on
/// tap it decodes and performs that exact instance. So the view constructs
/// `CycleHighlightIntent(scopeKey: entry.scopeBookID?.uuidString)` from the
/// configuration the provider already resolved for that entry, and the scope
/// arrives here as data rather than being inferred. Each widget's button
/// carries its own widget's book, because each widget rendered its own entry.
///
/// `scopeKey` is a plain `String?`, not a `BookEntity?`, on purpose. An entity
/// parameter round-trips through `BookEntityQuery` on every tap — a SwiftData
/// fetch before `perform()` even starts, which can fail or resolve to nil while
/// the store is busy and would silently turn a book-scoped shuffle into an
/// all-books one. A raw UUID string cannot fail to decode, costs nothing, and is
/// never shown to anyone: this intent is not user-facing, which is also why it
/// is no longer discoverable in Shortcuts. It was listed there before this
/// change, but "Show Another Highlight" as a Shortcuts action only ever reloaded
/// a widget timeline, and listing it now would surface a raw-UUID text field.
/// `RandomHighlightIntent` is the real, and much better, Shortcuts equivalent.
struct CycleHighlightIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Another Highlight"
    static var isDiscoverable: Bool = false

    /// nil = the whole library (an unconfigured widget). Otherwise the
    /// configured book's UUID string, which is both the pool filter and the
    /// history lane key.
    @Parameter(title: "Book", default: "")
    // NON-OPTIONAL since 59 (his fifth report, on 59: "tapping on widget
    // opens app"). A tap that opens the app is WidgetKit's fallback for a
    // region with no interactive control -- the button was drawn but never
    // registered. The one thing these three intents carry that the working
    // QuickCheck buttons do not is an OPTIONAL parameter; WidgetKit has to
    // encode the intent into the archived button when it draws the widget,
    // and an optional String left nil is the encoding most likely to fail
    // silently. Empty string means "no scope"; `scope` maps it back to nil
    // for the history lane, so every lane key is unchanged.
    var scopeKey: String

    init() {}

    init(scopeKey: String?) {
        self.scopeKey = scopeKey ?? ""
    }

    private var scope: String? { scopeKey.isEmpty ? nil : scopeKey }

    func perform() async throws -> some IntentResult {
        WidgetHighlightHistory.trace("started")
        // Fast path (58): the provider pre-drew the next quote when it built
        // what is showing. Moving the pointer is all a tap has to do.
        if let next = WidgetHighlightHistory.takeNext(scope: scope),
           next != WidgetHighlightHistory.currentID(scope: scope) {
            WidgetHighlightHistory.push(next, scope: scope)
            StreakTracker.recordActivityToday()
            WidgetHighlightHistory.trace("pre-drawn")
            WidgetCenter.shared.reloadTimelines(ofKind: "CobuxHighlightWidget")
            return .result()
        }
        guard let container = CobuxSchema.makeAppGroupContainer() else {
            WidgetHighlightHistory.trace("no container")
            return .result()
        }
        let context = ModelContext(container)
        guard let picked = WidgetHighlightPool.randomHighlight(
            in: context,
            bookID: scope.flatMap(UUID.init(uuidString:)),
            excluding: WidgetHighlightHistory.currentID(scope: scope)
        ) else {
            WidgetHighlightHistory.trace("no pick")
            return .result()
        }
        WidgetHighlightHistory.push(picked.id, scope: scope)
        StreakTracker.recordActivityToday()
        WidgetHighlightHistory.trace("picked from store")
        WidgetCenter.shared.reloadTimelines(ofKind: "CobuxHighlightWidget")
        return .result()
    }
}
