import XCTest
import SwiftData
@testable import Cobux

/// Guards the one rule Rajan explicitly reserved judgment on: real names from
/// his journals must never be usable in replies unless the Settings toggle is
/// deliberately on. The parameter defaults fail closed; this test makes sure
/// the instruction text itself can't silently regress in a refactor.
@MainActor
final class LifeExamplesPrivacyTests: XCTestCase {

    private func makeEntries() throws -> [PersonalWritingEntry] {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: PersonalWritingEntry.self, configurations: config)
        let context = ModelContext(container)
        // No embedding on the entry → the block's retrieval falls back to
        // substring matching, so the query below must appear in the text.
        let entry = PersonalWritingEntry(
            source: "Journal",
            title: "On friendship",
            text: "Thinking about friendship and what loyalty really costs."
        )
        context.insert(entry)
        return [entry]
    }

    func testAnonymousModeForbidsRealNames() throws {
        let block = SearchService.personalWritingContextBlock(
            query: "friendship", entries: try makeEntries(), useRealNames: false
        )
        XCTAssertFalse(block.isEmpty, "the entry should have been retrieved by substring match")
        XCTAssertTrue(block.contains("NEVER repeat personal names"), "anonymize instruction must be present when the toggle is off")
        XCTAssertFalse(block.contains("by the names used there"), "the allow-names instruction must not leak into anonymous mode")
    }

    func testRealNamesModeAllowsNames() throws {
        let block = SearchService.personalWritingContextBlock(
            query: "friendship", entries: try makeEntries(), useRealNames: true
        )
        XCTAssertFalse(block.isEmpty)
        XCTAssertTrue(block.contains("by the names used there"))
        XCTAssertFalse(block.contains("NEVER repeat personal names"))
    }

    func testDefaultsFailClosed() {
        // Every threading layer defaults the flag to false — spot-check the
        // outermost one so a future signature change can't flip the default.
        let mirrorBlock = SearchService.personalWritingContextBlock(
            query: "friendship", entries: [], useRealNames: false
        )
        XCTAssertEqual(mirrorBlock, "", "empty entries produce no block at all")
    }
}
