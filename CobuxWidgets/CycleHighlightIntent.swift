import AppIntents
import WidgetKit
import SwiftData
import Foundation

/// Backs the widget's small shuffle button (`CobuxWidgetEntryView`) -- lets a tap
/// swap the displayed highlight in place, without leaving the home screen, while
/// the rest of the widget's tap area keeps opening the app to the shown book via
/// `.widgetURL` exactly as before. Pushes the newly-picked highlight onto this
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
    @Parameter(title: "Book")
    var scopeKey: String?

    init() {}

    init(scopeKey: String?) {
        self.scopeKey = scopeKey
    }

    func perform() async throws -> some IntentResult {
        guard let container = CobuxSchema.makeAppGroupContainer() else { return .result() }
        let context = ModelContext(container)

        // Shares `WidgetHighlightPool` with `HighlightProvider` so the two
        // can't diverge on which highlights are eligible. The pool samples
        // across the whole reminder-flagged set (falling back to the whole
        // library) with a count-then-random-offset fetch, narrowed to the
        // configured book when there is one, and excludes the currently-shown
        // highlight so two consecutive taps can't land on the identical quote.
        guard let picked = WidgetHighlightPool.randomHighlight(
            in: context,
            bookID: scopeKey.flatMap(UUID.init(uuidString:)),
            excluding: WidgetHighlightHistory.currentID(scope: scopeKey)
        ) else { return .result() }
        WidgetHighlightHistory.push(picked.id, scope: scopeKey)
        StreakTracker.recordActivityToday()

        // Kind-wide is the only granularity WidgetKit offers, so this rebuilds
        // every Book Wisdom widget, not just the tapped one. The other widgets
        // survive it unchanged: their own lanes have no override armed, and
        // their rotation clocks haven't run out, so they re-show what they were
        // already showing (`HighlightProvider.resolveHighlight`, case 3).
        WidgetCenter.shared.reloadTimelines(ofKind: "CobuxHighlightWidget")
        return .result()
    }
}
