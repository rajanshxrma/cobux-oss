import XCTest
@testable import Cobux

final class ClaudeServiceTests: XCTestCase {

    private func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return json
    }

    // MARK: - Default RequestOptions must not change today's request shape

    func testDefaultOptionsOmitThinkingKeyEntirely() throws {
        let service = ClaudeService(apiKey: "test-key")
        let request = try service.buildRequest(
            userMessage: "hello",
            conversationHistory: [],
            systemPrompt: .cached(stable: "stable prefix", dynamic: "dynamic suffix"),
            stream: true
        )
        let body = try bodyJSON(request)
        XCTAssertNil(body["thinking"], "default options must leave the request byte-identical to before RequestOptions existed")
    }

    func testDefaultOptionsUseStandardMaxTokens() throws {
        let service = ClaudeService(apiKey: "test-key")
        let request = try service.buildRequest(
            userMessage: "hello",
            conversationHistory: [],
            systemPrompt: .cached(stable: "stable prefix", dynamic: "dynamic suffix"),
            stream: true
        )
        let body = try bodyJSON(request)
        XCTAssertEqual(body["max_tokens"] as? Int, 8192)
    }

    // MARK: - Voice-mode overrides

    func testThinkingDisabledOptionSetsThinkingTypeDisabled() throws {
        let service = ClaudeService(apiKey: "test-key")
        let options = ClaudeService.RequestOptions(thinkingDisabled: true)
        let request = try service.buildRequest(
            userMessage: "hello",
            conversationHistory: [],
            systemPrompt: .cached(stable: "stable prefix", dynamic: "dynamic suffix"),
            stream: true,
            options: options
        )
        let body = try bodyJSON(request)
        let thinking = try XCTUnwrap(body["thinking"] as? [String: String])
        XCTAssertEqual(thinking["type"], "disabled")
    }

    func testMaxTokensOverrideAppliesInsteadOfStandardValue() throws {
        let service = ClaudeService(apiKey: "test-key")
        let options = ClaudeService.RequestOptions(maxTokens: 1024)
        let request = try service.buildRequest(
            userMessage: "hello",
            conversationHistory: [],
            systemPrompt: .cached(stable: "stable prefix", dynamic: "dynamic suffix"),
            stream: true,
            options: options
        )
        let body = try bodyJSON(request)
        XCTAssertEqual(body["max_tokens"] as? Int, 1024)
    }

    func testCombinedOptionsBothApply() throws {
        let service = ClaudeService(apiKey: "test-key")
        let options = ClaudeService.RequestOptions(maxTokens: 1024, thinkingDisabled: true)
        let request = try service.buildRequest(
            userMessage: "hello",
            conversationHistory: [],
            systemPrompt: .cached(stable: "stable prefix", dynamic: "dynamic suffix"),
            stream: true,
            options: options
        )
        let body = try bodyJSON(request)
        XCTAssertEqual(body["max_tokens"] as? Int, 1024)
        let thinking = try XCTUnwrap(body["thinking"] as? [String: String])
        XCTAssertEqual(thinking["type"], "disabled")
    }

    // MARK: - Cached system prompt shape is unaffected by options

    func testCachedSystemPromptStructureUnaffectedByOptions() throws {
        let service = ClaudeService(apiKey: "test-key")
        let options = ClaudeService.RequestOptions(thinkingDisabled: true)
        let request = try service.buildRequest(
            userMessage: "hello",
            conversationHistory: [],
            systemPrompt: .cached(stable: "stable prefix", dynamic: "dynamic suffix"),
            stream: true,
            options: options
        )
        let body = try bodyJSON(request)
        let system = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 2)
        XCTAssertEqual(system[0]["text"] as? String, "stable prefix")
        XCTAssertNotNil(system[0]["cache_control"], "stable prefix must keep its cache_control marker regardless of RequestOptions")
        XCTAssertEqual(system[1]["text"] as? String, "dynamic suffix")
        XCTAssertNil(system[1]["cache_control"], "dynamic suffix must never be cached")
    }
}
