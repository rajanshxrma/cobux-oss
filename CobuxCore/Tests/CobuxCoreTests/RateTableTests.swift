import XCTest
@testable import CobuxCore

final class RateTableTests: XCTestCase {

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    func testSonnetUsesIntroductoryRateBeforeAugust31() {
        let beforeCutover = iso.date(from: "2026-08-01")!
        let rates = RateTable.currentRates(for: .sonnet5, on: beforeCutover)
        XCTAssertEqual(rates.inputPerMillion, 2.0)
        XCTAssertEqual(rates.outputPerMillion, 10.0)
    }

    func testSonnetUsesStandardRateOnAndAfterAugust31() {
        let onCutover = iso.date(from: "2026-08-31")!
        let rates = RateTable.currentRates(for: .sonnet5, on: onCutover)
        XCTAssertEqual(rates.inputPerMillion, 3.0)
        XCTAssertEqual(rates.outputPerMillion, 15.0)
    }

    func testEstimatedCostAppliesCacheMultipliers() {
        // 1M cache-write tokens at $2/M input * 1.25 write multiplier = $2.50
        let cost = RateTable.estimatedCost(
            model: .sonnet5, inputTokens: 0, outputTokens: 0,
            cacheCreationTokens: 1_000_000, cacheReadTokens: 0,
            on: iso.date(from: "2026-08-01")!
        )
        XCTAssertEqual(cost, 2.5, accuracy: 0.001)
    }

    func testHaikuBatchedBothTextbooksIsUnderFiftyCents() {
        // Ground-truth measured estimate from the architecture pass: ~227k input / ~127k
        // output tokens for both textbooks' full question banks, Haiku + Batch API (-50%).
        let batched = RateTable.estimatedCost(model: .haiku45, inputTokens: 227_000, outputTokens: 127_000, batch: true)
        XCTAssertLessThan(batched, 0.50, "bulk generation for both entire textbooks must stay a fraction of the $5 monthly cap")
    }

    func testBatchDiscountAppliesToInputOutputAndCache() {
        let live = RateTable.estimatedCost(model: .haiku45, inputTokens: 1_000_000, outputTokens: 1_000_000, cacheCreationTokens: 1_000_000, cacheReadTokens: 1_000_000)
        let batched = RateTable.estimatedCost(model: .haiku45, inputTokens: 1_000_000, outputTokens: 1_000_000, cacheCreationTokens: 1_000_000, cacheReadTokens: 1_000_000, batch: true)
        XCTAssertEqual(batched, live * 0.5, accuracy: 0.0001, "the batch discount must apply uniformly, not just to the base input/output rate")
    }

    /// Self-failing staleness guard. An entry being long *in effect* is not staleness —
    /// the introductory Sonnet rate is legitimately active for months, that's expected.
    /// The real risk is the table having gone quiet: nobody has added a newer entry in a
    /// long time even though `.now` has drifted well past the *most recent* dated entry
    /// (future or past). That's the actual class of landmine `UsageTracker.swift`'s old
    /// hardcoded constants were — a rate change happens and nobody notices for months.
    func testPricingConstantsAreCurrent() {
        for model in [CobuxModel.sonnet5, .haiku45] {
            let entries = RateTable.history[model] ?? []
            guard let mostRecentKnownDate = entries.map(\.effectiveFrom).max() else {
                XCTFail("\(model.rawValue) has no rate entries at all")
                continue
            }
            let daysSinceMostRecentEntryWasAdded = Calendar.current.dateComponents(
                [.day], from: mostRecentKnownDate, to: .now
            ).day ?? 0
            // If the most recent known date is still in the future (a scheduled change
            // we already know about), there's nothing stale. Only flag once wall-clock
            // time has moved more than ~400 days past the last entry anyone bothered to add.
            XCTAssertLessThan(
                daysSinceMostRecentEntryWasAdded, 400,
                "\(model.rawValue)'s most recent RateEntry is dated \(daysSinceMostRecentEntryWasAdded) days in the past — check whether Anthropic has announced a newer price and add a RateEntry if so"
            )
        }
    }
}
