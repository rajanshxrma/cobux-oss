import XCTest
@testable import Cobux

/// Guards Keeps and Asks.
///
/// The whole point of this feature is what it refuses to do: the app never
/// decides a passage is worth keeping, never writes the question, never checks
/// whether it was answered, and never grades the return. These tests are mostly
/// about that.
@MainActor
final class JournalKeepTests: XCTestCase {
    /// Never `UserDefaults.standard`: these tests clear the whole list, and the
    /// real list is the names Rajan asked never to see again.
    private var suite: UserDefaults!
    private var suiteName: String!

    private func useIsolatedQuietWordStore() {
        suiteName = "cobux.tests.quietwords.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        JournalQuietWords.store = suite
    }

    private func restoreQuietWordStore() {
        suite.removePersistentDomain(forName: suiteName)
        JournalQuietWords.store = .standard
        suite = nil
        suiteName = nil
    }

    override func setUp() {
        super.setUp()
        useIsolatedQuietWordStore()
    }

    override func tearDown() {
        restoreQuietWordStore()
        super.tearDown()
    }


    private func day(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: n, to: Date())!
    }

    func testANewKeepIsNotDueImmediately() {
        let keep = JournalKeep(entryID: UUID(), passage: "a line", sourceDate: day(-400))
        XCTAssertFalse(keep.isDue(), "keeping something is not a reason to hand it back the same day")
    }

    func testFirstRungIsSevenDays() {
        let keep = JournalKeep(entryID: UUID(), passage: "a line", sourceDate: day(-400))
        XCTAssertFalse(keep.isDue(now: day(6)))
        XCTAssertTrue(keep.isDue(now: day(7)))
    }

    /// The ladder widens, and the last rung repeats forever — a thing worth
    /// keeping does not expire.
    func testLadderWidensAndNeverRetires() {
        let keep = JournalKeep(entryID: UUID(), passage: "a line", sourceDate: day(-400))
        var seen: [Int] = []
        for _ in 0..<6 {
            seen.append(JournalKeep.ladder[min(keep.rung, JournalKeep.ladder.count - 1)])
            keep.markSurfaced()
        }
        XCTAssertEqual(seen, [7, 21, 60, 180, 180, 180])
    }

    /// Advancing is TIME, never performance. There is no correct or missed.
    func testAdvancingDependsOnlyOnBeingShown() {
        let keep = JournalKeep(entryID: UUID(), passage: "a line", sourceDate: day(-400))
        keep.markSurfaced(now: day(0))
        XCTAssertEqual(keep.rung, 1)
        XCTAssertFalse(keep.isDue(now: day(20)))
        XCTAssertTrue(keep.isDue(now: day(21)))
    }

    /// The question is his or absent. The model has no way to generate one.
    func testAKeepCarriesOnlyHisOwnQuestion() {
        let plain = JournalKeep(entryID: UUID(), passage: "a line", sourceDate: day(-30))
        XCTAssertNil(plain.question)
        let asked = JournalKeep(entryID: UUID(), passage: "a line", sourceDate: day(-30),
                                question: "did I actually do this?")
        XCTAssertEqual(asked.question, "did I actually do this?")
        // No `isAnswered`, no `completedDate`, no score — if such a field is
        // ever added this test should be the thing that argues against it.
        let fields = Set(Mirror(reflecting: asked).children.compactMap(\.label))
        for forbidden in ["isAnswered", "answered", "completed", "score", "grade", "streak"] {
            XCTAssertFalse(fields.contains(forbidden),
                           "a Keep must never acquire a sense of being done or undone")
        }
    }

    /// A quieted passage never returns, even though he kept it himself — the
    /// quiet list outranks everything.
    func testQuietedKeepsAreNotDealt() {
        for w in JournalQuietWords.all() { JournalQuietWords.remove(w) }
        JournalQuietWords.add("Priya")
        defer { JournalQuietWords.remove("Priya") }
        let keep = ThresholdDeckBuilder.KeepSnapshot(
            id: UUID(), entryID: UUID(),
            passage: "The best day I ever had, with Priya.",
            question: nil, sourceDate: day(-90), isDue: true)
        let deck = ThresholdDeckBuilder.build(
            todaysPick: nil, entries: [], keeps: [keep],
            suppressed: [], recentlyShown: [], daySeed: 1)
        XCTAssertEqual(deck, [.door])
    }

    func testOnlyOneDueKeepIsDealtAtATime() {
        let keeps = (0..<4).map { i in
            ThresholdDeckBuilder.KeepSnapshot(
                id: UUID(), entryID: UUID(), passage: "kept line \(i)",
                question: nil, sourceDate: day(-90), isDue: true)
        }
        let deck = ThresholdDeckBuilder.build(
            todaysPick: nil, entries: [], keeps: keeps,
            suppressed: [], recentlyShown: [], daySeed: 1)
        let kept = deck.filter { if case let .card(c) = $0, case .kept = c { return true }; return false }
        XCTAssertEqual(kept.count, 1, "several at once turns something he chose to hold into a queue")
    }

    // MARK: - The ladder actually advances (Fable, build 51 ship gate)

    /// The bug this pins: `markSurfacedIfKeep` was attached to `.onAppear` of
    /// the current slot's view, but `onAppear` fires only on INSERTION and slot
    /// 0 is always the day's pick -- so a Keep, which is always dealt at slot 1
    /// or later, was never marked at all. `rung` stayed 0 and `lastSurfacedDate`
    /// stayed nil, which meant the same keep came back every single day, and
    /// since only the first due keep is dealt, that one stuck keep would have
    /// blocked every other keep he ever made. Silent, permanent, and the exact
    /// opposite of the "after a week, then longer" promise.
    func testSurfacingAdvancesTheRungAndPushesTheNextReturnOut() {
        let keep = JournalKeep(entryID: UUID(), passage: "a line", sourceDate: day(-400))
        keep.createdDate = day(-30)
        XCTAssertTrue(keep.isDue(), "30 days idle is well past the first 7-day rung")

        keep.markSurfaced(now: Date())
        XCTAssertEqual(keep.rung, 1, "being shown moves it up the ladder")
        XCTAssertFalse(keep.isDue(), "and it must not be due again the same day")
    }

    /// The over-firing half of the same bug: the card lives in a `List`, so
    /// scrolling the row away and back re-inserts the view and fired `onAppear`
    /// again. Two idle scroll-bys carried a keep 7 -> 21 -> 60 without him
    /// reading it twice.
    func testSecondSightingOnTheSameDayIsNotASecondRung() {
        let keep = JournalKeep(entryID: UUID(), passage: "a line", sourceDate: day(-400))
        keep.createdDate = day(-30)
        let noon = Date()
        keep.markSurfaced(now: noon)
        keep.markSurfaced(now: noon.addingTimeInterval(60))
        keep.markSurfaced(now: noon.addingTimeInterval(3600))
        XCTAssertEqual(keep.rung, 1, "the ladder measures elapsed days, not scroll events")
    }

    // MARK: - Midnight does not count as a reading (build-51 caveat)

    /// A sighting right before midnight and another right after are two
    /// different calendar days but one glance, eleven minutes apart. Must not
    /// advance twice.
    func testMidnightCrossingDoesNotDoubleAdvance() {
        let keep = JournalKeep(entryID: UUID(), passage: "a line", sourceDate: day(-400))
        keep.createdDate = day(-30)
        var lateNight = DateComponents()
        lateNight.year = 2026; lateNight.month = 9; lateNight.day = 4
        lateNight.hour = 23; lateNight.minute = 59
        let elevenPM = Calendar.current.date(from: lateNight)!
        let justAfterMidnight = elevenPM.addingTimeInterval(2 * 60)

        keep.markSurfaced(now: elevenPM)
        XCTAssertEqual(keep.rung, 1, "the first sighting still advances one rung")

        keep.markSurfaced(now: justAfterMidnight)
        XCTAssertEqual(keep.rung, 1,
                       "crossing a calendar-day boundary eleven minutes later is not a second reading")
    }

    /// A genuine next-evening sighting -- well over twelve hours later, even
    /// though it may also cross a midnight -- must still advance.
    func testGenuineNextEveningSightingStillAdvances() {
        let keep = JournalKeep(entryID: UUID(), passage: "a line", sourceDate: day(-400))
        keep.createdDate = day(-30)
        let firstEvening = Date()
        let nextEvening = firstEvening.addingTimeInterval(20 * 60 * 60) // ~20h later

        keep.markSurfaced(now: firstEvening)
        XCTAssertEqual(keep.rung, 1)

        keep.markSurfaced(now: nextEvening)
        XCTAssertEqual(keep.rung, 2, "a real day apart is a real reading, and must advance")
    }

    /// The elapsed guard is a floor, not a same-day check in disguise: two
    /// sightings on the same calendar day less than twelve hours apart are
    /// still blocked by the existing same-day rule, and this pins the boundary
    /// exactly at twelve hours regardless of which side of midnight it falls.
    func testElapsedGuardHoldsExactlyAtTwelveHours() {
        let keep = JournalKeep(entryID: UUID(), passage: "a line", sourceDate: day(-400))
        keep.createdDate = day(-30)
        let first = Date()
        let justUnderTwelveHours = first.addingTimeInterval(12 * 60 * 60 - 1)
        let justOverTwelveHours = first.addingTimeInterval(12 * 60 * 60 + 1)

        keep.markSurfaced(now: first)
        XCTAssertEqual(keep.rung, 1)

        keep.markSurfaced(now: justUnderTwelveHours)
        XCTAssertEqual(keep.rung, 1, "one second short of twelve hours does not count")

        keep.markSurfaced(now: justOverTwelveHours)
        XCTAssertEqual(keep.rung, 2, "one second past twelve hours does")
    }

    /// Releasing sets it down without destroying the record that he once chose
    /// to hold it. The passage and the entry are untouched either way -- this
    /// asserts the marking approach, not a delete.
    func testReleasingStopsTheReturnWithoutErasingTheKeep() {
        let keep = JournalKeep(entryID: UUID(), passage: "a line", sourceDate: day(-400))
        keep.createdDate = day(-30)
        XCTAssertTrue(keep.isDue())

        keep.releasedDate = Date()
        XCTAssertFalse(keep.isDue(), "a released keep stops coming back")
        XCTAssertEqual(keep.passage, "a line", "and the passage itself is never destroyed")
    }

}
