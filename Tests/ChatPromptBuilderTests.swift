import XCTest
import SwiftData
@testable import Cobux

@MainActor
final class ChatPromptBuilderTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Book.self, Highlight.self, Chapter.self, ChatMessage.self, configurations: config)
        return ModelContext(container)
    }

    private func makeBook(_ title: String, author: String, in context: ModelContext) -> Book {
        let book = Book(title: title, author: author)
        context.insert(book)
        let highlight = Highlight(text: "A highlight from \(title).", chapter: "Chapter 1")
        highlight.book = book
        book.highlights.append(highlight)
        let chapter = Chapter(title: "Chapter 1", summary: "Summary of \(title).", keyLessons: ["Lesson"], chapterNumber: 1)
        chapter.book = book
        book.chapters.append(chapter)
        return book
    }

    func testSymposiumModeWinsRegardlessOfSelectedBook() throws {
        let context = try makeContext()
        let bookA = makeBook("Atomic Habits", author: "James Clear", in: context)
        let bookB = makeBook("Attached", author: "Amir Levine", in: context)

        // Deliberately mentions both books by title -- SearchService.buildContext only
        // populates citedTitles from books that actually matched (keyword/title or semantic),
        // by design: a vague query that falls back to the whole library must NOT claim every
        // book as "referenced" just because it was included as context (see buildContext's own
        // doc comment). A query with no embeddings set up and no title/author mention -- the
        // original "How do habits form?" -- legitimately produces empty citedTitles and isn't
        // testing what this test's name says it's testing.
        let assembled = ChatPromptBuilder.assemble(userMessage: "Compare Atomic Habits and Attached on behavior change", books: [bookA, bookB], selectedBookID: bookA.id, symposiumModeEnabled: true)

        guard case .symposium(let systemPrompt, let titles) = assembled else {
            return XCTFail("symposium mode must always produce .symposium, even with a book selected")
        }
        XCTAssertTrue(systemPrompt.contains("Atomic Habits"))
        XCTAssertTrue(systemPrompt.contains("Attached"))
        XCTAssertEqual(Set(titles), ["Atomic Habits", "Attached"])
    }

    func testBookScopedThreadNeverCarriesReferencedTitles() throws {
        let context = try makeContext()
        let book = makeBook("Atomic Habits", author: "James Clear", in: context)

        let assembled = ChatPromptBuilder.assemble(userMessage: "Summarize chapter 1", books: [book], selectedBookID: book.id, symposiumModeEnabled: false)

        guard case .bookScoped(let stableSystemPrompt, _) = assembled else {
            return XCTFail("a selected book with symposium off must produce .bookScoped")
        }
        XCTAssertTrue(stableSystemPrompt.contains("Atomic Habits"))
        XCTAssertTrue(stableSystemPrompt.contains("James Clear"))
    }

    func testNoSelectedBookProducesGeneralWithReferencedTitles() throws {
        let context = try makeContext()
        let bookA = makeBook("Atomic Habits", author: "James Clear", in: context)
        let bookB = makeBook("Attached", author: "Amir Levine", in: context)

        let assembled = ChatPromptBuilder.assemble(userMessage: "What did James Clear say about habits?", books: [bookA, bookB], selectedBookID: nil, symposiumModeEnabled: false)

        guard case .general(let stableSystemPrompt, _, let titles) = assembled else {
            return XCTFail("no selected book with symposium off must produce .general")
        }
        XCTAssertFalse(stableSystemPrompt.isEmpty)
        XCTAssertFalse(titles.isEmpty)
    }

    func testStaleSelectedBookIDFallsBackToGeneral() throws {
        // The selected book was deleted or the ID is otherwise stale — must not crash, and
        // must fall back to the general (unscoped) path rather than a scoped path with no book.
        let context = try makeContext()
        let book = makeBook("Atomic Habits", author: "James Clear", in: context)

        let assembled = ChatPromptBuilder.assemble(userMessage: "anything", books: [book], selectedBookID: UUID(), symposiumModeEnabled: false)

        guard case .general = assembled else {
            return XCTFail("a selectedBookID matching no book in the library must fall back to .general")
        }
    }

    // MARK: - Byte-identical to the pre-refactor ChatView.sendMessage logic

    func testGeneralPromptMatchesDirectSearchServiceCallExactly() throws {
        let context = try makeContext()
        let book = makeBook("Atomic Habits", author: "James Clear", in: context)
        let query = "What did James Clear say about habits?"

        let assembled = ChatPromptBuilder.assemble(userMessage: query, books: [book], selectedBookID: nil, symposiumModeEnabled: false)
        guard case .general(let stableSystemPrompt, let dynamicContext, let titles) = assembled else {
            return XCTFail("expected .general")
        }

        let (expectedStable, expectedDynamic, expectedTitles) = SearchService.buildSplitContext(query: query, books: [book])
        let expectedSystemPrompt = String(format: PromptTemplates.base, expectedStable)

        XCTAssertEqual(stableSystemPrompt, expectedSystemPrompt)
        XCTAssertEqual(dynamicContext, expectedDynamic)
        XCTAssertEqual(titles, expectedTitles)
    }

    // MARK: - Voice mode: spoken-style instructions in the dynamic suffix only

    func testVoiceModeLeavesGeneralStablePrefixByteIdenticalToText() throws {
        let context = try makeContext()
        let book = makeBook("Atomic Habits", author: "James Clear", in: context)
        let query = "What did James Clear say about habits?"

        let textAssembled = ChatPromptBuilder.assemble(userMessage: query, books: [book], selectedBookID: nil, symposiumModeEnabled: false, isVoice: false)
        let voiceAssembled = ChatPromptBuilder.assemble(userMessage: query, books: [book], selectedBookID: nil, symposiumModeEnabled: false, isVoice: true)

        guard case .general(let textStable, let textDynamic, _) = textAssembled,
              case .general(let voiceStable, let voiceDynamic, _) = voiceAssembled else {
            return XCTFail("expected .general for both")
        }

        // The cached prefix must be identical so voice and text share one prompt-cache entry.
        XCTAssertEqual(textStable, voiceStable)
        // The spoken-style instruction must land in the dynamic (uncached) suffix instead.
        XCTAssertNotEqual(textDynamic, voiceDynamic)
        XCTAssertTrue(voiceDynamic.contains("read aloud"))
        XCTAssertTrue(voiceDynamic.contains("<sources>"), "general chat has a sources instruction, so the voice reminder must reference it")
    }

    /// Was `testVoiceModeBookScopedOmitsSourcesReminderItWasNeverGiven`, and it
    /// asserted the opposite of what this now checks. That was correct while a
    /// book-scoped thread could only ever answer from its own single book, so
    /// naming a source carried no information. It can now genuinely draw on a
    /// second book, so its template carries the sources instruction like every
    /// other path and the spoken variant must reference it — otherwise a voice
    /// turn that reached across books would lose the citation.
    func testVoiceModeBookScopedAppendsSourcesReminder() throws {
        let context = try makeContext()
        let book = makeBook("Atomic Habits", author: "James Clear", in: context)

        let voiceAssembled = ChatPromptBuilder.assemble(userMessage: "Summarize chapter 1", books: [book], selectedBookID: book.id, symposiumModeEnabled: false, isVoice: true)

        guard case .bookScoped(let stableSystemPrompt, let dynamicContext) = voiceAssembled else {
            return XCTFail("expected .bookScoped")
        }
        XCTAssertFalse(stableSystemPrompt.contains("read aloud"), "spoken-style instructions must never touch the cached stable prefix")
        XCTAssertTrue(dynamicContext.contains("read aloud"))
        XCTAssertTrue(dynamicContext.contains("<sources>"), "bookScoped now instructs a <sources> tag, so voice must remind the model to still emit it")
    }

    /// The capability half of Rajan's report: a book-scoped thread must be able
    /// to reach another book when the question names it, instead of refusing
    /// and suggesting the general thread.
    func testBookScopedThreadPullsInAnotherBookTheQueryNames() throws {
        let context = try makeContext()
        let focus = makeBook("Atomic Habits", author: "James Clear", in: context)
        let other = makeBook("Beyond Order", author: "Jordan B. Peterson", in: context)
        let peterson = Highlight(text: "Set your house in perfect order before you criticize the world.", chapter: "Rule 6")
        peterson.book = other
        other.highlights.append(peterson)

        let assembled = ChatPromptBuilder.assemble(
            userMessage: "what would Jordan Peterson say about this?",
            books: [focus, other],
            selectedBookID: focus.id,
            symposiumModeEnabled: false
        )
        guard case .bookScoped(let stableSystemPrompt, let dynamicContext) = assembled else {
            return XCTFail("expected .bookScoped")
        }
        XCTAssertTrue(dynamicContext.contains("Beyond Order"), "a named second book must reach the prompt, not be refused")
        XCTAssertFalse(stableSystemPrompt.contains("Beyond Order"), "cross-book material must ride in the uncached suffix, never widen the cached prefix")
    }

    /// The other half: an ordinary in-book question must NOT drag the rest of
    /// the library in. This is what keeps a book-scoped thread cheaper and more
    /// focused than the general thread rather than a cosmetic label.
    func testBookScopedThreadStaysFocusedWhenNothingReachesOutside() throws {
        let context = try makeContext()
        let focus = makeBook("Atomic Habits", author: "James Clear", in: context)
        let other = makeBook("Beyond Order", author: "Jordan B. Peterson", in: context)
        let peterson = Highlight(text: "Set your house in perfect order before you criticize the world.", chapter: "Rule 6")
        peterson.book = other
        other.highlights.append(peterson)

        let assembled = ChatPromptBuilder.assemble(
            userMessage: "Summarize chapter 1",
            books: [focus, other],
            selectedBookID: focus.id,
            symposiumModeEnabled: false
        )
        guard case .bookScoped(_, let dynamicContext) = assembled else {
            return XCTFail("expected .bookScoped")
        }
        XCTAssertFalse(dynamicContext.contains("Other Books In This Library"), "an in-book question must not pull the rest of the library in")
    }

    /// A book-scoped reply naming only its own book produces no chip; one that
    /// reached across books does. Both channels share this rule.
    func testBookScopedCitationsDropTheThreadsOwnBook() throws {
        let context = try makeContext()
        let focus = makeBook("Atomic Habits", author: "James Clear", in: context)
        let other = makeBook("Beyond Order", author: "Jordan B. Peterson", in: context)

        XCTAssertEqual(
            ChatPromptBuilder.displayableCitations(resolvedTitles: ["Atomic Habits"], selectedBookID: focus.id, books: [focus, other]),
            []
        )
        XCTAssertEqual(
            ChatPromptBuilder.displayableCitations(resolvedTitles: ["Atomic Habits", "Beyond Order"], selectedBookID: focus.id, books: [focus, other]),
            ["Beyond Order"]
        )
        XCTAssertEqual(
            ChatPromptBuilder.displayableCitations(resolvedTitles: ["Atomic Habits", "Beyond Order"], selectedBookID: nil, books: [focus, other]),
            ["Atomic Habits", "Beyond Order"],
            "the general thread must keep every declared citation"
        )
    }

    func testVoiceModeSymposiumAppendsSpokenInstructionWithSourcesReminder() throws {
        let context = try makeContext()
        let book = makeBook("Atomic Habits", author: "James Clear", in: context)

        let voiceAssembled = ChatPromptBuilder.assemble(userMessage: "anything", books: [book], selectedBookID: nil, symposiumModeEnabled: true, isVoice: true)

        guard case .symposium(let systemPrompt, _) = voiceAssembled else {
            return XCTFail("expected .symposium")
        }
        XCTAssertTrue(systemPrompt.contains("read aloud"))
        XCTAssertTrue(systemPrompt.contains("<sources>"))
    }
}
