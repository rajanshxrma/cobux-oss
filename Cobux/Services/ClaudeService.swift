import Foundation

enum ClaudeError: LocalizedError {
    case networkError(Error)
    case apiError(String)
    case invalidResponse
    case missingAPIKey
    case invalidAPIKey
    case truncated

    var errorDescription: String? {
        switch self {
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .apiError(let message):
            return "API error: \(message)"
        case .invalidResponse:
            return "Invalid response from Claude API"
        case .missingAPIKey:
            return "API key is missing. Please add your Anthropic API key in Settings."
        case .invalidAPIKey:
            return "Your API key was rejected. Please check it in Settings."
        case .truncated:
            return "The response was cut short."
        }
    }
}

@Observable
class ClaudeService: AIService {
    /// Per-request overrides for `streamMessageCached` — additive, defaults preserve today's
    /// exact request body. Voice mode uses this to disable adaptive thinking (thinking tokens
    /// bill as output, the most expensive class, and buy nothing for short retrieval-grounded
    /// spoken answers per Fable's voice architecture ruling) and cap `max_tokens` tighter than
    /// text chat's 8192, since a rambling spoken reply is worse UX than a short one.
    struct RequestOptions {
        var maxTokens: Int?
        var thinkingDisabled: Bool = false

        static let `default` = RequestOptions()
    }

    var apiKey: String
    var isLoading: Bool = false

    private let endpoint = "https://api.anthropic.com/v1/messages"
    private let model = "claude-sonnet-5"
    // Claude Sonnet 5 thinks adaptively by default, and thinking tokens count
    // against max_tokens — so this needs enough headroom for thinking + answer.
    private let maxTokens = 8192
    // Cap how much history is sent per request so long chats don't bloat cost.
    private let maxHistoryMessages = 20

    /// `URLSession.shared`'s default `timeoutIntervalForRequest` is 60s — for
    /// a streaming request this is an IDLE timer (time until the first
    /// byte/event arrives), not a total-duration cap. A cold prompt cache
    /// forces Anthropic to finish writing the entire cache before it can
    /// stream back a single token, so a large-but-legitimate stable prefix
    /// (even after `SearchService`'s dynamic-budget fix) can still take
    /// longer than 60s to produce a first token on a genuinely cold cache —
    /// most likely a user's very first message, or any message after the
    /// ~5-minute cache TTL lapses. This is a backstop for that legitimate
    /// case, not a substitute for the prompt-size fix itself. All three
    /// network call sites below share one instance instead of
    /// `URLSession.shared` so the timeout applies everywhere.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        return URLSession(configuration: config)
    }()

    init(apiKey: String = "") {
        self.apiKey = apiKey
    }

    func sendMessage(userMessage: String, conversationHistory: [AIMessage], systemPrompt: String) async throws -> String {
        guard !apiKey.isEmpty else {
            throw ClaudeError.missingAPIKey
        }

        let request = try buildRequest(
            userMessage: userMessage,
            conversationHistory: conversationHistory,
            systemPrompt: systemPrompt,
            stream: false
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw ClaudeError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw Self.mapAPIError(statusCode: httpResponse.statusCode, body: data)
        }

        // Content can include thinking blocks before the text block — take the first text block.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw ClaudeError.invalidResponse
        }

        // Unlike the streaming paths, this one-shot call never went through
        // `consumeStream`'s usage capture — record it here from the same
        // response body so non-streaming callers (e.g. quiz generation)
        // still show up in the monthly spend estimate instead of silently
        // undercounting real cost.
        if let usage = json["usage"] as? [String: Any] {
            UsageTracker.record(
                inputTokens: usage["input_tokens"] as? Int ?? 0,
                outputTokens: usage["output_tokens"] as? Int ?? 0,
                cacheCreationTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
                cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0
            )
        }

        return text
    }

    /// `AIService`-conforming overload -- kept as an exact-signature match (a default-valued
    /// `options` parameter on a single method does NOT satisfy protocol conformance the same
    /// way; Swift needs the literal 3-arg signature to exist) that just forwards to the
    /// options-aware overload below with `.default`.
    func streamMessage(userMessage: String, conversationHistory: [AIMessage], systemPrompt: String) -> AsyncThrowingStream<String, Error> {
        streamMessage(userMessage: userMessage, conversationHistory: conversationHistory, systemPrompt: systemPrompt, options: .default)
    }

    /// Voice mode's symposium branch passes `RequestOptions(maxTokens: 1024, thinkingDisabled:
    /// true)` explicitly, the same options the book-scoped/general voice branches already
    /// used -- without this overload existing at all, symposium voice turns ran with adaptive
    /// thinking on and an 8192-token cap, both real avoidable cost and a spoken reply the queue
    /// could take minutes to finish reading. Text chat's Symposium/Decision Consultation/Ask
    /// Intent callers keep using the 3-arg overload above, unaffected.
    func streamMessage(userMessage: String, conversationHistory: [AIMessage], systemPrompt: String, options: RequestOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    guard !apiKey.isEmpty else {
                        continuation.finish(throwing: ClaudeError.missingAPIKey)
                        return
                    }

                    let request = try buildRequest(
                        userMessage: userMessage,
                        conversationHistory: conversationHistory,
                        systemPrompt: .plain(systemPrompt),
                        stream: true,
                        options: options
                    )

                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    do {
                        (bytes, response) = try await Self.session.bytes(for: request)
                    } catch {
                        continuation.finish(throwing: ClaudeError.networkError(error))
                        return
                    }

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: ClaudeError.invalidResponse)
                        return
                    }

                    guard (200...299).contains(httpResponse.statusCode) else {
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }
                        continuation.finish(throwing: Self.mapAPIError(statusCode: httpResponse.statusCode, body: errorData))
                        return
                    }

                    let (stopReason, usage) = try await Self.consumeStream(bytes: bytes, continuation: continuation)
                    usage.record()

                    if stopReason == "max_tokens" {
                        // All streamed text has been yielded; signal that it was cut short.
                        continuation.finish(throwing: ClaudeError.truncated)
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // If the consumer stops iterating (e.g. the user taps stop),
            // cancel the network request instead of letting it run out.
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    /// Same streaming chat call as `streamMessage`, but takes the system
    /// prompt pre-split into a stable prefix (base instructions + the
    /// library's chapter map — byte-identical across every message in a
    /// session, see `SearchService.buildSplitContext`) and a dynamic suffix
    /// (this turn's ranked highlight chunks). The stable prefix is marked
    /// with Anthropic's `cache_control` so it's billed once and re-read
    /// cheaply on every subsequent message instead of resent at full price —
    /// this matters a lot on a monthly-capped key, since without it the
    /// two medical textbooks' full chapter-summary set (~116 chapters'
    /// worth) was being resent, uncached, on every single turn. Only
    /// `ChatView`'s main flow uses this; other one-shot templates (Symposium,
    /// Decision Consultation, Ask Intent) keep using the plain-string
    /// `streamMessage` above, since a single one-shot call doesn't benefit
    /// from caching the way a multi-turn study session does.
    func streamMessageCached(userMessage: String, conversationHistory: [AIMessage], stableSystemPrompt: String, dynamicContext: String, options: RequestOptions = .default) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    guard !apiKey.isEmpty else {
                        continuation.finish(throwing: ClaudeError.missingAPIKey)
                        return
                    }

                    let request = try buildRequest(
                        userMessage: userMessage,
                        conversationHistory: conversationHistory,
                        systemPrompt: .cached(stable: stableSystemPrompt, dynamic: dynamicContext),
                        stream: true,
                        options: options
                    )

                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    do {
                        (bytes, response) = try await Self.session.bytes(for: request)
                    } catch {
                        continuation.finish(throwing: ClaudeError.networkError(error))
                        return
                    }

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: ClaudeError.invalidResponse)
                        return
                    }

                    guard (200...299).contains(httpResponse.statusCode) else {
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }
                        continuation.finish(throwing: Self.mapAPIError(statusCode: httpResponse.statusCode, body: errorData))
                        return
                    }

                    let (stopReason, usage) = try await Self.consumeStream(bytes: bytes, continuation: continuation)
                    usage.record()

                    if stopReason == "max_tokens" {
                        continuation.finish(throwing: ClaudeError.truncated)
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    /// Token usage Anthropic reports for one turn, captured from the
    /// `message_start` and `message_delta` SSE events while streaming — no
    /// extra request needed, it's already in the response. Feeds
    /// `UsageTracker` so Settings can show a running spend estimate.
    private struct TurnUsage {
        var inputTokens = 0
        var outputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0

        func record() {
            UsageTracker.record(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheCreationTokens: cacheCreationTokens,
                cacheReadTokens: cacheReadTokens
            )
        }
    }

    /// Shared SSE-parsing loop for both `streamMessage` and
    /// `streamMessageCached` — reads `content_block_delta` events to yield
    /// text as it arrives, `message_start` for initial/cache token counts,
    /// and `message_delta` for the final cumulative output token count and
    /// stop reason.
    private static func consumeStream(bytes: URLSession.AsyncBytes, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws -> (stopReason: String?, usage: TurnUsage) {
        var stopReason: String?
        var usage = TurnUsage()

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))

            guard let jsonData = jsonString.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let type = event["type"] as? String else {
                continue
            }

            if type == "message_stop" {
                break
            }

            if type == "message_start",
               let message = event["message"] as? [String: Any],
               let startUsage = message["usage"] as? [String: Any] {
                usage.inputTokens = startUsage["input_tokens"] as? Int ?? 0
                usage.cacheCreationTokens = startUsage["cache_creation_input_tokens"] as? Int ?? 0
                usage.cacheReadTokens = startUsage["cache_read_input_tokens"] as? Int ?? 0
                usage.outputTokens = startUsage["output_tokens"] as? Int ?? 0
            }

            if type == "message_delta" {
                if let delta = event["delta"] as? [String: Any],
                   let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }
                // `message_delta.usage.output_tokens` is the cumulative total
                // so far — the last one seen before `message_stop` is final.
                if let deltaUsage = event["usage"] as? [String: Any],
                   let outputTokens = deltaUsage["output_tokens"] as? Int {
                    usage.outputTokens = outputTokens
                }
            }

            if type == "content_block_delta",
               let delta = event["delta"] as? [String: Any],
               let deltaType = delta["type"] as? String,
               deltaType == "text_delta",
               let text = delta["text"] as? String {
                continuation.yield(text)
            }
        }

        return (stopReason, usage)
    }

    /// How the `system` field should be built for this request: a plain
    /// string (all existing callers), or split into a cached stable prefix
    /// plus an uncached dynamic suffix (the new caching-aware chat path).
    /// `internal` (not `private`) so `ClaudeServiceTests` can construct one directly.
    enum SystemContent {
        case plain(String)
        case cached(stable: String, dynamic: String)
    }

    private func buildRequest(userMessage: String, conversationHistory: [AIMessage], systemPrompt: String, stream: Bool) throws -> URLRequest {
        try buildRequest(userMessage: userMessage, conversationHistory: conversationHistory, systemPrompt: .plain(systemPrompt), stream: stream)
    }

    /// `internal` (not `private`) so `ClaudeServiceTests` can verify the exact request body
    /// `RequestOptions` produces — including that the default leaves it byte-identical to
    /// before `RequestOptions` existed — without needing a live network call.
    func buildRequest(userMessage: String, conversationHistory: [AIMessage], systemPrompt: SystemContent, stream: Bool, options: RequestOptions = .default) throws -> URLRequest {
        guard let url = URL(string: endpoint) else {
            throw ClaudeError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var messages: [[String: String]] = []
        for message in conversationHistory.suffix(maxHistoryMessages) {
            messages.append([
                "role": message.role,
                "content": message.content
            ])
        }
        messages.append([
            "role": "user",
            "content": userMessage
        ])

        let systemField: Any
        switch systemPrompt {
        case .plain(let text):
            systemField = text
        case .cached(let stable, let dynamic):
            // Anthropic caches everything up to and including the last block
            // that carries `cache_control`, so the stable prefix must come
            // first with the cache marker on it, followed by the volatile
            // per-turn content in a separate, uncached block.
            systemField = [
                ["type": "text", "text": stable, "cache_control": ["type": "ephemeral"]],
                ["type": "text", "text": dynamic]
            ]
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": options.maxTokens ?? maxTokens,
            "system": systemField,
            "messages": messages,
            "stream": stream
        ]
        if options.thinkingDisabled {
            body["thinking"] = ["type": "disabled"]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return request
    }

    private static func mapAPIError(statusCode: Int, body: Data) -> ClaudeError {
        if let errorBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = errorBody["error"] as? [String: Any] {
            if error["type"] as? String == "authentication_error" {
                return .invalidAPIKey
            }
            if let message = error["message"] as? String {
                return .apiError(message)
            }
        }
        return .apiError("HTTP \(statusCode)")
    }
}
