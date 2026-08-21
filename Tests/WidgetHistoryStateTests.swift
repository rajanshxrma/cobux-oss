import XCTest

/// Covers the widget's back/forward state machine, which cannot be verified by
/// watching a Home Screen widget rotate on its two-hour timer. `WidgetHistoryState`
/// is compiled into this bundle directly (see project.yml) and is storage-free,
/// so none of this touches the real App-Group defaults.
///
/// The invariant under test throughout: **after any operation, `currentID` is
/// the highlight the widget is showing.** The reported bug -- chevrons that
/// appear when they shouldn't, and jump somewhere unrelated when tapped -- was
/// this invariant breaking, not the arrow drawing.
final class WidgetHistoryStateTests: XCTestCase {
    private let a = "A", b = "B", c = "C", d = "D"
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Basics

    func testEmptyStateOffersNoNavigation() {
        let state = WidgetHistoryState()
        XCTAssertNil(state.currentID)
        XCTAssertFalse(state.canGoBack)
        XCTAssertFalse(state.canGoForward)
        XCTAssertFalse(state.shouldHoldForwardTail(now: t0))
    }

    func testOutOfRangeStoredIndexIsClamped() {
        // Defaults can hold an index left by an older, longer history.
        let state = WidgetHistoryState(entries: [a, b], index: 97)
        XCTAssertEqual(state.currentID, b)
        XCTAssertFalse(state.canGoForward)
    }

    func testRotationBecomesTheCurrentEntrySoBackHasSomewhereToGo() {
        var state = WidgetHistoryState()
        state.recordRotation(a)
        XCTAssertEqual(state.currentID, a)
        XCTAssertFalse(state.canGoBack)

        state.recordRotation(b)
        XCTAssertEqual(state.currentID, b)
        XCTAssertTrue(state.canGoBack)
        XCTAssertFalse(state.canGoForward)
    }

    func testPushTruncatesTheForwardTailBrowserStyle() {
        var state = WidgetHistoryState()
        state.recordRotation(a)
        state.recordRotation(b)
        state.recordRotation(c)
        state.goBack(at: t0)
        XCTAssertEqual(state.currentID, b)
        XCTAssertTrue(state.canGoForward)

        state.push(d, at: t0)
        XCTAssertEqual(state.currentID, d)
        XCTAssertFalse(state.canGoForward)
        XCTAssertEqual(state.entries, [a, b, d])
    }

    func testHistoryIsCappedAndKeepsTheNewestEntryCurrent() {
        var state = WidgetHistoryState()
        for i in 0...(WidgetHistoryState.cap + 5) {
            state.recordRotation("id-\(i)")
        }
        XCTAssertEqual(state.entries.count, WidgetHistoryState.cap)
        XCTAssertEqual(state.currentID, "id-\(WidgetHistoryState.cap + 5)")
        XCTAssertTrue(state.canGoBack)
        XCTAssertFalse(state.canGoForward)
    }

    // MARK: - The reported bug

    /// A rebuild firing while the user is standing in a *warm* forward tail
    /// must not rotate them out of it -- the app calls `reloadAllTimelines` on
    /// ordinary events like saving a highlight, and that used to land seconds
    /// after a Back tap.
    func testWarmForwardTailIsHeldAgainstPassiveRotation() {
        var state = WidgetHistoryState()
        state.recordRotation(a)
        state.recordRotation(b)
        state.goBack(at: t0)

        XCTAssertTrue(state.shouldHoldForwardTail(now: t0.addingTimeInterval(60)))
        XCTAssertTrue(state.shouldHoldForwardTail(
            now: t0.addingTimeInterval(WidgetHistoryState.forwardTailHoldWindow - 1)
        ))
    }

    /// ...but the hold expires, or the widget would freeze forever on whatever
    /// the user last stepped back to.
    func testForwardTailStopsBeingHeldOnceItGoesCold() {
        var state = WidgetHistoryState()
        state.recordRotation(a)
        state.recordRotation(b)
        state.goBack(at: t0)

        XCTAssertFalse(state.shouldHoldForwardTail(
            now: t0.addingTimeInterval(WidgetHistoryState.forwardTailHoldWindow)
        ))
        XCTAssertFalse(state.shouldHoldForwardTail(now: t0.addingTimeInterval(2 * 60 * 60)))
    }

    func testPassiveRotationNeverEarnsATailItsHoldWindow() {
        // Only a real tap sets `lastInteraction`; a rotation that happens to
        // leave a tail (it can't, but the guard shouldn't depend on that) must
        // not protect one.
        var state = WidgetHistoryState(entries: [a, b], index: 0, lastInteraction: nil)
        XCTAssertTrue(state.canGoForward)
        XCTAssertFalse(state.shouldHoldForwardTail(now: t0))

        state.recordRotation(c)
        XCTAssertNil(state.lastInteraction)
    }

    /// The old `recordRotation` returned early whenever a forward tail existed,
    /// leaving `index` on one highlight while the provider rendered another.
    /// A cold-tail rotation must now collapse the tail and take the position.
    func testColdTailRotationCollapsesTailAndTakesThePosition() {
        var state = WidgetHistoryState()
        state.recordRotation(a)
        state.recordRotation(b)
        state.recordRotation(c)
        state.goBack(at: t0)
        XCTAssertEqual(state.currentID, b)

        state.recordRotation(d)
        XCTAssertEqual(state.currentID, d, "history must point at the quote actually rendered")
        XCTAssertFalse(state.canGoForward, "forward chevron must not offer a tail that no longer exists")
        XCTAssertTrue(state.canGoBack)

        state.goBack(at: t0)
        XCTAssertEqual(state.currentID, b, "Back returns to what the user was last looking at")
    }

    func testRotationOntoTheShownHighlightDoesNotManufactureAChevron() {
        // Only reachable on a library too small for the exclusion filter to
        // find anything else; a duplicate entry would give Back an arrow that
        // steps onto the identical quote.
        var state = WidgetHistoryState()
        state.recordRotation(a)
        state.recordRotation(a)
        XCTAssertEqual(state.entries, [a])
        XCTAssertFalse(state.canGoBack)
        XCTAssertEqual(state.currentID, a)
    }

    // MARK: - Full traced sequence

    /// shuffle -> rotation -> back -> rotation-while-tail-live -> forward,
    /// asserting at every step that the position matches what is on screen.
    func testShuffleRotateBackRotateForwardKeepsPositionAndScreenInAgreement() {
        var state = WidgetHistoryState()
        var shown: String?

        // 1. User taps shuffle. Override arms; provider renders history[index].
        state.push(a, at: t0)
        shown = state.currentID
        XCTAssertEqual(shown, a)
        XCTAssertFalse(state.canGoBack)
        XCTAssertFalse(state.canGoForward)

        // 2. Two hours pass; a passive rotation picks B. No tail, so it records.
        let t1 = t0.addingTimeInterval(2 * 60 * 60)
        XCTAssertFalse(state.shouldHoldForwardTail(now: t1))
        state.recordRotation(b)
        shown = b
        XCTAssertEqual(state.currentID, shown)
        XCTAssertTrue(state.canGoBack, "back chevron appears because A is genuinely behind B")
        XCTAssertFalse(state.canGoForward)

        // 3. User taps Back. Now showing A, with B ahead.
        XCTAssertTrue(state.goBack(at: t1))
        shown = state.currentID
        XCTAssertEqual(shown, a)
        XCTAssertTrue(state.canGoForward)

        // 4. The app saves a highlight a minute later and reloads timelines.
        //    The tail is warm, so the provider re-shows the current entry
        //    instead of picking fresh -- screen unchanged, history unchanged.
        let t2 = t1.addingTimeInterval(60)
        XCTAssertTrue(state.shouldHoldForwardTail(now: t2))
        XCTAssertEqual(state.currentID, shown)
        XCTAssertTrue(state.canGoForward, "the tail the user is standing in survives the rebuild")

        // 5. User taps Forward, landing back on B.
        XCTAssertTrue(state.goForward(at: t2))
        shown = state.currentID
        XCTAssertEqual(shown, b)
        XCTAssertTrue(state.canGoBack)
        XCTAssertFalse(state.canGoForward)

        // 6. Much later a rotation picks C. No tail left to protect; it records
        //    and both chevron states still describe what's rendered.
        let t3 = t2.addingTimeInterval(4 * 60 * 60)
        XCTAssertFalse(state.shouldHoldForwardTail(now: t3))
        state.recordRotation(c)
        XCTAssertEqual(state.currentID, c)
        XCTAssertEqual(state.entries, [a, b, c])
        XCTAssertTrue(state.canGoBack)
        XCTAssertFalse(state.canGoForward)
    }

    // MARK: - The rotation clock
    //
    // Added with the configurable (per-book) widget. Once two independently
    // configured Book Wisdom widgets can sit on one Home Screen, every shuffle
    // tap rebuilds BOTH of them -- `WidgetCenter.reloadTimelines(ofKind:)` is
    // the finest granularity WidgetKit offers. Without a clock, tapping shuffle
    // on a book-scoped widget would rotate the all-books widget beside it to an
    // unrelated quote. Rotation therefore has to be time-driven, not
    // reload-driven, and that decision lives here in the storage-free state.

    private let interval: TimeInterval = 2 * 60 * 60

    func testAFreshLaneHasNoClockAndRotatesImmediately() {
        let state = WidgetHistoryState(entries: [a], index: 0)
        XCTAssertFalse(state.shouldHoldRecentRotation(now: t0, interval: interval))
    }

    func testARebuildInsideTheIntervalReShowsInsteadOfRotating() {
        var state = WidgetHistoryState()
        state.recordRotation(a, at: t0)
        XCTAssertTrue(state.shouldHoldRecentRotation(now: t0.addingTimeInterval(60), interval: interval))
        XCTAssertTrue(state.shouldHoldRecentRotation(now: t0.addingTimeInterval(interval - 1), interval: interval))
    }

    func testTheIntervalItselfRotates() {
        var state = WidgetHistoryState()
        state.recordRotation(a, at: t0)
        XCTAssertFalse(state.shouldHoldRecentRotation(now: t0.addingTimeInterval(interval), interval: interval))
    }

    func testAClockMovedBackwardsRotatesRatherThanFreezing() {
        // The failure mode worth designing against: a bad timestamp that makes
        // every future rebuild hold forever, leaving the widget stuck on one
        // quote with no way for the user to tell why.
        var state = WidgetHistoryState()
        state.recordRotation(a, at: t0)
        XCTAssertFalse(state.shouldHoldRecentRotation(now: t0.addingTimeInterval(-3600), interval: interval))
    }

    func testEveryUserTapRestartsTheClock() {
        // A shuffle nearly a full interval after the last rotation must not be
        // rotated away seconds later -- the user just chose that quote.
        var state = WidgetHistoryState()
        state.recordRotation(a, at: t0)
        let late = t0.addingTimeInterval(interval - 60)
        state.push(b, at: late)
        XCTAssertTrue(state.shouldHoldRecentRotation(now: late.addingTimeInterval(120), interval: interval))

        XCTAssertTrue(state.goBack(at: late.addingTimeInterval(180)))
        XCTAssertTrue(state.shouldHoldRecentRotation(now: late.addingTimeInterval(200), interval: interval))

        XCTAssertTrue(state.goForward(at: late.addingTimeInterval(240)))
        XCTAssertTrue(state.shouldHoldRecentRotation(now: late.addingTimeInterval(260), interval: interval))
    }

    func testRotationOntoTheShownHighlightStillRestartsTheClock() {
        // A one-highlight library re-picks the same quote every time. That is
        // still a completed rotation, so the clock must restart -- otherwise
        // every subsequent rebuild would re-rotate and the exclusion logic
        // would churn for nothing.
        var state = WidgetHistoryState()
        state.recordRotation(a, at: t0)
        state.recordRotation(a, at: t0.addingTimeInterval(interval))
        XCTAssertEqual(state.entries, [a], "no duplicate entry, as before")
        XCTAssertTrue(
            state.shouldHoldRecentRotation(now: t0.addingTimeInterval(interval + 60), interval: interval)
        )
    }

    func testNextRotationIsMeasuredFromTheLastMoveNotFromNow() {
        // Anchoring to `now` would let incidental reloads push the next real
        // rotation another full interval away each time, so a widget on a busy
        // Home Screen would drift toward never rotating at all.
        var state = WidgetHistoryState()
        state.recordRotation(a, at: t0)
        let next = state.nextRotationDate(now: t0.addingTimeInterval(60), interval: interval)
        XCTAssertEqual(next.timeIntervalSince1970, t0.addingTimeInterval(interval).timeIntervalSince1970, accuracy: 1)
    }

    func testNextRotationIsNeverInThePast() {
        var state = WidgetHistoryState()
        state.recordRotation(a, at: t0)
        let farFuture = t0.addingTimeInterval(10 * interval)
        XCTAssertGreaterThan(state.nextRotationDate(now: farFuture, interval: interval), farFuture)
    }

    func testAFreshLaneSchedulesOneIntervalOut() {
        let state = WidgetHistoryState()
        let next = state.nextRotationDate(now: t0, interval: interval)
        XCTAssertEqual(next.timeIntervalSince1970, t0.addingTimeInterval(interval).timeIntervalSince1970, accuracy: 1)
    }
}
