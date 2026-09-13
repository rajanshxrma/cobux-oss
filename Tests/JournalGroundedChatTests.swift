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
        // The coverage header is one sentence group at the top (~400 chars);
        // the bound allows for it explicitly rather than leaning on the
        // per-entry slack.
        XCTAssertLessThan(
            block.count,
            SearchService.journalThreadTopK * (SearchService.journalThreadEntryCharLimit + 200) + 600,
            "the whole block must stay bounded"
        )
    }

    /// Rajan, build 57: "Can you access before September 7 on all my journals?"
    /// was answered with "My earliest entry is September 7". The month word
    /// narrowed the pool to September for a question about everything before
    /// it. A range word must leave the whole archive in play.
    func testRangeQuestionDoesNotNarrowToTheNamedMonth() throws {
        let context = try makeContext()
        let old = makeEntry(in: context, title: "Beginnings", text: "First week in the new city, everything unfamiliar.", date: date(2022, 3, 3))
        let september = makeEntry(in: context, title: "Now", text: "Shipped the build and slept well for once.", date: date(2026, 9, 7))

        let block = SearchService.buildJournalContext(query: "Can you access before September 7 on all my journals? Give me a quick summary.", entries: [old, september])

        XCTAssertTrue(block.contains("First week in the new city"), "a 'before September' question must reach entries before September")
        XCTAssertTrue(block.contains("March 3, 2022"), "the oldest entry must be present, dated")
    }

    /// The header the model answers coverage questions from. Without it the
    /// model's only honest move is to call the oldest EXCERPT the oldest ENTRY,
    /// which is exactly the reply he screenshotted.
    func testCoverageHeaderStatesCountAndSpanBeforeAnyExcerpt() throws {
        let context = try makeContext()
        let entries = [
            makeEntry(in: context, title: "One", text: "Alpha.", date: date(2022, 3, 3)),
            makeEntry(in: context, title: "Two", text: "Beta.", date: date(2024, 6, 15)),
            makeEntry(in: context, title: "Three", text: "Gamma.", date: date(2026, 9, 12)),
        ]

        let block = SearchService.buildJournalContext(query: "how have I been doing lately?", entries: entries)

        XCTAssertTrue(block.hasPrefix("The journal holds 3 entries, from March 3, 2022 to September 12, 2026."), "the header must lead the block: \(block.prefix(120))")
        XCTAssertTrue(block.contains("Do not describe the earliest excerpt as the earliest entry"))
        let headerEnd = block.range(of: "\n\n")!.lowerBound
        XCTAssertTrue(block[..<headerEnd].contains("Every entry is excerpted below"), "when every entry fits, the header says so rather than claiming a selection")
    }

    /// The header must be honest about a narrowed pool, too: a period question
    /// gets a header that says the excerpts are that month's, so the model
    /// does not read three September entries as the whole journal.
    func testCoverageHeaderNamesTheNarrowedMonth() throws {
        let context = try makeContext()
        let march = makeEntry(in: context, title: "Spring", text: "Rebuilding the routine.", date: date(2026, 3, 2))
        let july = makeEntry(in: context, title: "Summer", text: "Shipped and slept badly.", date: date(2026, 7, 9))

        let block = SearchService.buildJournalContext(query: "what was I writing about in March?", entries: [march, july])

        XCTAssertTrue(block.contains("The journal holds 2 entries"), "the count is the whole journal's, not the narrowed pool's")
        XCTAssertTrue(block.contains("drawn from March entries only"), "a narrowed pool must be declared")
    }

    /// Entries without a vector are his writing too. With more embedded entries
    /// than slots, the ranked list used to fill every slot and the imported
    /// archive -- waiting on the backfill -- never appeared. A share of the
    /// slots is reserved for it.
    func testUnembeddedEntriesKeepAShareOfTheSlots() throws {
        let context = try makeContext()
        let vector = [Float](repeating: 0.5, count: 512)
        let embedded = (0..<20).map { index in
            let entry = makeEntry(in: context, title: "Recent \(index)", text: "An embedded entry about routine and sleep.", date: date(2026, 9, index + 1))
            entry.embedding = vector
            return entry
        }
        let imported = (0..<5).map { index in
            makeEntry(in: context, title: "Imported \(index)", text: "An imported entry from years ago, still unembedded.", date: date(2023, 1, index + 1))
        }

        let block = SearchService.buildJournalContext(query: "how has my sleep been?", entries: embedded + imported)

        let importedShown = (0..<5).filter { block.contains("\"Imported \($0)\"") }.count
        XCTAssertGreaterThanOrEqual(importedShown, min(5, SearchService.journalThreadUnembeddedReserve), "un-embedded entries must hold their reserved share even when embedded entries could fill every slot")
        let recentShown = (0..<20).filter { block.contains("\"Recent \($0)\"") }.count
        XCTAssertLessThanOrEqual(importedShown + recentShown, SearchService.journalThreadTopK)
    }

    /// "My earliest entries" is a date question. The pool leans toward the
    /// oldest entries instead of asking cosine similarity what "earliest" means.
    func testEarliestQuestionLeansTowardTheOldestEntries() throws {
        let context = try makeContext()
        let entries = (0..<30).map { index in
            makeEntry(in: context, title: "Entry \(index)", text: "Ordinary day number \(index).", date: date(2022 + index / 12, index % 12 + 1, 10))
        }

        let block = SearchService.buildJournalContext(query: "what were my earliest entries about?", entries: entries)

        for index in 0..<(SearchService.journalThreadTopK / 2) {
            XCTAssertTrue(block.contains("\"Entry \(index)\""), "the oldest entries must be present for an earliest question; missing Entry \(index)")
        }
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

    // MARK: - Reach classification

    /// `monthMentioned` stays blind to range words on purpose -- it answers
    /// "is a month named"; `journalReach` answers "filter or boundary".
    func testRangeWordsMakeANamedMonthABoundary() {
        XCTAssertEqual(SearchService.monthMentioned(in: "Can you access before September 7 on all my journals?"), 9)
        XCTAssertEqual(SearchService.journalReach(of: "Can you access before September 7 on all my journals?"), .earliest)
        XCTAssertEqual(SearchService.journalReach(of: "what have I written since June?"), .range)
        XCTAssertEqual(SearchService.journalReach(of: "what did I write between March and July?"), .range)
        XCTAssertEqual(SearchService.journalReach(of: "summarize everything from March to July"), .range)
        XCTAssertEqual(SearchService.journalReach(of: "what is my oldest entry?"), .earliest)
        XCTAssertEqual(SearchService.journalReach(of: "give me a summary of all my journals"), .range)
    }

    func testPeriodQuestionsKeepMonthNarrowing() {
        XCTAssertEqual(SearchService.journalReach(of: "what was I writing about in March?"), .period)
        XCTAssertEqual(SearchService.journalReach(of: "how was I doing last May?"), .period)
        XCTAssertEqual(SearchService.journalReach(of: "anything from jan worth rereading?"), .period, "'from' alone is not a span -- 'from my journal' is everywhere")
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
