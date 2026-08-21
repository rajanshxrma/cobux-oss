import Foundation

/// Bounded retry for transient Claude API failures. Used by quiz generation, which
/// used to abandon an entire batch of chapters on the first network blip
/// (`QuizScopeBuilderView.generateThenStart`) with no retry at all.
///
/// Retries ONLY what's actually transient: `.networkError` (the connection itself
/// failed) and `.retryableAPIError` with a 429 (rate limit) or 5xx server status.
/// Never retries `.invalidAPIKey`/`.missingAPIKey` (retrying a bad key is pointless
/// noise, not recoverable), `.invalidResponse`/`.truncated` (a malformed response
/// isn't fixed by asking again), plain `.apiError` (a business-logic refusal
/// like "Claude declined to generate questions" — not transient, retrying just
/// re-asks the same question and bills again for the same answer), or `.offline`
/// (raised before a request was even attempted -- retrying in a tight backoff loop
/// while still offline is exactly the "stuck spinner" this fast-fail case exists to
/// avoid; the surfaced message already tells the user to retry manually once
/// reconnected).
///
/// Bounded on BOTH sides deliberately: max 2 retries (3 attempts total) caps how
/// long a user waits, and — since each retry is a second full paid API call, not a
/// free reconnect — caps real dollar exposure from a chapter that keeps failing.
enum RetryPolicy {
    static let maxRetries = 2

    static func isRetryable(_ error: Error) -> Bool {
        guard let claudeError = error as? ClaudeError else { return false }
        switch claudeError {
        case .networkError:
            return true
        case .retryableAPIError(let statusCode, _):
            return statusCode == 429 || (500...599).contains(statusCode)
        case .apiError, .invalidResponse, .missingAPIKey, .invalidAPIKey, .truncated, .offline:
            return false
        }
    }

    /// Runs `operation`, retrying with exponential backoff (0.5s, 1s, ...) only on a
    /// retryable failure, up to `maxRetries` additional attempts. A non-retryable
    /// error is rethrown immediately on its first occurrence, not retried.
    @discardableResult
    static func run<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < maxRetries, isRetryable(error) else { throw error }
                let backoffSeconds = pow(2.0, Double(attempt)) * 0.5
                try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                attempt += 1
            }
        }
    }
}
