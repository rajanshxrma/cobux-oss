import XCTest
@testable import Cobux

/// Guards the stamp and, more importantly, `isStampLine`.
///
/// Three separate files carried private copies of a stamp-matching regex. The
/// moment a stamp gained a weather/place tail, all three would have stopped
/// recognising it and every card in the journal feed would have shown the stamp
/// line instead of the writing. They now share this matcher; these tests are
/// what keep it accepting every form that has ever existed.
final class JournalSessionStampTests: XCTestCase {

    private func date(_ h: Int, _ m: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 3,
                                                   hour: h, minute: m))!
    }

    // ------------------------------------------------------------ the stamp

    func testNoAmbientContextLeavesTheStampExactlyAsItWas() {
        let stamp = JournalSessionStamp.text(at: date(21, 41), previousSessionDate: nil,
                                             ambient: nil)
        XCTAssertEqual(stamp, "September 3, 2026 · 9:41 PM")
    }

    func testSameDayContinuationStillDropsTheDate() {
        let stamp = JournalSessionStamp.text(at: date(23, 5),
                                             previousSessionDate: date(21, 41),
                                             ambient: nil)
        XCTAssertEqual(stamp, "11:05 PM")
    }

    /// At home the place is silent — which is what stops ordinary entries from
    /// ever accumulating a location log.
    func testUsualPlaceIsNotNamed() {
        let ambient = AmbientContext(temperatureF: 72, locality: "Atlanta",
                                     condition: nil, isUsualPlace: true)
        let stamp = JournalSessionStamp.text(at: date(21, 41), previousSessionDate: nil,
                                             ambient: ambient)
        XCTAssertEqual(stamp, "September 3, 2026 · 9:41 PM · 72°")
        XCTAssertFalse(stamp.contains("Atlanta"))
    }

    func testUnusualPlaceIsNamed() {
        let ambient = AmbientContext(temperatureF: 54, locality: "Berlin",
                                     condition: nil, isUsualPlace: false)
        let stamp = JournalSessionStamp.text(at: date(21, 41), previousSessionDate: nil,
                                             ambient: ambient)
        XCTAssertEqual(stamp, "September 3, 2026 · 9:41 PM · 54° · Berlin")
    }

    func testNotableConditionAppears() {
        let ambient = AmbientContext(temperatureF: 28, locality: "Atlanta",
                                     condition: "Snow", isUsualPlace: true)
        let stamp = JournalSessionStamp.text(at: date(8, 15), previousSessionDate: nil,
                                             ambient: ambient)
        XCTAssertEqual(stamp, "September 3, 2026 · 8:15 AM · 28° · Snow")
    }

    // --------------------------------------------------------- the tripwire

    func testEveryHistoricalStampFormIsStillRecognised() {
        for line in ["September 3, 2026 · 9:41 PM",
                     "9:41 PM",
                     "9:41PM",
                     "January 1, 2026 · 12:00 AM"] {
            XCTAssertTrue(JournalSessionStamp.isStampLine(line),
                          "stopped recognising an existing stamp: \(line)")
        }
    }

    func testNewStampFormsAreRecognised() {
        for line in ["September 3, 2026 · 9:41 PM · 72°",
                     "September 3, 2026 · 9:41 PM · 54° · Berlin",
                     "9:41 PM · 28° · Snow",
                     "September 3, 2026 · 8:15 AM · 28° · Snow · New York"] {
            XCTAssertTrue(JournalSessionStamp.isStampLine(line),
                          "a stamp the app itself writes is not recognised: \(line)")
        }
    }

    /// The failure that matters most: real writing must never be mistaken for
    /// machinery and stripped out of a feed preview.
    func testRealWritingIsNotMistakenForAStamp() {
        for line in ["I woke up at 9:41 PM and felt strange",
                     "Bro the crazy thing about today",
                     "72° outside and I still felt cold",
                     ""] {
            XCTAssertFalse(JournalSessionStamp.isStampLine(line),
                           "would have deleted real writing: \(line)")
        }
    }

    // ----------------------------------------------------------- the tail

    func testNothingToSayProducesNoTail() {
        let empty = AmbientContext(temperatureF: nil, locality: nil,
                                   condition: nil, isUsualPlace: false)
        XCTAssertNil(empty.stampTail)
        // And a place we're standing in is still nothing to say.
        let home = AmbientContext(temperatureF: nil, locality: "Atlanta",
                                  condition: nil, isUsualPlace: true)
        XCTAssertNil(home.stampTail)
    }
}
