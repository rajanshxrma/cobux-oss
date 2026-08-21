import Foundation
import CobuxCore

/// Non-interactive, cost-sensitive Claude API calls used by quiz question
/// generation — as opposed to `ClaudeService`'s streaming chat path, which
/// stays on Sonnet 5 with adaptive thinking on because that's the
/// quality-sensitive, already-cheap-per-turn path. Generation is different:
/// it's bulk, structured, and the actual cost driver on a monthly-capped key
/// (Utkarsh's ~$5/month), so every lever that reduces cost without hurting
/// question quality is worth using here specifically:
///
/// - **Structured outputs** (`output_config.format`) replace the old
///   "respond with ONLY a JSON array, no markdown fences" instruction +
///   fence-stripping decode. The API enforces the shape itself, so a
///   response can't come back malformed.
/// - **Thinking disabled** — generation is a mechanical transformation of
///   already-curated highlights into question JSON, not open-ended
///   reasoning. Sonnet 5 thinks adaptively by default, and thinking tokens
///   bill the same as output tokens, so turning it off for this one call
///   shape is a real, free cost reduction.
/// - **Model choice** — every call here takes `model` as a parameter rather
///   than hardcoding Sonnet 5, so `QuizGenerationService` can route bulk
///   generation to Haiku 4.5 and reserve Sonnet 5 for question types that
///   benefit from it (see `QuestionQuality`).
/// - **Batch API** — the same request shape submitted as batch items gets
///   a 50% price cut in exchange for up-to-24h turnaround, so whole-book
///   pre-generation (see `BatchGenerationService`) goes through here too.
extension ClaudeService {
    /// One-shot, non-streaming generation call with a JSON-schema-constrained
    /// response. Returns the raw JSON text — already schema-valid, so callers
    /// decode it directly with no fence-stripping or cleanup.
    func generateStructured(userMessage: String, systemPrompt: String, model: CobuxModelID, jsonSchema: [String: Any]) async throws -> String {
        guard !apiKey.isEmpty else { throw ClaudeError.missingAPIKey }
        guard await NetworkMonitor.shared.isConnected else { throw ClaudeError.offline }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.generationRequestBody(
            userMessage: userMessage, systemPrompt: systemPrompt, model: model, jsonSchema: jsonSchema
        ))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClaudeError.networkError(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else { throw ClaudeError.invalidResponse }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw Self.mapGenerationAPIError(statusCode: httpResponse.statusCode, body: data)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.invalidResponse
        }

        if let stopReason = json["stop_reason"] as? String, stopReason == "refusal" {
            throw ClaudeError.apiError("Claude declined to generate questions for this content.")
        }

        if let usage = json["usage"] as? [String: Any] {
            // purpose: .generation explicitly -- this function is only ever called for quiz
            // generation, even when it runs on Sonnet (.thorough quality, or any exam-style
            // chapter). Inferring purpose from model would book those as chat, the exact bug
            // this explicit parameter exists to prevent.
            UsageTracker.record(
                inputTokens: usage["input_tokens"] as? Int ?? 0,
                outputTokens: usage["output_tokens"] as? Int ?? 0,
                cacheCreationTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
                cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
                model: model.rateTableModel,
                purpose: .generation
            )
        }

        guard let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw ClaudeError.invalidResponse
        }
        return text
    }

    /// Real token count for a prospective generation request, via Anthropic's
    /// `/v1/messages/count_tokens` endpoint — no generation happens, this
    /// just prices the request. Used in place of `QuizGenerationService`'s
    /// old fixed-ratio heuristic (`~120 tokens/highlight + 600 fixed`) so the
    /// cost estimate shown before spending money is the real one.
    func countGenerationTokens(userMessage: String, systemPrompt: String, model: CobuxModelID) async throws -> Int {
        guard !apiKey.isEmpty else { throw ClaudeError.missingAPIKey }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages/count_tokens")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model.rawValue,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userMessage]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw ClaudeError.invalidResponse
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inputTokens = json["input_tokens"] as? Int else {
            throw ClaudeError.invalidResponse
        }
        return inputTokens
    }

    /// The request body shape shared by a live call and a Batch API item —
    /// `thinking: disabled` and `output_config.format` are set unconditionally
    /// here, so no generation call site can accidentally skip them.
    static func generationRequestBody(userMessage: String, systemPrompt: String, model: CobuxModelID, jsonSchema: [String: Any]) -> [String: Any] {
        [
            "model": model.rawValue,
            "max_tokens": 8192,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userMessage]],
            "thinking": ["type": "disabled"],
            "output_config": [
                "format": [
                    "type": "json_schema",
                    "schema": jsonSchema
                ]
            ]
        ]
    }

    private static func mapGenerationAPIError(statusCode: Int, body: Data) -> ClaudeError {
        if let errorBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = errorBody["error"] as? [String: Any] {
            if error["type"] as? String == "authentication_error" { return .invalidAPIKey }
            if let message = error["message"] as? String { return .retryableAPIError(statusCode: statusCode, message: message) }
        }
        return .retryableAPIError(statusCode: statusCode, message: "HTTP \(statusCode)")
    }

    // MARK: - Batch API

    /// One item in a batch submission — same shape as a live generation
    /// call, plus a `customID` the caller picks so results can be matched
    /// back up once the batch ends (Anthropic returns them unordered).
    struct BatchItem {
        let customID: String
        let userMessage: String
        let systemPrompt: String
        let model: CobuxModelID
        let jsonSchema: [String: Any]
    }

    enum BatchProcessingStatus: String {
        case inProgress = "in_progress"
        case canceling
        case ended
    }

    struct BatchHandle {
        let id: String
    }

    struct BatchStatusReport {
        let status: BatchProcessingStatus
        let processing: Int
        let succeeded: Int
        let errored: Int
        let canceled: Int
        let expired: Int
        let resultsURL: String?

        var isDone: Bool { status == .ended }
    }

    struct BatchResult {
        let customID: String
        let succeeded: Bool
        let text: String?
        let errorMessage: String?
    }

    /// Submits a batch of generation requests at once. Batch pricing is
    /// roughly half the live-call rate in exchange for up to ~24h
    /// turnaround, so this is the path `BatchGenerationService` uses for
    /// whole-book pre-generation rather than the interactive per-chapter
    /// flow (`QuizGenerationService.generateQuestions`), which needs an
    /// answer in seconds and stays on the live `generateStructured` call.
    func submitBatch(_ items: [BatchItem]) async throws -> BatchHandle {
        guard !apiKey.isEmpty else { throw ClaudeError.missingAPIKey }
        guard !items.isEmpty else { throw ClaudeError.apiError("No items to submit.") }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages/batches")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let requests = items.map { item -> [String: Any] in
            [
                "custom_id": item.customID,
                "params": Self.generationRequestBody(
                    userMessage: item.userMessage, systemPrompt: item.systemPrompt,
                    model: item.model, jsonSchema: item.jsonSchema
                )
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["requests": requests])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw Self.mapGenerationAPIError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw ClaudeError.invalidResponse
        }
        return BatchHandle(id: id)
    }

    /// Polls a batch's current state. Callers loop this at their own
    /// cadence (`BatchGenerationService` uses a background task with a
    /// several-minute interval, not a tight poll) until `isDone`.
    func batchStatus(_ handle: BatchHandle) async throws -> BatchStatusReport {
        guard !apiKey.isEmpty else { throw ClaudeError.missingAPIKey }

        // `handle.id` is Anthropic's own batch ID, not user input, so this "should"
        // always be a well-formed URL -- but `ClaudeService.swift`'s equivalent
        // request-building already uses `guard let` rather than force-unwrap for
        // exactly this reason (an API-issued value is still not a guarantee), and
        // these two `ClaudeGenerationService` call sites were the two places that
        // hadn't matched that pattern yet.
        guard let url = URL(string: "https://api.anthropic.com/v1/messages/batches/\(handle.id)") else {
            throw ClaudeError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw Self.mapGenerationAPIError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusRaw = json["processing_status"] as? String,
              let status = BatchProcessingStatus(rawValue: statusRaw) else {
            throw ClaudeError.invalidResponse
        }
        let counts = json["request_counts"] as? [String: Any] ?? [:]
        return BatchStatusReport(
            status: status,
            processing: counts["processing"] as? Int ?? 0,
            succeeded: counts["succeeded"] as? Int ?? 0,
            errored: counts["errored"] as? Int ?? 0,
            canceled: counts["canceled"] as? Int ?? 0,
            expired: counts["expired"] as? Int ?? 0,
            resultsURL: json["results_url"] as? String
        )
    }

    /// Fetches and decodes a finished batch's results (JSONL, one result
    /// object per line, returned unordered — matched back up via `customID`).
    /// `modelByCustomID` is how the real per-item model (Haiku for bulk chapters, Sonnet
    /// for clinical-vignette chapters — `submitBatch` items aren't all the same model) gets
    /// to the usage recording below; without it every batch result was being priced at
    /// Sonnet's rate regardless of which model actually ran, and at full live-call rates
    /// despite the batch discount, together overstating real batched-Haiku spend ~4x.
    func batchResults(_ handle: BatchHandle, resultsURL: String, modelByCustomID: [String: CobuxModelID] = [:]) async throws -> [BatchResult] {
        guard !apiKey.isEmpty else { throw ClaudeError.missingAPIKey }
        guard let url = URL(string: resultsURL) else { throw ClaudeError.invalidResponse }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw ClaudeError.invalidResponse
        }
        guard let body = String(data: data, encoding: .utf8) else { throw ClaudeError.invalidResponse }

        var results: [BatchResult] = []
        for line in body.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let customID = entry["custom_id"] as? String,
                  let result = entry["result"] as? [String: Any],
                  let resultType = result["type"] as? String else { continue }

            if resultType == "succeeded",
               let message = result["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]],
               let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String {
                if let usage = message["usage"] as? [String: Any] {
                    // The real per-item model (falls back to Sonnet, the more expensive
                    // side, only if a caller genuinely didn't supply the map -- e.g. an
                    // in-flight batch submitted before this fix landed).
                    let model = modelByCustomID[customID]?.rateTableModel ?? .sonnet5
                    UsageTracker.record(
                        inputTokens: usage["input_tokens"] as? Int ?? 0,
                        outputTokens: usage["output_tokens"] as? Int ?? 0,
                        cacheCreationTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
                        cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
                        model: model,
                        batch: true,
                        purpose: .generation
                    )
                }
                results.append(BatchResult(customID: customID, succeeded: true, text: text, errorMessage: nil))
            } else {
                let errorMessage = (result["error"] as? [String: Any])?["message"] as? String ?? resultType
                results.append(BatchResult(customID: customID, succeeded: false, text: nil, errorMessage: errorMessage))
            }
        }
        return results
    }

    /// Cancels an in-flight batch. Already-completed items still finish and
    /// bill; only unstarted/in-progress items stop. Safe to call on a batch
    /// that has already ended — the API just reports it as ended.
    func cancelBatch(_ handle: BatchHandle) async throws {
        guard !apiKey.isEmpty else { throw ClaudeError.missingAPIKey }

        guard let url = URL(string: "https://api.anthropic.com/v1/messages/batches/\(handle.id)/cancel") else {
            throw ClaudeError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw Self.mapGenerationAPIError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        }
    }
}

/// The two models Cobux's generation pipeline chooses between. A distinct
/// type from `CobuxCore.CobuxModel` (which prices, not calls) so a caller
/// can't accidentally pass a chat-path model string here — mapped
/// explicitly to `CobuxCore.CobuxModel` for pricing via `rateTableModel`.
enum CobuxModelID: String, Codable {
    case sonnet5 = "claude-sonnet-5"
    case haiku45 = "claude-haiku-4-5"

    var rateTableModel: CobuxModel {
        switch self {
        case .sonnet5: return .sonnet5
        case .haiku45: return .haiku45
        }
    }
}

/// The "Question quality" setting exposed in Settings — trades generation
/// cost against question sophistication. Matches the plan's own call:
/// *"Haiku 4.5 for bulk generation, Sonnet 5 for clinical vignettes"* is
/// `.balanced`, the default; `.efficient`/`.thorough` are the two knobs
/// either side of it for a $5-capped key that needs to stretch further, or
/// a chat-only user who doesn't care about generation cost at all.
enum QuestionQuality: String, CaseIterable, Identifiable {
    case efficient
    case balanced
    case thorough

    var id: String { rawValue }

    var label: String {
        switch self {
        case .efficient: return "Efficient"
        case .balanced: return "Balanced"
        case .thorough: return "Thorough"
        }
    }

    var detail: String {
        switch self {
        case .efficient: return "Haiku 4.5 for every question — cheapest, best for stretching a capped key."
        case .balanced: return "Haiku 4.5 for most questions, Sonnet 5 for exam-style vignettes."
        case .thorough: return "Sonnet 5 for every question — highest quality, highest cost."
        }
    }

    /// `isExamStyle` mirrors `BookContentProfile.isExamStyleQuiz` — the
    /// existing signal for "this chapter's quiz should read like a clinical
    /// vignette bank," which is exactly the content `.balanced` reserves
    /// for Sonnet.
    func model(isExamStyle: Bool) -> CobuxModelID {
        switch self {
        case .efficient: return .haiku45
        case .balanced: return isExamStyle ? .sonnet5 : .haiku45
        case .thorough: return .sonnet5
        }
    }
}
