import XCTest
import SwiftData
@testable import Cobux

/// Guards cross-conversation memory.
///
/// Three of these are structural privacy properties, not behaviours: assistant
/// replies are never retrievable, the journal thread never leaks into an
/// unlocked thread, and a quieted word stays out of the incidental path.
@MainActor
final class CrossChatMemoryTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!
    private let journalID = ChatPromptBuilder.journalThreadID

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

    private func messages(_ specs: [(String, Bool, UUID?)]) throws -> [CrossChatMemory.Snapshot] {
        specs.map { text, isUser, thread in
            CrossChatMemory.Snapshot(content: text, isUser: isUser, bookID: thread,
                                     timestamp: .now, embedding: EmbeddingService.embed(text))
        }
    }

    private func block(_ query: String, _ msgs: [CrossChatMemory.Snapshot],
                       current: UUID? = nil) -> String {
        CrossChatMemory.contextBlock(
            query: query, userMessages: msgs, currentThreadID: current,
            recentWindowCutoff: nil, journalThreadID: journalID,
            threadLabel: { _ in .unknown }, useRealNames: false)
    }

    /// Assistant replies are never indexed, so they can never be retrieved --
    /// which is what stops a real name spelled out under an older toggle state
    /// from being re-injected later.
    func testAssistantRepliesAreNeverRetrieved() throws {
        let msgs = try messages([
            ("You seem to be avoiding the conversation about loyalty.", false, nil),
            ("I keep thinking about loyalty and what it costs.", true, nil),
        ])
        let out = block("what does loyalty cost", msgs)
        XCTAssertFalse(out.contains("You seem to be avoiding"),
                       "Cobux must never quote its own past opinions back as memory")
    }

    /// The journal thread sits behind Face ID. It must not reappear in an
    /// unlocked thread through retrieval.
    func testJournalThreadIsNeverRetrieved() throws {
        let msgs = try messages([
            ("The thing I never told anyone about that winter.", true, journalID),
        ])
        XCTAssertTrue(block("tell me about that winter", msgs).isEmpty,
                      "content behind the lock stays behind the lock")
    }

    /// The incidental path is unprompted by construction, so it inherits the
    /// quiet list exactly as every other ambient surface does.
    func testAQuietedWordIsExcludedFromIncidentalRetrieval() throws {
        let msgs = try messages([
            ("Priya said the same thing about loyalty back then.", true, nil),
        ])
        JournalQuietWords.add("Priya")
        XCTAssertTrue(block("what does loyalty cost", msgs).isEmpty,
                      "a quieted name must not be woven into an unrelated reply")
    }

    /// And the other half: asking directly is not ambient. Quieting means
    /// stop bringing it up at me, never hide my own words from me.
    func testADirectQuestionStillReachesHisOwnWords() throws {
        let msgs = try messages([
            ("Priya said the same thing about loyalty back then.", true, nil),
        ])
        JournalQuietWords.add("Priya")
        let out = block("what did i say about loyalty last time", msgs)
        XCTAssertFalse(out.isEmpty, "a direct question about past chats is never gated")
    }

    /// The block must always tell him which conversation and when.
    func testTheBlockRequiresAttribution() throws {
        let msgs = try messages([("I keep thinking about loyalty.", true, nil)])
        let out = block("what did i say about loyalty last time", msgs)
        XCTAssertTrue(out.contains("say which conversation"),
                      "he must always know why he is being shown something")
        XCTAssertTrue(out.contains("NEVER repeat personal names"),
                      "names stay closed by default here too")
    }

    func testTheBlockRequiresAttributionAndClosedNames() throws {
        let msgs = try messages([("I keep thinking about loyalty.", true, nil)])
        let out = block("what did i say about loyalty last time", msgs)
        XCTAssertTrue(out.contains("say which conversation"),
                      "he must always know why he is being shown something")
        XCTAssertTrue(out.contains("NEVER repeat personal names"),
                      "names stay closed by default here too")
    }

    func testTheCurrentWindowIsNotQuotedBackAtItself() throws {
        let thread = UUID()
        let msgs = try messages([("I keep thinking about loyalty.", true, thread)])
        let out = CrossChatMemory.contextBlock(
            query: "what did i say about loyalty last time", userMessages: msgs,
            currentThreadID: thread, recentWindowCutoff: .distantPast,
            journalThreadID: journalID, threadLabel: { _ in .unknown }, useRealNames: false)
        XCTAssertTrue(out.isEmpty, "messages inside the visible window are excluded")
    }
}
