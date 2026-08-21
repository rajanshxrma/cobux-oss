import Foundation

/// The widget history's state machine, deliberately free of any storage: no
/// `UserDefaults`, no App Group, no SwiftData. `WidgetHighlightHistory` is the
/// thin persistence shell around this type, and this type is what the unit
/// tests exercise — the back/forward/rotation interleavings that broke the
/// chevrons are pure index math, and testing them through the real App-Group
/// suite would mean writing into Rajan's actual device state.
///
/// The invariant every mutation here protects: **the entry at `index` is
/// always the highlight the widget is currently showing.** Chevron visibility
/// is derived from `index`, so the moment those two drift apart the arrows
/// start describing a quote that isn't on screen and tapping them jumps
/// somewhere the user never was.
struct WidgetHistoryState: Equatable {
    /// Cap on retained history. Twenty steps back is far more than anyone
    /// walks on a home-screen widget, and it bounds the defaults payload.
    static let cap = 20

    /// How long a forward tail survives a passive rebuild. The problem this
    /// solves: the app calls `reloadAllTimelines` on ordinary events (saving a
    /// highlight), which can land seconds after the user tapped Back — without
    /// a hold, that rebuild would rotate them straight out of the tail they
    /// were standing in. Past this window the tail is treated as abandoned and
    /// a rotation may collapse it, which is what keeps the widget from
    /// freezing forever on a quote the user stepped back to once.
    static let forwardTailHoldWindow: TimeInterval = 30 * 60

    /// UUID strings of highlights the widget has shown, oldest first.
    private(set) var entries: [String]
    /// Position of the currently-shown highlight within `entries`.
    private(set) var index: Int
    /// When the user last drove navigation themselves (shuffle/back/forward).
    /// Passive rotations deliberately do NOT touch this — only a real tap
    /// earns a forward tail its protection window.
    private(set) var lastInteraction: Date?

    /// When this lane last changed what it is showing, by ANY route — a passive
    /// rotation, a shuffle, or a back/forward step. Unlike `lastInteraction`
    /// this is not about who caused it, only about when the visible quote last
    /// moved, because that is what the rotation clock is measured from.
    ///
    /// Why the clock exists: `WidgetCenter.reloadTimelines(ofKind:)` is the
    /// finest granularity WidgetKit offers — there is no per-instance reload —
    /// so a shuffle tap on ONE Book Wisdom widget rebuilds EVERY Book Wisdom
    /// widget on the home screen. Without a clock, each of those rebuilds would
    /// rotate, and tapping shuffle on a "Denial of Death" widget would silently
    /// throw away the unrelated quote showing on the all-books widget beside it.
    /// The same thing already happened on every `reloadAllTimelines` the app
    /// fires for ordinary events like saving a highlight.
    ///
    /// With the clock, rotation is time-driven rather than reload-driven: a
    /// rebuild that arrives before the interval has elapsed re-shows what is
    /// already there. That is both the fix for cross-widget churn and a closer
    /// match to what "rotates every two hours" was always supposed to mean.
    private(set) var lastShownAt: Date?

    init(
        entries: [String] = [],
        index: Int = 0,
        lastInteraction: Date? = nil,
        lastShownAt: Date? = nil
    ) {
        self.entries = entries
        self.index = entries.isEmpty ? 0 : min(max(index, 0), entries.count - 1)
        self.lastInteraction = lastInteraction
        self.lastShownAt = lastShownAt
    }

    var currentID: String? {
        entries.isEmpty ? nil : entries[index]
    }

    var canGoBack: Bool {
        !entries.isEmpty && index > 0
    }

    var canGoForward: Bool {
        !entries.isEmpty && index < entries.count - 1
    }

    /// Whether a passive rebuild must re-show `currentID` instead of rotating
    /// to a fresh pick. True only while an intact forward tail is still warm
    /// from a real tap.
    func shouldHoldForwardTail(now: Date) -> Bool {
        guard canGoForward, let lastInteraction else { return false }
        let elapsed = now.timeIntervalSince(lastInteraction)
        return elapsed >= 0 && elapsed < Self.forwardTailHoldWindow
    }

    /// Whether this rebuild arrived before the rotation interval was up, and so
    /// must re-show `currentID` instead of rotating. See `lastShownAt` for why
    /// this exists at all.
    ///
    /// An empty lane never holds (there is nothing to re-show), and a negative
    /// elapsed time — a clock moved backwards — never holds either, so the
    /// worst a bad timestamp can do is one extra rotation rather than a widget
    /// frozen forever on one quote.
    func shouldHoldRecentRotation(now: Date, interval: TimeInterval) -> Bool {
        guard currentID != nil, let lastShownAt else { return false }
        let elapsed = now.timeIntervalSince(lastShownAt)
        return elapsed >= 0 && elapsed < interval
    }

    /// When WidgetKit should next be asked to rebuild this lane: one interval
    /// after the visible quote last moved, never sooner than `minimumLead` from
    /// now so a held rebuild can't request a refresh date that is already past.
    ///
    /// Measuring from `lastShownAt` rather than from `now` is what keeps the
    /// schedule honest — otherwise every incidental reload would push the next
    /// real rotation another full interval into the future, and a widget on a
    /// busy home screen would drift toward never rotating at all.
    func nextRotationDate(now: Date, interval: TimeInterval, minimumLead: TimeInterval = 60) -> Date {
        let scheduled = (lastShownAt ?? now).addingTimeInterval(interval)
        return max(scheduled, now.addingTimeInterval(minimumLead))
    }

    /// A user-initiated jump to a fresh highlight (the shuffle button):
    /// browser-style, any forward tail is truncated and the pick appended.
    mutating func push(_ id: String, at date: Date) {
        append(id)
        lastInteraction = date
        lastShownAt = date
    }

    /// A passive rotation pick made by the provider. It appends
    /// unconditionally — including collapsing a forward tail — because by the
    /// time this is called the provider has already decided to put this
    /// highlight on screen, and a skipped append would leave `index` pointing
    /// at a different quote than the one being rendered. The decision of
    /// *whether* to rotate at all belongs to `shouldHoldForwardTail(now:)`,
    /// checked before the pick is made.
    ///
    /// Re-landing on the highlight already showing is a no-op rather than a
    /// duplicate entry: the position is already correct, and appending would
    /// manufacture a Back chevron that steps onto the identical quote. Only
    /// reachable when the library is too small for the exclusion filter to
    /// find anything else.
    mutating func recordRotation(_ id: String, at date: Date = .now) {
        // The rotation clock restarts either way: this build is what the user
        // sees from now on, whether or not the pick happened to land on the
        // quote already up. Only the history entry is conditional.
        defer { lastShownAt = date }
        guard id != currentID else { return }
        append(id)
    }

    @discardableResult
    mutating func goBack(at date: Date) -> Bool {
        guard canGoBack else { return false }
        index -= 1
        lastInteraction = date
        lastShownAt = date
        return true
    }

    @discardableResult
    mutating func goForward(at date: Date) -> Bool {
        guard canGoForward else { return false }
        index += 1
        lastInteraction = date
        lastShownAt = date
        return true
    }

    private mutating func append(_ id: String) {
        if !entries.isEmpty && index < entries.count - 1 {
            entries.removeSubrange((index + 1)...)
        }
        entries.append(id)
        if entries.count > Self.cap {
            entries.removeFirst(entries.count - Self.cap)
        }
        index = entries.count - 1
    }
}
