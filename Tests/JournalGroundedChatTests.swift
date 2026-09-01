import XCTest
import SwiftData
@testable import Cobux

/// Guards the journal-grounded chat thread's prompt assembly (see
/// `PromptTemplates.journalGrounded` / `SearchService.buildJournalContext` /
/// `ChatPromptBuilder.journalThreadID`): the whole point of the thread is
/// that "what was I writing about in March?" is answerable, which requires
/// (1) the books-only restriction absent, (2) real entries in the prompt,
/// (3) each entry carrying its date, and (4) a month named in the query
/// actually narrowing to that month's entries — none of which the compiler
/// checks for us.
@MainActor
final class JournalGroundedChatTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: PersonalWritingEntry.self, configurations: config)
        return ModelContext(container)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func makeEntry(in context: ModelContext, title: String, text: String, date: Date) -> PersonalWritingEntry {
        let entry = PersonalWritingEntry(source: "journal", title: title, text: text, modifiedDate: date, dateImported: date)
        context.insert(entry)
        return entry
    }

    // MARK: - Context block

    func testJournalContextCarriesEntryTextAndDate() throws {
        let context = try makeContext()
        let entry = makeEntry(in: context, title: "A hard week", text: "Felt overwhelmed by the visa paperwork but kept going.", date: date(2026, 3, 14))

        let block = SearchService.buildJournalContext(query: "how was I doing?", entries: [entry])

        XCTAssertTrue(block.contains("Felt overwhelmed by the visa paperwork"), "the entry's own text must reach the prompt")
        XCTAssertTrue(block.contains("March"), "the entry must be prefixed with its date so period questions are answerable")
        XCTAssertTrue(block.contains("2026"), "the date prefix must include the year")
    }

    func testJournalContextRespectsEntryAndCharCaps() throws {
        let context = try makeContext()
        let entries = (0..<20).map { index in
            makeEntry(
                in: context,
                title: "Entry \(index)",
                text: String(repeating: "reflection ", count: 400) + "marker-\(index)",
                date: date(2026, 1, index + 1)
            )
        }

        let block = SearchService.buildJournalContext(query: "everything", entries: entries)

        let included = (0..<20).filter { block.contains("\"Entry \($0)\"") }.count
        XCTAssertLessThanOrEqual(included, SearchService.journalThreadTopK, "at most topK entries may be injected")
        XCTAssertGreaterThan(included, 0, "some entries must always be injected while any exist")
        // 400 × "reflection " is ~4400 chars — every injected entry must have
        // been cut to the per-entry limit (so the "marker" tail is gone).
        XCTAssertFalse(block.contains("marker-"), "entry text must be truncated to the per-entry char limit")
        XCTAssertLessThan(
            block.count,
            SearchService.journalThreadTopK * (SearchService.journalThreadEntryCharLimit + 200),
            "the whole block must stay bounded"
        )
    }

    func testMonthQuestionNarrowsToThatMonthsEntries() throws {
        let context = try makeContext()
        let march = makeEntry(in: context, title: "Spring", text: "Started rebuilding the study routine from scratch.", date: date(2026, 3, 2))
        let july = makeEntry(in: context, title: "Summer", text: "Shipped the decoder project and slept badly.", date: date(2026, 7, 9))

        let block = SearchService.buildJournalContext(query: "what was I writing about in March?", entries: [march, july])

        XCTAssertTrue(block.contains("Started rebuilding the study routine"), "the named month's entries must be present")
        XCTAssertFalse(block.contains("Shipped the decoder project"), "a month question must narrow the pool to that month")
    }

    func testEmptyJournalProducesHonestPlaceholder() {
        let block = SearchService.buildJournalContext(query: "what did I write?", entries: [])
        XCTAssertTrue(block.contains("no entries"), "an empty journal must be stated, never silently blank")
    }

    // MARK: - Month detection

    func testMonthMentionedFindsFullAndShortNames() {
        XCTAssertEqual(SearchService.monthMentioned(in: "What was I writing about in March?"), 3)
        XCTAssertEqual(SearchService.monthMentioned(in: "anything from jan worth rereading?"), 1)
        XCTAssertNil(SearchService.monthMentioned(in: "what themes keep coming up?"))
    }

    func testMayOnlyCountsAsMonthInDateContext() {
        XCTAssertEqual(SearchService.monthMentioned(in: "how was I doing last May?"), 5)
        XCTAssertNil(SearchService.monthMentioned(in: "what may I take from my library?"), "modal-verb 'may' must not trigger month narrowing")
    }

    // MARK: - Assembly

    func testJournalThreadAssemblesWithoutBooksOnlyRestriction() throws {
        let context = try makeContext()
        let entry = makeEntry(in: context, title: "Note", text: "Thinking a lot about momentum lately.", date: date(2026, 8, 1))

        let assembled = ChatPromptBuilder.assemble(
            userMessage: "what have I been thinking about?",
            books: [],
            selectedBookID: ChatPromptBuilder.journalThreadID,
            symposiumModeEnabled: false,
            personalWritingEntries: [entry]
        )

        guard case .journal(let systemPrompt) = assembled else {
            return XCTFail("the journal sentinel thread must assemble as .journal, got \(assembled)")
        }
        XCTAssertFalse(systemPrompt.contains("ONLY answer based on the book content"), "the books-only restriction is exactly what deflected journal questions — it must not appear here")
        XCTAssertTrue(systemPrompt.contains("Thinking a lot about momentum lately."), "the journal entries must ground the prompt")
    }

    /// Symposium mode has no coherent meaning inside the journal thread — the
    /// journal must win while it's the selected thread.
    func testJournalThreadWinsOverSymposiumMode() throws {
        let context = try makeContext()
        let entry = makeEntry(in: context, title: "Note", text: "A quiet day.", date: date(2026, 8, 2))

        let assembled = ChatPromptBuilder.assemble(
            userMessage: "how were things?",
            books: [],
            selectedBookID: ChatPromptBuilder.journalThreadID,
            symposiumModeEnabled: true,
            personalWritingEntries: [entry]
        )

        guard case .journal = assembled else {
            return XCTFail("journal thread must assemble as .journal even with symposium enabled, got \(assembled)")
        }
    }
}
