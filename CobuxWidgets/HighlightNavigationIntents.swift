import AppIntents
import WidgetKit
import Foundation

/// Backs the widget's back chevron — returns to the previously shown highlight
/// after a shuffle (or a passive rotation) replaced it. Pure
/// `WidgetHighlightHistory` index math: no SwiftData container is opened, so
/// the intent is instant and immune to the widget process's memory ceiling. A
/// stale/deleted id resolves through the provider's existing
/// fallback-to-random path on the rebuild.
///
/// `scopeKey` identifies which history lane to walk, and reaches this intent the
/// same way it reaches `CycleHighlightIntent` — baked into the instance the view
/// hands `Button(intent:)`, so a back tap on a book-scoped widget steps through
/// that book's history and nothing else. See `CycleHighlightIntent` for why that
/// mechanism, and why a plain `String?`.
struct PreviousHighlightIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Previous Highlight"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Book")
    var scopeKey: String?

    init() {}

    init(scopeKey: String?) {
        self.scopeKey = scopeKey
    }

    func perform() async throws -> some IntentResult {
        if WidgetHighlightHistory.goBack(scope: scopeKey) {
            WidgetHighlightHistory.trace("back")
            StreakTracker.recordActivityToday()
            WidgetCenter.shared.reloadTimelines(ofKind: "CobuxHighlightWidget")
        }
        return .result()
    }
}

/// Backs the widget's forward chevron — re-advances through the history tail
/// that Back stepped out of. Only visible when such a tail exists; landing on
/// a brand-new highlight stays the shuffle button's job.
struct NextHighlightIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Next Highlight"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Book")
    var scopeKey: String?

    init() {}

    init(scopeKey: String?) {
        self.scopeKey = scopeKey
    }

    func perform() async throws -> some IntentResult {
        if WidgetHighlightHistory.goForward(scope: scopeKey) {
            WidgetHighlightHistory.trace("forward")
            StreakTracker.recordActivityToday()
            WidgetCenter.shared.reloadTimelines(ofKind: "CobuxHighlightWidget")
        }
        return .result()
    }
}
