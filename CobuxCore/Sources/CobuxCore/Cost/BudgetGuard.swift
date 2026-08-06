import Foundation

/// A hard client-side spending cap for paid generation calls (quiz question
/// generation, cloze fallback, etc.) — distinct from `UsageTracker`'s
/// running estimate, which is purely observational. `UsageTracker` tells
/// Rajan how much has been spent; `BudgetGuard` is the thing that actually
/// refuses to spend more once a configured ceiling is hit, so a monthly-capped
/// key (Utkarsh's ~$5/month) can't be exhausted by one runaway generation
/// pass before anyone notices the estimate climbing.
///
/// Pure value type — no UserDefaults, no network. Callers own where the
/// "already spent" figure comes from (`UsageTracker.currentMonthEstimate()`
/// in practice) and where the cap is configured (a Settings-exposed value,
/// default `$3.50` — comfortably under the ~$5 real cap so the guard trips
/// before the actual account-level enforcement would, leaving headroom for
/// the interactive chat path Rajan and Utkarsh use every day).
public struct BudgetGuard: Sendable, Equatable {
    public let capDollars: Double

    public init(capDollars: Double = BudgetGuard.defaultCapDollars) {
        self.capDollars = capDollars
    }

    /// The recommended default — intentionally below Utkarsh's real ~$5/month
    /// key cap so generation stops itself with room left for everyday chat.
    public static let defaultCapDollars: Double = 3.50

    public struct Decision: Sendable, Equatable {
        public let allowed: Bool
        public let remainingDollars: Double
        /// Present only when `allowed` is false — a short, user-facing reason.
        public let blockReason: String?
    }

    /// - Parameters:
    ///   - alreadySpentDollars: this period's running spend so far (e.g. `UsageTracker.currentMonthEstimate()`).
    ///   - proposedCostDollars: the estimated cost of the generation call about to be made.
    public func evaluate(alreadySpentDollars: Double, proposedCostDollars: Double) -> Decision {
        let remaining = max(0, capDollars - alreadySpentDollars)
        guard alreadySpentDollars + proposedCostDollars <= capDollars else {
            let reason = "This would bring estimated spend to $\(String(format: "%.2f", alreadySpentDollars + proposedCostDollars)), over the $\(String(format: "%.2f", capDollars)) generation budget. Raise the budget in Settings or wait for next month's reset."
            return Decision(allowed: false, remainingDollars: remaining, blockReason: reason)
        }
        return Decision(allowed: true, remainingDollars: remaining - proposedCostDollars, blockReason: nil)
    }
}
