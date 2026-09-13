import XCTest
import SwiftData
@testable import Cobux

/// Guards the interpersonal-advice capability Rajan asked Fable to design.
///
/// The behaviour was already happening in the wild before it was ever designed
/// for -- he noticed it was one of the app's most-used real uses -- which is
/// exactly why it needs tests: nothing about it is visible in the UI, so a
/// refactor could silently delete it and the only symptom would be replies
/// quietly getting worse. Same reasoning as `LifeExamplesPrivacyTests`.
@MainActor
final class ReparteeTests: XCTestCase {

    // ------------------------------------------------- the prompt layer (A)

    func testGeneralPromptAsksForSendableDrafts() {
        let prompt = String(format: PromptTemplates.base, "LIBRARY")
        // The load-bearing promise: the reply must contain the reply.
        XCTAssertTrue(prompt.contains("give them replies"))
        XCTAssertTrue(prompt.contains("two or three short candidate messages"))
        // Drafts render as real quote blocks in MessageBubbleView.
        XCTAssertTrue(prompt.contains("each on its own \"> \" line"))
    }

    func testGeneralPromptSpeaksTheUsersRegister() {
        let prompt = String(format: PromptTemplates.base, "LIBRARY")
        for term in ["left on read", "rizz", "dry texting", "situationship", "ghosted"] {
            XCTAssertTrue(prompt.contains(term), "lost vernacular anchor: \(term)")
        }
    }

    /// The ethical line, in both directions. A test that only checked the
    /// prohibitions would happily pass on a timid, lecturing assistant -- which
    /// fails him just as badly as a manipulative one.
    func testEthicalLineIsHeldFromBothSides() {
        let prompt = String(format: PromptTemplates.base, "LIBRARY")
        // Sharp play in his own interest stays explicitly in bounds.
        XCTAssertTrue(prompt.contains("Sharp play in the user's own interest is fine"))
        XCTAssertTrue(prompt.contains("letting silence do its work"))
        // Deception of a real person never gets drafted...
        XCTAssertTrue(prompt.contains("deceived or worn down"))
        XCTAssertTrue(prompt.contains("invented rivals"))
        // ...but the answer is a better message, never a refusal.
        XCTAssertTrue(prompt.contains("write the strongest honest version of the same move"))
    }

    func testBookScopedThreadCarriesReparteeButNotTraditionRegister() {
        let prompt = String(format: PromptTemplates.bookScoped, "T", "A", "T", "CONTENT")
        XCTAssertTrue(prompt.contains("give them replies"),
                      "a book thread is still a place people ask what to say")
        // The tradition block explains labels that only the full-library
        // context emits, so it would be describing something absent here.
        XCTAssertFalse(prompt.contains("The library speaks about people in more than one register"))
    }

    // --------------------------------------------- tradition attribution (B)

    func testTraditionLabelReachesTheModel() {
        let strategy = Book(title: "The 48 Laws of Power", author: "Robert Greene")
        strategy.tradition = .strategy
        XCTAssertEqual(SearchService.traditionSuffix(for: strategy), " — Tradition: Strategy")

        let therapy = Book(title: "Attached", author: "Amir Levine")
        therapy.tradition = .therapy
        XCTAssertEqual(SearchService.traditionSuffix(for: therapy), " — Tradition: Therapy")
    }

    /// An unset tradition says nothing rather than guessing a shelf.
    func testUntaggedBookClaimsNoTradition() {
        XCTAssertEqual(SearchService.traditionSuffix(for: Book(title: "X", author: "Y")), "")
    }

    // ------------------------------------------------------- retrieval (C)

    func testVernacularExpandsForRetrievalOnly() {
        let expanded = SearchService.expandedRetrievalQuery("she left me on read what do i say")
        // The user's own words survive untouched...
        XCTAssertTrue(expanded.hasPrefix("she left me on read what do i say"))
        // ...and the library's diction is appended for matching.
        XCTAssertTrue(expanded.contains("ignored message no reply waiting anxiety"))
    }

    func testOrdinaryQuestionIsNotRewritten() {
        let plain = "what does Marcus Aurelius say about anger"
        XCTAssertEqual(SearchService.expandedRetrievalQuery(plain), plain,
                       "a question with no vernacular must pass through byte-identical")
    }

    func testRankedSliceNeverReturnsFewerHighlightsThanBefore() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Book.self, Highlight.self, Chapter.self,
                                           configurations: config)
        let context = ModelContext(container)
        let book = Book(title: "Big", author: "A")
        context.insert(book)
        // More highlights than the per-book cap, none of them embedded, so
        // ranking comes up empty and the fallback path is what runs.
        for i in 0..<(SearchService.maxHighlightsPerBookInDynamicContext + 25) {
            let h = Highlight(text: "highlight number \(i)")
            h.book = book
            context.insert(h)
        }
        let picked = SearchService.topHighlights(of: book, for: "anything")
        XCTAssertEqual(picked.count, SearchService.maxHighlightsPerBookInDynamicContext,
                       "the ranked slice must still fill the budget")
    }

    func testSmallBookIsReturnedWhole() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Book.self, Highlight.self, Chapter.self,
                                           configurations: config)
        let context = ModelContext(container)
        let book = Book(title: "Small", author: "A")
        context.insert(book)
        for i in 0..<5 {
            let h = Highlight(text: "h\(i)")
            h.book = book
            context.insert(h)
        }
        XCTAssertEqual(SearchService.topHighlights(of: book, for: "q").count, 5)
    }
}

/// The journal feed's date headers.
///
/// Separate from the feature tests above because this guards a defect that
/// survived a fix AND a verification: `sectionLabel` handled the year correctly,
/// was computed into `DateSection.label`, and was then never read by anything.
/// Checking that function proved nothing about the screen. These tests call the
/// function the header actually renders.
@MainActor
final class JournalDateHeaderTests: XCTestCase {

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testPastYearsAreDistinguishable() {
        let april2023 = JournalListView.weekdayAndMonth(date(2023, 4, 23))
        let april2025 = JournalListView.weekdayAndMonth(date(2025, 4, 23))
        XCTAssertTrue(april2023.contains("2023"), "got \(april2023)")
        XCTAssertTrue(april2025.contains("2025"), "got \(april2025)")
        XCTAssertNotEqual(april2023, april2025,
                          "two Aprils in different years must not render identically")
    }

    /// The year would repeat on every header this year, so it stays off.
    func testCurrentYearOmitsTheYear() {
        let year = Calendar.current.component(.year, from: .now)
        let header = JournalListView.weekdayAndMonth(date(year, 4, 23))
        XCTAssertFalse(header.contains(String(year)), "got \(header)")
    }

    func testTitleIsNotRepeatedAsTheFirstBodyLine() {
        let body = JournalListView.dropDuplicatedTitle(
            from: "when u\nwhen u can see how a person feels", title: "when u")
        XCTAssertEqual(body, "when u can see how a person feels")
    }

    /// A near-match is the user's own writing, not a duplicate heading.
    func testOnlyAnExactTitleLineIsDropped() {
        let body = JournalListView.dropDuplicatedTitle(
            from: "when u are tired\nrest", title: "when u")
        XCTAssertEqual(body, "when u are tired\nrest")
    }
}
