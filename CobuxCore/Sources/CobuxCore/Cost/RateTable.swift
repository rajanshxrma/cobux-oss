import Foundation

/// Anthropic per-model pricing, effective-dated so a rate change is a data update, not a
/// code change someone has to remember. Replaces `UsageTracker.swift`'s old hardcoded
/// `$2/$10` constants, which were introductory rates that expire 2026-08-31 (a ~50%
/// jump to $3/$15 landing right as Utkarsh starts real daily use).
public struct ModelRates: Sendable, Equatable {
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    /// Anthropic prompt-cache multipliers, applied on top of the input rate.
    public let cacheWriteMultiplier: Double
    public let cacheReadMultiplier: Double

    public init(inputPerMillion: Double, outputPerMillion: Double, cacheWriteMultiplier: Double = 1.25, cacheReadMultiplier: Double = 0.1) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheWriteMultiplier = cacheWriteMultiplier
        self.cacheReadMultiplier = cacheReadMultiplier
    }
}

public struct RateEntry: Sendable {
    public let effectiveFrom: Date
    public let rates: ModelRates
    public init(effectiveFrom: Date, rates: ModelRates) {
        self.effectiveFrom = effectiveFrom
        self.rates = rates
    }
}

public enum CobuxModel: String, Sendable {
    case sonnet5 = "claude-sonnet-5"
    case haiku45 = "claude-haiku-4-5"
}

public enum RateTable {

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    /// Effective-dated rate history per model. Add a new entry rather than editing an
    /// old one — `currentRates(for:on:)` always uses the latest entry that has already
    /// taken effect, so historical spend estimates stay accurate.
    static let history: [CobuxModel: [RateEntry]] = [
        .sonnet5: [
            RateEntry(effectiveFrom: iso.date(from: "2026-01-01")!,
                      rates: ModelRates(inputPerMillion: 2.0, outputPerMillion: 10.0)),
            RateEntry(effectiveFrom: iso.date(from: "2026-08-31")!,
                      rates: ModelRates(inputPerMillion: 3.0, outputPerMillion: 15.0))
        ],
        .haiku45: [
            RateEntry(effectiveFrom: iso.date(from: "2026-01-01")!,
                      rates: ModelRates(inputPerMillion: 1.0, outputPerMillion: 5.0))
        ]
    ]

    public static func currentRates(for model: CobuxModel, on date: Date = .now) -> ModelRates {
        let entries = history[model] ?? []
        let applicable = entries.filter { $0.effectiveFrom <= date }
        return (applicable.max { $0.effectiveFrom < $1.effectiveFrom })?.rates
            ?? entries.first?.rates
            ?? ModelRates(inputPerMillion: 0, outputPerMillion: 0)
    }

    /// Anthropic's Batch API discount — half price on both input and output, applied
    /// uniformly since Anthropic doesn't publish a separate cache-write/cache-read batch
    /// rate. Previously unmodeled entirely: every batch call was priced as if it ran at
    /// full live-call rates, overstating real batched spend by 2x on its own, compounding
    /// with the wrong-model bug (batch results recorded at Sonnet rates regardless of which
    /// model actually ran) to roughly 4x the real cost of batched Haiku generation.
    public static let batchDiscountMultiplier: Double = 0.5

    public static func estimatedCost(
        model: CobuxModel,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        batch: Bool = false,
        on date: Date = .now
    ) -> Double {
        let r = currentRates(for: model, on: date)
        let discount = batch ? batchDiscountMultiplier : 1.0
        let input = Double(inputTokens) / 1_000_000 * r.inputPerMillion * discount
        let output = Double(outputTokens) / 1_000_000 * r.outputPerMillion * discount
        let cacheWrite = Double(cacheCreationTokens) / 1_000_000 * r.inputPerMillion * r.cacheWriteMultiplier * discount
        let cacheRead = Double(cacheReadTokens) / 1_000_000 * r.inputPerMillion * r.cacheReadMultiplier * discount
        return input + output + cacheWrite + cacheRead
    }

    /// The date the next known rate change takes effect for a model, if any is on file.
    /// Used by the self-failing staleness test: this must never be more than ~30 days in
    /// the past relative to "today" in production, or a rate change already happened
    /// without a new entry being added.
    public static func nextKnownChangeDate(for model: CobuxModel, after date: Date = .now) -> Date? {
        (history[model] ?? [])
            .map(\.effectiveFrom)
            .filter { $0 > date }
            .min()
    }
}
