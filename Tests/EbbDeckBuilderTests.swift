import XCTest
@testable import Cobux

/// Guards the Ebb deck. The vetoes in `docs/ebb.md` are what these test.
final class EbbDeckBuilderTests: XCTestCase {

    private let now = Calendar.current.date(from: DateComponents(
        year: 2026, month: 9, day: 3, hour: 12))!

    private func entry(daysAgo: Int, words: Int = 120,
                       certain: Bool = true, id: UUID = UUID())
    -> EbbDeckBuilder.EntrySnapshot {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
        let text = "This is a real sentence from an entry that says something whole. "
            + String(repeating: "More writing follows here to give it length. ", count: 3)
        return .init(id: id, date: date, dateIsCertain: certain, text: text, words: words)
    }

    private func deck(_ entries: [EbbDeckBuilder.EntrySnapshot],
                      suppressed: Set<UUID> = [],
                      opener: EbbCard? = nil) -> [EbbCard] {
        EbbDeckBuilder.buildDeck(entries: entries, opener: opener,
                                 suppressed: suppressed, recentlyShown: [],
                                 daySeed: 42, now: now)
    }

    /// Fresh writing is a wound. Non-negotiable.
    func testEntriesInsideTheAgeFloorNeverAppear() {
        let fresh = (1...10).map { entry(daysAgo: $0) }
        XCTAssertTrue(deck(fresh).isEmpty,
                      "nothing written in the last 14 days may be dealt back at him")
    }

    /// Suppression is permanent and is checked before anything else, because
    /// entries can never be deleted.
    func testSuppressedEntriesNeverAppear() {
        let silenced = UUID()
        let entries = [entry(daysAgo: 40, id: silenced)] + (30...45).map { entry(daysAgo: $0) }
        let cards = deck(entries, suppressed: [silenced])
        XCTAssertFalse(cards.contains { $0.entryID == silenced })
    }

    /// The deck ends. An ebb recedes; it does not loop.
    func testDeckIsFiniteAndEndsWithTheEndCard() {
        let entries = (20...80).map { entry(daysAgo: $0) }
        let cards = deck(entries)
        XCTAssertFalse(cards.isEmpty)
        guard case .endCard = cards.last else {
            return XCTFail("a deck must end on purpose, with the end card")
        }
        XCTAssertLessThanOrEqual(cards.count, EbbDeckBuilder.maximumDeck + 4)
    }

    /// Same day, same deck — reopening must not reshuffle his own life.
    func testTheSameDayDealsTheSameDeck() {
        let entries = (20...60).map { entry(daysAgo: $0) }
        XCTAssertEqual(deck(entries).map(\.id), deck(entries).map(\.id))
    }

    /// No entry is dealt twice inside one deck.
    func testNoEntryRepeatsWithinADeck() {
        let entries = (20...60).map { entry(daysAgo: $0) }
        let ids = deck(entries).compactMap(\.entryID)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    /// An import whose date collapsed onto its import date cannot make a
    /// calendar claim.
    func testUncertainDatesNeverClaimOnThisDay() {
        // Same month and day as `now`, a year back, but the date is a guess.
        let uncertain = entry(daysAgo: 365, certain: false)
        let cards = deck([uncertain] + (20...40).map { entry(daysAgo: $0) })
        for card in cards {
            if case .onThisDay(let id, _, _) = card {
                XCTAssertNotEqual(id, uncertain.id,
                                  "an unknown date must never be dated on a card")
            }
        }
    }

    /// Too little material means saying so, not padding.
    func testTooFewEntriesProducesNoDeck() {
        XCTAssertTrue(deck([entry(daysAgo: 30)]).isEmpty)
    }

    /// The opener is handed in, not recomputed, and leads the deck.
    func testOpenerLeadsTheDeck() {
        let openerID = UUID()
        let opener = EbbCard.passage(entryID: openerID, date: now, text: "today's passage")
        let cards = deck((20...60).map { entry(daysAgo: $0) }, opener: opener)
        XCTAssertEqual(cards.first?.entryID, openerID)
    }
}
