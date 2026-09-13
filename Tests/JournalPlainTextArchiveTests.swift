import XCTest
@testable import Cobux

/// Guards the one thing this archive exists to do: be readable, in order, and
/// unedited, years from now, by someone who does not have Cobux.
///
/// It is the copy Rajan asked for so that "if by chance the ocbux journals are
/// lost misatkenly thhey still in apple notes." Every assertion below is a way
/// that copy could quietly stop being that: dates that don't sort, entries that
/// run backwards, a body the renderer decided to tidy, or two appended batches
/// with nothing between them.
///
/// Nothing here asserts the weekday word. `JournalPlainTextArchive` renders the
/// weekday in the READER's locale on purpose, so pinning "Thursday" would only
/// pin the machine the tests happen to run on. The sortable stamp beside it is
/// `en_US_POSIX` and is asserted exactly, which is the half that has to be
/// stable.
final class JournalPlainTextArchiveTests: XCTestCase {

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day,
                                                   hour: hour, minute: minute))!
    }

    private func entry(_ date: Date, title: String = "", source: String = "journal",
                       text: String) -> JournalPlainTextArchive.Entry {
        JournalPlainTextArchive.Entry(date: date, title: title, source: source, text: text)
    }

    // -------------------------------------------------------------- the date

    func testHeaderOpensWithASortableStamp() {
        let rendered = JournalPlainTextArchive.render([
            entry(date(2015, 4, 2, 23, 11), title: "when u", source: "Notes(personal)",
                  text: "when u can see how far it goes")
        ])
        XCTAssertTrue(rendered.hasPrefix("2015-04-02 23:11 \u{00B7} "),
                      "The first thing on the line must be the sortable stamp: \(rendered)")
        XCTAssertTrue(rendered.contains("\u{2014} when u"), "The title belongs on the header line")
    }

    func testEntriesComeOutOldestFirst() {
        let rendered = JournalPlainTextArchive.render([
            entry(date(2026, 9, 6, 14, 32), text: "third"),
            entry(date(2015, 4, 2, 23, 11), text: "first"),
            entry(date(2026, 9, 5, 9, 3), text: "second")
        ])
        // Ascending is not cosmetic: the destination action is "Append to
        // Note", which writes at the bottom.
        let order = ["first", "second", "third"].compactMap { rendered.range(of: $0)?.lowerBound }
        XCTAssertEqual(order.count, 3)
        XCTAssertTrue(order == order.sorted(), "Oldest first, or an appended note reads backwards")
    }

    // -------------------------------------------------------------- the words

    func testTheBodyIsVerbatimIncludingTheSessionStamp() {
        // The feed strips this stamp; the archive must not. It carries the
        // weather and the place, which `JournalSessionStamp` appends as TEXT
        // and which exist nowhere else once Cobux is gone.
        let body = "September 6, 2026 \u{00B7} 2:32 PM \u{00B7} 72\u{00B0} \u{00B7} Atlanta\nThe work is the reward."
        let rendered = JournalPlainTextArchive.render([entry(date(2026, 9, 6, 14, 32), text: body)])
        XCTAssertTrue(rendered.contains(body), "A backup that edits his words is not a backup")
    }

    // --------------------------------------------------------- the provenance

    func testWritingFromElsewhereSaysWhereItCameFrom() {
        let rendered = JournalPlainTextArchive.render([
            entry(date(2015, 4, 2, 23, 11), source: "Notes(personal)", text: "body")
        ])
        // The RAW source string, not `JournalSourceFamily`'s collapsed label:
        // the folder name is what still means something in ten years.
        XCTAssertTrue(rendered.contains("from Notes(personal)"))
    }

    func testWritingFromCobuxSaysNothingAboutItsSource() {
        let rendered = JournalPlainTextArchive.render([
            entry(date(2026, 9, 6, 14, 32), text: "body")
        ])
        XCTAssertFalse(rendered.contains("from "), "The absence of a line is what 'written here' looks like")
    }

    // ------------------------------------------------------------- the shape

    func testATitlelessEntryLeavesNoDanglingDash() {
        let rendered = JournalPlainTextArchive.render([
            entry(date(2026, 9, 6, 14, 32), title: "   ", text: "body")
        ])
        XCTAssertTrue(rendered.hasPrefix("2026-09-06 14:32 \u{00B7} "))
        XCTAssertFalse(rendered.contains("\u{2014} \n"), "An em dash with nothing after it")
        XCTAssertFalse(rendered.hasSuffix("\u{2014} "))
    }

    func testEveryRecordEndsWithTheSeparator() {
        // After each record, not between them -- so tomorrow night's appended
        // batch lands under a rule instead of butting onto tonight's last
        // sentence.
        let rendered = JournalPlainTextArchive.render([
            entry(date(2026, 9, 5, 9, 3), text: "one"),
            entry(date(2026, 9, 6, 14, 32), text: "two")
        ])
        let separators = rendered.components(separatedBy: JournalPlainTextArchive.recordSeparator).count - 1
        XCTAssertEqual(separators, 2, "One separator per entry, including the last")
        XCTAssertTrue(rendered.hasSuffix(JournalPlainTextArchive.recordSeparator))
    }

    func testAnEmptyJournalRendersNothingRatherThanAStrayRule() {
        XCTAssertEqual(JournalPlainTextArchive.render([]), "")
    }
}
