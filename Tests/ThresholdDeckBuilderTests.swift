import XCTest
@testable import Cobux

/// Guards the window under the calendar.
///
/// Its defining property is that tapping CYCLES a finite deck rather than
/// re-selecting. `JournalHighlightCard` documents how re-selection emptied a
/// ~100-entry pool through the 60-day cooldown, so an unbounded refresh would
/// rebuild that bug as a feature.
@MainActor
final class ThresholdDeckBuilderTests: XCTestCase {
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


    private let now = Calendar.current.date(from: DateComponents(
        year: 2026, month: 9, day: 4, hour: 12))!

    override func setUp() {
        super.setUp()
        useIsolatedQuietWordStore()
    }
    override func tearDown() {
        restoreQuietWordStore()
        super.tearDown()
    }

    private func entry(daysAgo: Int, text: String? = nil,
                       id: UUID = UUID()) -> EbbDeckBuilder.EntrySnapshot {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
        let body = text ?? ("A whole sentence from an entry that says something real. "
            + String(repeating: "More writing to give it some length here. ", count: 3))
        return .init(id: id, date: date, dateIsCertain: true, text: body, words: 90)
    }

    private func build(_ entries: [EbbDeckBuilder.EntrySnapshot],
                       pick: EbbCard? = nil,
                       suppressed: Set<UUID> = []) -> [ThresholdDeckBuilder.Slot] {
        ThresholdDeckBuilder.build(todaysPick: pick, entries: entries,
                                   suppressed: suppressed, recentlyShown: [],
                                   daySeed: 99, now: now)
    }

    /// The door is always last, so the window always offers a way further in.
    func testTheDoorIsAlwaysTheFinalSlot() {
        let deck = build((20...60).map { entry(daysAgo: $0) })
        XCTAssertEqual(deck.last, .door)
        XCTAssertEqual(deck.filter { $0 == .door }.count, 1)
    }

    /// Even with nothing eligible at all, the door still stands.
    func testEmptyArchiveStillOffersTheDoor() {
        XCTAssertEqual(build([]), [.door])
    }

    func testTodaysPickLeadsTheDeck() {
        let id = UUID()
        let pick = EbbCard.passage(entryID: id, date: now, text: "today's passage")
        let entries = [entry(daysAgo: 40, id: id)] + (20...50).map { entry(daysAgo: $0) }
        let deck = build(entries, pick: pick)
        guard case let .card(first) = deck.first else { return XCTFail("expected a card first") }
        XCTAssertEqual(first.entryID, id, "card one must be exactly the card already there")
    }

    /// Finite by construction — this is what makes tap-to-refresh safe.
    func testDeckIsSmallAndFinite() {
        let deck = build((20...200).map { entry(daysAgo: $0) })
        XCTAssertLessThanOrEqual(deck.count, ThresholdDeckBuilder.maximumCards + 1)
    }

    func testNoEntryAppearsTwice() {
        let deck = build((20...60).map { entry(daysAgo: $0) })
        let ids = deck.compactMap { if case let .card(c) = $0 { return c.entryID }; return nil }
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testFreshWritingNeverAppears() {
        let deck = build((1...10).map { entry(daysAgo: $0) })
        XCTAssertEqual(deck, [.door], "nothing inside the 14-day floor may be dealt back")
    }

    func testSuppressedEntriesNeverAppear() {
        let silenced = UUID()
        let deck = build([entry(daysAgo: 40, id: silenced)] + (30...50).map { entry(daysAgo: $0) },
                         suppressed: [silenced])
        let ids = deck.compactMap { if case let .card(c) = $0 { return c.entryID }; return nil }
        XCTAssertFalse(ids.contains(silenced))
    }

    /// The amplified surface must not be the one that forgets the quiet list.
    func testQuietedEntriesNeverAppear() {
        JournalQuietWords.add("Priya")
        let quiet = entry(daysAgo: 40,
                          text: "The best day I have ever had. Priya and I walked until dark.")
        let deck = build([quiet] + (30...50).map { entry(daysAgo: $0) })
        let ids = deck.compactMap { if case let .card(c) = $0 { return c.entryID }; return nil }
        XCTAssertFalse(ids.contains(quiet.id))
    }

    func testTheSameDayBuildsTheSameDeck() {
        let entries = (20...60).map { entry(daysAgo: $0) }
        XCTAssertEqual(build(entries).map(\.id), build(entries).map(\.id))
    }

    // MARK: - The choke point holds on EVERY path (Fable, build 51 ship gate)

    /// The deck used to append `todaysPick` as slot 0 without checking it,
    /// trusting that whoever selected it had already applied the gates. The
    /// journal card's settled same-day path had not. The failure was concrete
    /// and cruel: he sees a passage naming his ex, goes to Settings and quiets
    /// the name, comes back to the same screen -- and it is still there,
    /// because the pick had already been settled for the day.
    func testAQuietedPickIsNotDealtEvenWhenHandedIn() {
        let id = UUID()
        let text = "The night Priya and I walked the whole length of the bridge talking."
        let entries = [entry(daysAgo: 400, text: text, id: id), entry(daysAgo: 300)]
        let pick = EbbCard.passage(entryID: id, date: now.addingTimeInterval(-9e6),
                                   text: text)

        JournalQuietWords.add("Priya")
        let slots = build(entries, pick: pick)

        for slot in slots {
            if case let .card(card) = slot {
                XCTAssertNotEqual(card.entryID, id,
                                  "a handed-in pick is still a pick -- it goes through the gate")
            }
        }
    }

    /// A keep holds ONE excerpt, but the card opens into the whole entry. The
    /// quiet check therefore covers the source entry, not just the stored
    /// passage -- otherwise a keep is the single surface that walks him back
    /// into the thing he asked not to see.
    func testAKeepIsCheckedAgainstItsWholeSourceEntry() {
        let id = UUID()
        let entries = [entry(daysAgo: 400,
                             text: "A neutral opening line that names nobody at all. "
                                 + "Later in the same entry it says Priya left in April.",
                             id: id)]
        let keep = ThresholdDeckBuilder.KeepSnapshot(
            id: UUID(), entryID: id,
            passage: "A neutral opening line that names nobody at all.",
            question: nil, sourceDate: now.addingTimeInterval(-3e7), isDue: true)

        JournalQuietWords.add("Priya")
        let slots = ThresholdDeckBuilder.build(
            todaysPick: nil, entries: entries, keeps: [keep],
            suppressed: [], recentlyShown: [], daySeed: 99, now: now)

        for slot in slots {
            if case let .card(card) = slot {
                XCTAssertNil(card.keepID,
                             "the passage is clean but the entry it opens into is not")
            }
        }
    }

    /// The choke point must fail CLOSED, not open. `entries` is a
    /// caller-supplied snapshot -- a pick whose entry cannot be found in it
    /// (a stale caller, a deleted entry, anything) must be treated as
    /// unresolved-therefore-unsafe, never as "nothing to check against."
    /// This is the exact shape e11c1b6 already fixed for
    /// `CrossChatInput.journalThreadID`; this builder had the same bug.
    func testAPickWhoseEntryIsMissingFromTheSetFailsClosed() {
        let missingID = UUID()
        let pick = EbbCard.passage(entryID: missingID, date: now.addingTimeInterval(-9e6),
                                   text: "a pick whose own entry never made it into the set")
        let entries = (20...50).map { entry(daysAgo: $0) }

        let slots = build(entries, pick: pick)

        for slot in slots {
            if case let .card(card) = slot {
                XCTAssertNotEqual(card.entryID, missingID,
                                  "an unresolved lookup must suppress, not surface")
            }
        }
    }

    /// Same rule for the Keep path: a due Keep whose source entry is not in
    /// the passed-in set is not dealt.
    func testAKeepWhoseEntryIsMissingFromTheSetFailsClosed() {
        let missingID = UUID()
        let keep = ThresholdDeckBuilder.KeepSnapshot(
            id: UUID(), entryID: missingID,
            passage: "a clean passage whose source entry never made it into the set",
            question: nil, sourceDate: now.addingTimeInterval(-3e7), isDue: true)
        let entries = (20...50).map { entry(daysAgo: $0) }

        let slots = ThresholdDeckBuilder.build(
            todaysPick: nil, entries: entries, keeps: [keep],
            suppressed: [], recentlyShown: [], daySeed: 99, now: now)

        for slot in slots {
            if case let .card(card) = slot {
                XCTAssertNil(card.keepID,
                             "an unresolved keep lookup must suppress, not surface")
            }
        }
    }

}
