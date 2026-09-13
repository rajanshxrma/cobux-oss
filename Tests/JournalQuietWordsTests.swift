import XCTest
@testable import Cobux

/// Guards the one control that answers the ex problem.
///
/// The app deliberately refuses to detect painful content itself — that is
/// characterization, and it is impossible in principle, since the most painful
/// material about a person is often the happiest. So the user holds the list,
/// and these tests guard that his list is actually obeyed.
@MainActor
final class JournalQuietWordsTests: XCTestCase {
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

    func testNothingIsQuietUntilHeSaysSo() {
        XCTAssertFalse(JournalQuietWords.isQuiet("a perfectly ordinary entry about Priya"))
        XCTAssertTrue(JournalHighlightSelector.maySurface("anything at all"))
    }

    func testAQuietedNameSilencesTheWholeEntry() {
        JournalQuietWords.add("Priya")
        // Checked against the whole entry, not the chosen sentence: an entry is
        // about her even if the passage the selector picked never says her name.
        XCTAssertTrue(JournalQuietWords.isQuiet("Today was fine. I keep thinking about Priya though."))
        XCTAssertFalse(JournalHighlightSelector.maySurface("Today was fine. I keep thinking about Priya though."))
    }

    func testMatchingIsCaseInsensitive() {
        JournalQuietWords.add("Priya")
        XCTAssertTrue(JournalQuietWords.isQuiet("priya said something"))
        XCTAssertTrue(JournalQuietWords.isQuiet("PRIYA"))
    }

    /// The happy memory is the case sentiment analysis would miss, and the case
    /// this control exists for.
    func testAHappyMemoryIsSilencedToo() {
        JournalQuietWords.add("Priya")
        XCTAssertFalse(JournalHighlightSelector.maySurface(
            "The best day I have ever had. Priya and I walked until it got dark."))
    }

    func testUnquietingRestoresIt() {
        JournalQuietWords.add("Priya")
        JournalQuietWords.remove("Priya")
        XCTAssertTrue(JournalHighlightSelector.maySurface("thinking about Priya"))
    }

    func testDuplicatesAreNotAdded() {
        JournalQuietWords.add("Priya")
        JournalQuietWords.add("priya")
        XCTAssertEqual(JournalQuietWords.all().count, 1)
    }

    func testEmptyInputIsIgnored() {
        JournalQuietWords.add("   ")
        XCTAssertTrue(JournalQuietWords.all().isEmpty)
    }
}
