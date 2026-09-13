import XCTest
import SwiftData
@testable import Cobux

/// Guards what a situation thread may and may not remember.
///
/// The feature's whole defensibility is that it stores exactly two things the
/// user can see and delete — the transcript, and a note he wrote. Anything that
/// quietly accumulates findings about a real third party is the thing this must
/// never become.
@MainActor
final class SituationThreadTests: XCTestCase {

    func testAThreadStoresOnlyWhatHeTyped() {
        let thread = SituationThread(name: "the situationship")
        XCTAssertEqual(thread.name, "the situationship")
        XCTAssertNil(thread.note, "a new thread holds no note until he writes one")

        // The model has no vocabulary for describing the other person. If this
        // ever fails to compile because such a field was added, that is the
        // point of the test.
        let mirror = Mirror(reflecting: thread)
        let fields = Set(mirror.children.compactMap(\.label))
        for forbidden in ["attachmentStyle", "personality", "traits", "sentiment",
                          "mood", "assessment", "profile", "inferences"] {
            XCTAssertFalse(fields.contains(forbidden),
                           "a situation must never store an inference about a real person")
        }
    }

    /// It shares the general thread's cached prefix, so it costs nothing extra
    /// per turn — the reason it routes through `.general` rather than getting a
    /// mode of its own.
    func testSituationSharesTheGeneralThreadsStablePrefix() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Book.self, Highlight.self, Chapter.self,
                                           PersonalWritingEntry.self, SituationThread.self,
                                           configurations: config)
        let context = ModelContext(container)
        let book = Book(title: "A Book", author: "An Author")
        context.insert(book)
        let books = try context.fetch(FetchDescriptor<Book>())

        let plain = ChatPromptBuilder.assemble(
            userMessage: "what do i say", books: books, selectedBookID: nil,
            symposiumModeEnabled: false)
        let withSituation = ChatPromptBuilder.assemble(
            userMessage: "what do i say", books: books, selectedBookID: nil,
            symposiumModeEnabled: false,
            situation: SituationThread(name: "Priya"))

        guard case let .general(plainStable, _, _) = plain,
              case let .general(situatedStable, situatedDynamic, _) = withSituation
        else { return XCTFail("a situation must route through the general path") }

        XCTAssertEqual(plainStable, situatedStable,
                       "the cached prefix must be byte-identical, or it pays for a second cache entry")
        XCTAssertTrue(situatedDynamic.contains("Ongoing situation"),
                      "the situation block rides the uncached suffix")
        XCTAssertTrue(situatedDynamic.contains("Priya"))
    }
}
