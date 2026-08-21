import AppIntents
import Foundation

/// The Book Wisdom widget's configuration surface — what iOS shows when you
/// long-press the widget and tap "Edit Widget", the same sheet Notes uses to
/// pick a folder and Reminders uses to pick a list.
///
/// One optional parameter, deliberately. Unset means "my whole library", which
/// is exactly what the widget did before it was configurable, so:
///
/// - a widget installed before this feature keeps working untouched. WidgetKit
///   migrates a `StaticConfiguration` widget to an `AppIntentConfiguration` of
///   the same `kind` by handing the provider a default-initialized intent, and
///   a default-initialized `SelectBookIntent` has `book == nil`. No migration
///   step, no user action, no empty widget;
/// - the default for a *newly* added widget is also the whole library, so
///   nothing about the add flow gets harder for someone who doesn't care about
///   scoping.
///
/// `BookEntity`/`BookEntityQuery` (Cobux/Intents/BookEntity.swift, compiled into
/// this extension too — see project.yml) supply the picker's contents from the
/// real App-Group store, so the list is the actual library rather than a
/// hardcoded set.
///
/// Not discoverable in Shortcuts: a widget configuration intent has no meaning
/// outside the widget's edit sheet, and `RandomHighlightIntent` already covers
/// "give me a quote, optionally from this book" as a real Shortcuts action.
struct SelectBookIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Book Wisdom"
    static var description = IntentDescription(
        "Rotate through every highlight in your library, or keep this widget on a single book."
    )
    static var isDiscoverable: Bool = false

    @Parameter(
        title: "Book",
        description: "Leave this empty to rotate through your whole library."
    )
    var book: BookEntity?

    init() {}

    init(book: BookEntity?) {
        self.book = book
    }

    /// The scope this configuration resolves to: `nil` = the whole library.
    ///
    /// This is also the identity the widget's history lane is keyed by, so it
    /// must stay a plain value read off the configuration and nothing more —
    /// see `WidgetHighlightHistory` for why per-configuration (not
    /// per-literal-widget) is the right granularity.
    ///
    /// A configured book that has since been deleted resolves to `nil` here
    /// (its `EntityQuery` can no longer produce the entity), which degrades to
    /// the whole library rather than to a blank widget.
    var scopeBookID: UUID? { book?.id }

    /// Storage/serialization form of `scopeBookID`. The interactive intents
    /// carry this as a plain `String?` rather than a `BookEntity?` on purpose —
    /// see `CycleHighlightIntent`.
    var scopeKey: String? { book?.id.uuidString }
}
