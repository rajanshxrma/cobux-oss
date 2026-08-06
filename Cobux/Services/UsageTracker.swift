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
    /// usage) — a no-op in that case.
    static func record(inputTokens: Int, outputTokens: Int, cacheCreationTokens: Int, cacheReadTokens: Int) {
        record(inputTokens: inputTokens, outputTokens: outputTokens, cacheCreationTokens: cacheCreationTokens, cacheReadTokens: cacheReadTokens, model: .sonnet5)
    }

    /// Model-aware variant — used by generation calls that may run on
    /// Haiku 4.5 rather than the chat path's fixed Sonnet 5, so bulk quiz
    /// generation doesn't get priced at Sonnet rates in the running estimate.
    static func record(inputTokens: Int, outputTokens: Int, cacheCreationTokens: Int, cacheReadTokens: Int, model: CobuxModel) {
        let cost = estimatedCost(inputTokens: inputTokens, outputTokens: outputTokens, cacheCreationTokens: cacheCreationTokens, cacheReadTokens: cacheReadTokens, model: model)
        guard cost > 0 else { return }

        let key = monthKey()
        let current = defaults.double(forKey: key)
        defaults.set(current + cost, forKey: key)
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
        model: CobuxModel = .sonnet5
    ) -> Double {
        RateTable.estimatedCost(
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )
    }
}
