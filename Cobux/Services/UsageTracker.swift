import Foundation
import CobuxCore

/// Tracks an estimated running monthly spend against the Anthropic API key
/// currently saved in this app, purely from token counts Anthropic already
/// reports in its own streaming responses — no extra network calls, no cost
/// of its own. Exists specifically because Cobux's AI chat runs on a
/// monthly-capped key (Utkarsh's key is capped around $5), and there was
/// previously no way to see spend building up before a confusing mid-session
/// hard stop. This is an ESTIMATE for visibility, not a source of truth —
/// Anthropic's own console/cap enforcement is authoritative.
///
/// Pricing itself now comes from `CobuxCore.RateTable`, not hardcoded
/// constants here — this file used to carry its own `$2/$10` introductory
/// rates with a hand-written comment flagging that they expire 2026-08-31.
/// `RateTable` is effective-dated (both the introductory and the
/// post-08-31 `$3/$15` standard rate are already on file) and has its own
/// self-failing staleness test, so this can't quietly go stale the same way.
struct UsageTracker {
    private static let defaults = UserDefaults.standard
    private static func monthKey(for date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return "cobux.usageEstimate." + formatter.string(from: date)
    }

    /// Adds one turn's token usage to this calendar month's running total.
    /// Safe to call with all-zero counts (e.g. if a stream never reported
    /// usage) — a no-op in that case. This overload is chat-only (used by
    /// `ClaudeService`'s streaming/one-shot chat paths, always Sonnet 5).
    static func record(inputTokens: Int, outputTokens: Int, cacheCreationTokens: Int, cacheReadTokens: Int) {
        record(inputTokens: inputTokens, outputTokens: outputTokens, cacheCreationTokens: cacheCreationTokens, cacheReadTokens: cacheReadTokens, model: .sonnet5, purpose: .chat)
    }

    /// Model-aware variant — used by generation calls that may run on
    /// Haiku 4.5 rather than the chat path's fixed Sonnet 5, so bulk quiz
    /// generation doesn't get priced at Sonnet rates in the running estimate.
    /// `batch` applies Anthropic's real -50% Batch API discount — omitting it
    /// (as the batch results path used to) overstates real batched spend 2x
    /// on its own, and 4x combined with defaulting to Sonnet's rate instead
    /// of the actual model that ran.
    ///
    /// `purpose` is explicit, not inferred from `model` — generation legitimately
    /// runs on Sonnet 5 too (`.thorough` question quality, and every exam-style
    /// chapter regardless of quality setting), so "model == .sonnet5 means chat"
    /// was a real bug: the most expensive generation calls were being booked as
    /// chat, leaving BudgetGuard's generation-only check blind to them.
    static func record(inputTokens: Int, outputTokens: Int, cacheCreationTokens: Int, cacheReadTokens: Int, model: CobuxModel, batch: Bool = false, purpose: SpendPurpose) {
        let cost = estimatedCost(inputTokens: inputTokens, outputTokens: outputTokens, cacheCreationTokens: cacheCreationTokens, cacheReadTokens: cacheReadTokens, model: model, batch: batch)
        guard cost > 0 else { return }

        let key = monthKey()
        let current = defaults.double(forKey: key)
        defaults.set(current + cost, forKey: key)

        recordByPurpose(purpose, cost: cost)
    }

    /// This calendar month's running estimated spend, in US dollars.
    static func currentMonthEstimate() -> Double {
        defaults.double(forKey: monthKey())
    }

    /// Defaults to Sonnet 5 — the model the main chat path
    /// (`ClaudeService`) actually uses. Callers pricing a different model
    /// (e.g. Haiku-tiered bulk quiz generation) pass `model` explicitly.
    static func estimatedCost(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        model: CobuxModel = .sonnet5,
        batch: Bool = false
    ) -> Double {
        RateTable.estimatedCost(
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            batch: batch
        )
    }

    // MARK: - Per-purpose split

    /// Chat (the recurring, per-turn Sonnet 5 cost) and quiz generation (hash-gated,
    /// effectively one-time per chapter, whichever model ran) are different cost shapes
    /// with different causes — merging them into one number hid a real accounting bug
    /// (generation's BudgetGuard was checking the combined total, so a normal chat month
    /// could exhaust "the generation budget" before any generation happened). Settings
    /// shows both lines now instead of one merged figure.
    enum SpendPurpose: String {
        case chat
        case generation
    }

    private static func purposeKey(_ purpose: SpendPurpose, for date: Date = .now) -> String {
        monthKey(for: date) + "." + purpose.rawValue
    }

    private static func recordByPurpose(_ purpose: SpendPurpose, cost: Double) {
        let key = purposeKey(purpose)
        let current = defaults.double(forKey: key)
        defaults.set(current + cost, forKey: key)
    }

    /// This calendar month's running estimated spend for one purpose only.
    static func currentMonthEstimate(for purpose: SpendPurpose) -> Double {
        defaults.double(forKey: purposeKey(purpose))
    }
}
