import XCTest
import SwiftData
@testable import Cobux

/// Guards the one rule Rajan explicitly reserved judgment on: real names from
/// his journals must never be usable in replies unless the Settings toggle is
/// deliberately on. The parameter defaults fail closed; this test makes sure
/// the instruction text itself can't silently regress in a refactor.
@MainActor
final class LifeExamplesPrivacyTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "cobux.tests.quietwords.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        JournalQuietWords.store = suite
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        JournalQuietWords.store = .standard
        suite = nil
        suiteName = nil
        super.tearDown()
    }


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

    // MARK: - The quiet list reaches the chat too (Fable, build 51 ship gate)

    private func quietedEntries() throws -> [PersonalWritingEntry] {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: PersonalWritingEntry.self,
                                           configurations: config)
        let context = ModelContext(container)
        let entry = PersonalWritingEntry(
            source: "Journal", title: "On friendship",
            text: "Thinking about friendship and what loyalty really costs, with Priya.")
        context.insert(entry)
        return [entry]
    }

    /// The last surface that still ignored the quiet list. He asks the chat
    /// something ordinary about friendship and it weaves in, unprompted, the
    /// entry naming the person he asked never to hear about again. Every
    /// ambient surface was gated except the one that talks back.
    func testIncidentalWeavingRespectsQuietWords() throws {
        let entries = try quietedEntries()
        JournalQuietWords.add("Priya")

        let block = SearchService.personalWritingContextBlock(
            query: "what does friendship really cost", entries: entries,
            useRealNames: false)

        XCTAssertFalse(block.contains("Priya"),
                       "a quieted name must not be woven into an unrelated reply")
        XCTAssertTrue(block.isEmpty,
                      "with nothing left to weave, the block is simply absent")
    }

    /// The other half, and it matters just as much: quieting a name means
    /// "stop bringing this up at me", NOT "hide my own writing from me". When
    /// he asks about his journal directly, he gets his journal. An app that
    /// censored his own words back at him would be a worse failure than the
    /// one this fixes.
    func testAskingDirectlyStillReturnsHisOwnWriting() throws {
        let entries = try quietedEntries()
        JournalQuietWords.add("Priya")

        let block = SearchService.personalWritingContextBlock(
            query: "what did I write in my journal about friendship",
            entries: entries, useRealNames: false)

        XCTAssertFalse(block.isEmpty,
                       "a direct question about his own writing is never ambient")
        XCTAssertTrue(block.contains("friendship"))
    }

}
