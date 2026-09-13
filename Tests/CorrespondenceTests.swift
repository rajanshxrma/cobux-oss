import XCTest
import SwiftData
@testable import Cobux

/// Guards The Correspondence.
///
/// The invariants here are the feature's constitution: the original is never
/// touched, the link survives every store it passes through, and old data
/// decodes with nils rather than failing.
@MainActor
final class CorrespondenceTests: XCTestCase {
    private func context() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: PersonalWritingEntry.self,
                                               configurations: config))
    }

    /// Write-back creates a NEW row and never writes the original -- the
    /// permanence invariant, asserted byte-for-byte.
    func testWritingBackNeverTouchesTheOriginal() throws {
        let ctx = try context()
        let original = PersonalWritingEntry(source: "journal", title: "then",
                                            text: "What I believed that spring.")
        ctx.insert(original)
        let beforeText = original.text
        let beforeModified = original.modifiedDate
        let beforeSeconds = original.writingSeconds

        let reply = PersonalWritingEntry(source: "journal", title: "now",
                                         text: "What I would tell him today.")
        reply.answersEntryID = original.id
        reply.answersEntryDate = original.modifiedDate ?? original.dateImported
        ctx.insert(reply)
        try ctx.save()

        XCTAssertEqual(original.text, beforeText)
        XCTAssertEqual(original.modifiedDate, beforeModified)
        XCTAssertEqual(original.writingSeconds, beforeSeconds)
        XCTAssertEqual(reply.answersEntryID, original.id)
    }

    /// The DTO round-trip carries the link -- and a DTO built without it
    /// (an old snapshot) decodes to nils rather than failing.
    func testBackupRoundTripCarriesTheLink() throws {
        let id = UUID(); let date = Date(timeIntervalSince1970: 1_700_000_000)
        let dto = BackupService.PersonalWritingEntryDTO(
            source: "journal", title: "t", text: "x", modifiedDate: nil,
            dateImported: .now, answersEntryID: id, answersEntryDate: date)
        let data = try JSONEncoder().encode(dto)
        let back = try JSONDecoder().decode(BackupService.PersonalWritingEntryDTO.self, from: data)
        XCTAssertEqual(back.answersEntryID, id)
        XCTAssertEqual(back.answersEntryDate, date)

        // Old-shape JSON (no link fields) must decode with nils.
        let oldJSON = #"{"source":"journal","title":"t","text":"x","dateImported":700000000}"#
        let old = try JSONDecoder().decode(BackupService.PersonalWritingEntryDTO.self,
                                           from: Data(oldJSON.utf8))
        XCTAssertNil(old.answersEntryID)
        XCTAssertNil(old.answersEntryDate)
    }

    /// The compose kicker states the mechanism and dates it -- and stays
    /// honest about uncertain dates.
    func testAnsweringKickerIsHonestAboutDates() {
        let date = DateComponents(calendar: .current, year: 2025, month: 3, day: 12).date!
        XCTAssertEqual(JournalEntryComposeView.answeringKicker(date: date, certain: true),
                       "Answering · March 12, 2025")
        XCTAssertEqual(JournalEntryComposeView.answeringKicker(date: date, certain: false),
                       "Answering · imported March 12, 2025")
    }

    /// The draft store persists the link so a crash mid-write-back recovers
    /// answering what it was answering.
    func testDraftCarriesTheLinkThroughACrash() throws {
        let id = UUID(); let date = Date(timeIntervalSince1970: 1_690_000_000)
        var draft = JournalDraftStore.Draft(entryID: nil, title: "", text: "half-written reply",
                                            updated: .now)
        draft.answersEntryID = id
        draft.answersEntryDate = date
        let data = try JSONEncoder().encode(draft)
        let back = try JSONDecoder().decode(JournalDraftStore.Draft.self, from: data)
        XCTAssertEqual(back.answersEntryID, id)
        XCTAssertEqual(back.answersEntryDate, date)

        // And an OLD persisted draft (no link keys) decodes unchanged.
        let oldJSON = #"{"title":"","text":"old draft","updated":690000000}"#
        let old = try JSONDecoder().decode(JournalDraftStore.Draft.self, from: Data(oldJSON.utf8))
        XCTAssertNil(old.answersEntryID)
    }
}
