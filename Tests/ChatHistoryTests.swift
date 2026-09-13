import XCTest
@testable import Cobux

/// Guards the alternation of the API conversation.
///
/// A user message is saved the moment it is sent; its reply is saved only when
/// the stream finishes. Every interrupted reply therefore leaves an orphaned
/// user message behind, and mapping saved messages straight onto API turns sent
/// two consecutive `user` roles -- which is why Cobux answered a question Rajan
/// had asked days earlier alongside the one he just asked.
@MainActor
final class ChatHistoryTests: XCTestCase {

    private func user(_ text: String) -> ChatMessage {
        ChatMessage(content: text, isUser: true)
    }
    private func assistant(_ text: String) -> ChatMessage {
        ChatMessage(content: text, isUser: false)
    }

    func testCompleteExchangesSurviveIntact() {
        let history = ChatView.alternatingHistory(from: [
            user("first"), assistant("answer one"),
            user("second"), assistant("answer two"),
        ])
        XCTAssertEqual(history.map(\.role), ["user", "assistant", "user", "assistant"])
        XCTAssertEqual(history.map(\.content),
                       ["first", "answer one", "second", "answer two"])
    }

    /// The defect itself: a question whose reply never arrived must not be
    /// re-asked on the next turn.
    func testOrphanedQuestionIsNotSentAgain() {
        let history = ChatView.alternatingHistory(from: [
            user("this one was interrupted"),
            user("this is what i am asking now"), assistant("answer"),
        ])
        XCTAssertEqual(history.map(\.role), ["user", "assistant"])
        XCTAssertEqual(history.first?.content, "this is what i am asking now")
        XCTAssertFalse(history.contains { $0.content == "this one was interrupted" })
    }

    func testNoTwoConsecutiveTurnsShareARole() {
        let history = ChatView.alternatingHistory(from: [
            user("a"), user("b"), assistant("answer b"),
            user("c"), user("d"), user("e"), assistant("answer e"),
        ])
        for (previous, next) in zip(history, history.dropFirst()) {
            XCTAssertNotEqual(previous.role, next.role,
                              "two \(previous.role) turns in a row is the bug")
        }
    }

    /// A lone assistant message cannot open a conversation.
    func testLeadingAssistantMessageIsDropped() {
        let history = ChatView.alternatingHistory(from: [
            assistant("stray"), user("real question"), assistant("real answer"),
        ])
        XCTAssertEqual(history.map(\.role), ["user", "assistant"])
        XCTAssertEqual(history.first?.content, "real question")
    }

    func testTrailingUnansweredQuestionIsNotIncluded() {
        // The live message is passed to the API separately, so it must not also
        // appear in the history or it would be sent twice.
        let history = ChatView.alternatingHistory(from: [
            user("answered"), assistant("answer"), user("still streaming"),
        ])
        XCTAssertEqual(history.map(\.role), ["user", "assistant"])
    }

    func testEmptyThreadIsEmpty() {
        XCTAssertTrue(ChatView.alternatingHistory(from: []).isEmpty)
    }
}
