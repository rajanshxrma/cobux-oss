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
/// - `widgetHighlightNextCards` — the cards drawn ahead for the cycle tap
///   (`WidgetHighlightCard`, JSON, at most `nextCardDepth`), and
///   `widgetHighlightShown` — the card last put on screen, which is both what
///   the tap's rebuild is served from and the provider's last good entry.
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
    // MARK: Pre-drawn next, and the tap trace (58)
    //
    // His fourth report of a dead cycle tap (12 Sep, on 57: "on clicking it
    // does not change the highlight. That's a big thing"). Every earlier fix
    // was to the Button layer; none could be verified here (no simulator, no
    // device logs from the widget process). Two changes, both evidence-first:
    //
    // 1. The tap no longer needs SwiftData. The provider, which has already
    //    opened the store to draw what is showing, draws the NEXT quote at the
    //    same time and parks its id here. The intent then only moves a
    //    pointer: no container, no context, no fetch in the ~30 MB widget
    //    process at tap time. The store path stays as the fallback.
    // 2. The intent leaves a trace -- when it last ran and what happened --
    //    that the app's Diagnostics screen shows. The next report carries the
    //    answer to the one question nobody could answer tonight: did the tap
    //    reach the intent at all.
    // MARK: Pre-drawn CARDS, and the card last shown (61)
    //
    // 58 parked only the next quote's ID. That made the tap store-free but
    // not the rebuild it triggers: the provider still had to open the
    // container to turn that ID into text, and to draw the following card,
    // before it could return -- and that is the whole length of the blink he
    // measured on 60 ("that blinking is taking a little bit of time"). What
    // is parked now is the full `WidgetHighlightCard`, so the rebuild after
    // a tap is a defaults read and nothing else. Two are kept, not one: the
    // refill after a fast build runs off the critical path, in a task that
    // outlives `timeline(for:)`, and a second card in hand means one lost
    // refill costs nothing -- the tap after it is still served from here.
    //
    // The card last shown is written on every successful build and by the
    // intent the instant it moves the pointer. It is the provider's fallback
    // when a build fails, replacing the placeholder -- see
    // `HighlightProvider.timeline(for:)` for the report that made it one.
    static let nextCardsKey = "widgetHighlightNextCards"
    static let shownCardKey = "widgetHighlightShown"
    /// 58's id-only key. Cleared on sight; a 60 install upgrading mid-lane
    /// takes one ordinary store-path tap and is then on cards.
    static let legacyNextIDKey = "widgetHighlightNext"
    /// How many cards a lane keeps drawn ahead.
    static let nextCardDepth = 2

    static let tapAtKey = "widgetTap.lastAt"
    static let tapOutcomeKey = "widgetTap.outcome"
    static let buildAtKey = "widgetBuild.lastAt"
    static let buildOutcomeKey = "widgetBuild.outcome"

    static func nextCards(scope: String?) -> [WidgetHighlightCard] {
        guard let data = defaults?.data(forKey: key(nextCardsKey, scope: scope)) else { return [] }
        return (try? JSONDecoder().decode([WidgetHighlightCard].self, from: data)) ?? []
    }

    /// Replaces the lane's pre-drawn cards, oldest-drawn first, capped at
    /// `nextCardDepth`. An empty array clears the key rather than storing
    /// `[]`, so a lane that has nothing drawn reads the same as one that
    /// never had anything.
    static func storeNext(_ cards: [WidgetHighlightCard], scope: String?) {
        let k = key(nextCardsKey, scope: scope)
        let kept = Array(cards.prefix(nextCardDepth))
        guard !kept.isEmpty, let data = try? JSONEncoder().encode(kept) else {
            defaults?.removeObject(forKey: k)
            return
        }
        defaults?.set(data, forKey: k)
    }

    /// Consumes the first pre-drawn card that is not `excluding` (the quote
    /// already showing) and may still be shown without the store, dropping
    /// any it passes over, so one tap can never be served twice from the
    /// same card and a card drawn before its book was switched off is never
    /// served at all.
    static func takeNext(scope: String?, excluding excludedID: UUID?) -> WidgetHighlightCard? {
        defaults?.removeObject(forKey: key(legacyNextIDKey, scope: scope))
        var remaining = nextCards(scope: scope)
        var taken: WidgetHighlightCard?
        while taken == nil, !remaining.isEmpty {
            let candidate = remaining.removeFirst()
            guard candidate.highlightID != excludedID, candidate.isShowableWithoutStore else { continue }
            taken = candidate
        }
        storeNext(remaining, scope: scope)
        return taken
    }

    /// The card the lane last put on screen -- the provider's last good entry.
    static func shownCard(scope: String?) -> WidgetHighlightCard? {
        guard let data = defaults?.data(forKey: key(shownCardKey, scope: scope)) else { return nil }
        return try? JSONDecoder().decode(WidgetHighlightCard.self, from: data)
    }

    static func storeShown(_ card: WidgetHighlightCard, scope: String?) {
        guard let data = try? JSONEncoder().encode(card) else { return }
        defaults?.set(data, forKey: key(shownCardKey, scope: scope))
    }

    static func trace(_ outcome: String) {
        defaults?.set(Date.now, forKey: tapAtKey)
        defaults?.set(outcome, forKey: tapOutcomeKey)
    }

    /// For the app's Diagnostics screen. Nil when no tap has ever reached an intent.
    static func lastTrace() -> (at: Date, outcome: String)? {
        guard let at = defaults?.object(forKey: tapAtKey) as? Date,
              let outcome = defaults?.string(forKey: tapOutcomeKey) else { return nil }
        return (at, outcome)
    }

    /// The provider's counterpart to `trace`: which path the last timeline
    /// build took ("card", "store", "last shown", "placeholder"). Separate keys
    /// from the tap trace so a rebuild never overwrites what the tap reported.
    /// Read by nothing in the app yet; parked here so the next report can be
    /// answered from the device rather than reasoned about.
    static func buildTrace(_ outcome: String) {
        defaults?.set(Date.now, forKey: buildAtKey)
        defaults?.set(outcome, forKey: buildOutcomeKey)
    }

    static func lastBuildTrace() -> (at: Date, outcome: String)? {
        guard let at = defaults?.object(forKey: buildAtKey) as? Date,
              let outcome = defaults?.string(forKey: buildOutcomeKey) else { return nil }
        return (at, outcome)
    }

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
