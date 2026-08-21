import Foundation

/// The single reader/writer for the widget's highlight-history state, shared by
/// `HighlightProvider`, `CycleHighlightIntent`, `PreviousHighlightIntent`, and
/// `NextHighlightIntent`. All the index math lives in `WidgetHistoryState`;
/// this type is only the App-Group `UserDefaults` shell around it:
///
/// - `widgetHighlightHistory` — UUID strings of highlights the widget has shown,
///   oldest first, capped at `WidgetHistoryState.cap`.
/// - `widgetHighlightHistoryIndex` — position of the currently-shown highlight.
/// - `widgetHighlightHistoryInteractedAt` — when the user last drove navigation
///   themselves, which is what gives a forward tail its protection window.
/// - `widgetHighlightHistoryShownAt` — when the visible quote last moved by any
///   route, which is what the rotation clock is measured from.
/// - `widgetHistoryOverride` — one-shot flag: when set, the very next timeline
///   build's "now" entry resolves `history[index]` instead of a fresh pick,
///   then the flag clears so normal rotation resumes.
///
/// Keeping every mutation in this one type is what stops the intents and the
/// provider from drifting apart on key names or index semantics.
///
/// # Lanes
///
/// Every entry point takes a `scope`: `nil` for a widget showing the whole
/// library, or a book's UUID string for a widget configured to one book
/// (`SelectBookIntent`). Each scope gets its own independent set of the keys
/// above — its own lane — so a "Denial of Death" widget and an all-books widget
/// on the same home screen shuffle past each other without ever touching each
/// other's position, forward tail, or one-shot override.
///
/// **Granularity is per-configuration, not per-widget-instance, and that is
/// deliberate.** WidgetKit exposes no stable identifier for an individual
/// installed widget to an `AppIntent`, so per-instance lanes are not something
/// that can be built honestly here. Per-configuration is also the behavior the
/// precedent Rajan named actually has: two Notes widgets pointed at the same
/// folder show the same rotation, they do not diverge. Two all-books Cobux
/// widgets therefore share one lane exactly as they did before this feature
/// existed, and any number of widgets on the same book share that book's lane.
///
/// **The all-books lane deliberately reuses the pre-existing key names with no
/// suffix.** That is the whole migration story: a widget installed before this
/// feature has no configured book, so it reads and writes the identical
/// defaults keys it always did, and its history survives the update untouched.
/// Only book-scoped lanes introduce new keys.
enum WidgetHighlightHistory {
    static let historyKey = "widgetHighlightHistory"
    static let indexKey = "widgetHighlightHistoryIndex"
    static let interactedAtKey = "widgetHighlightHistoryInteractedAt"
    static let shownAtKey = "widgetHighlightHistoryShownAt"
    static let overrideKey = "widgetHistoryOverride"
    /// The key the pre-history shuffle implementation used; cleared on sight so
    /// upgraded installs don't carry a stale pin forever.
    static let legacyPinnedIDKey = "widgetPinnedHighlightID"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: CobuxSchema.appGroupID)
    }

    /// `nil`/empty scope maps to the bare key — see the type's doc comment for
    /// why that exact choice is what makes existing widgets need no migration.
    private static func key(_ base: String, scope: String?) -> String {
        guard let scope, !scope.isEmpty else { return base }
        return "\(base).\(scope)"
    }

    static func load(scope: String?) -> WidgetHistoryState {
        let entries = defaults?.stringArray(forKey: key(historyKey, scope: scope)) ?? []
        let index = defaults?.integer(forKey: key(indexKey, scope: scope)) ?? 0
        let interactedAt = defaults?.object(forKey: key(interactedAtKey, scope: scope)) as? Date
        let shownAt = defaults?.object(forKey: key(shownAtKey, scope: scope)) as? Date
        return WidgetHistoryState(
            entries: entries,
            index: index,
            lastInteraction: interactedAt,
            lastShownAt: shownAt
        )
    }

    private static func save(_ state: WidgetHistoryState, scope: String?, armingOverride: Bool) {
        defaults?.set(state.entries, forKey: key(historyKey, scope: scope))
        defaults?.set(state.index, forKey: key(indexKey, scope: scope))
        if let lastInteraction = state.lastInteraction {
            defaults?.set(lastInteraction, forKey: key(interactedAtKey, scope: scope))
        }
        if let lastShownAt = state.lastShownAt {
            defaults?.set(lastShownAt, forKey: key(shownAtKey, scope: scope))
        }
        if armingOverride {
            defaults?.set(true, forKey: key(overrideKey, scope: scope))
        }
    }

    static func currentID(scope: String?) -> UUID? {
        load(scope: scope).currentID.flatMap(UUID.init(uuidString:))
    }

    /// A user-initiated jump to a fresh highlight (the shuffle button): any
    /// forward tail is truncated, the new id appended, and the one-shot
    /// override armed so the next timeline build shows it immediately.
    ///
    /// The override is armed on THIS lane only, which is what keeps a shuffle
    /// on one widget from being consumed by a different widget's rebuild —
    /// `reloadTimelines(ofKind:)` rebuilds every Book Wisdom widget, but only
    /// the lane that armed the flag finds it set.
    static func push(_ id: UUID, scope: String?, at date: Date = .now) {
        var state = load(scope: scope)
        state.push(id.uuidString, at: date)
        save(state, scope: scope, armingOverride: true)
    }

    /// A passive rotation pick the provider is about to render. Recorded so
    /// Back can return to it later, but WITHOUT arming the override — the
    /// provider is mid-build and already showing this pick.
    ///
    /// Unlike the original implementation this never silently skips: the
    /// provider asks `shouldHoldForwardTail(now:)` *before* picking, so by the
    /// time this is called the pick is going on screen no matter what, and
    /// refusing to record it would leave the stored index pointing at a
    /// different quote than the one rendered — which is exactly how the
    /// chevrons desynced from the visible highlight.
    static func recordRotation(_ id: UUID, scope: String?, at date: Date = .now) {
        var state = load(scope: scope)
        state.recordRotation(id.uuidString, at: date)
        save(state, scope: scope, armingOverride: false)
    }

    /// Steps back one entry. Pure index math — deliberately no SwiftData access
    /// so the Back intent stays fast and memory-safe in the widget process.
    @discardableResult
    static func goBack(scope: String?, at date: Date = .now) -> Bool {
        var state = load(scope: scope)
        guard state.goBack(at: date) else { return false }
        save(state, scope: scope, armingOverride: true)
        return true
    }

    /// Steps forward through a tail left by Back. Only ever re-advances over
    /// already-seen highlights — landing on something new is shuffle's job.
    @discardableResult
    static func goForward(scope: String?, at date: Date = .now) -> Bool {
        var state = load(scope: scope)
        guard state.goForward(at: date) else { return false }
        save(state, scope: scope, armingOverride: true)
        return true
    }

    /// Timeline-build read of the override. `peek` (snapshot builds) reports the
    /// target without clearing the flag, so a gallery/snapshot render can't eat
    /// the override the real timeline build is about to honor.
    static func overrideTarget(scope: String?, peek: Bool) -> UUID? {
        // Lane-independent, and cheap: one legacy key from before history
        // existed at all, cleared on whichever build sees it first.
        defaults?.removeObject(forKey: legacyPinnedIDKey)
        guard defaults?.bool(forKey: key(overrideKey, scope: scope)) == true else { return nil }
        if !peek {
            defaults?.removeObject(forKey: key(overrideKey, scope: scope))
        }
        return currentID(scope: scope)
    }
}
