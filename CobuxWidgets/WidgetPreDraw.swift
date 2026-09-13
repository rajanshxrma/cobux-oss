import Foundation
import SwiftData

/// Keeps a lane's pre-drawn cards topped up to
/// `WidgetHighlightHistory.nextCardDepth`, so a cycle tap is always served
/// from a card and never from the store.
///
/// Two entry points, one rule between them:
///
/// - `fill(...)`, synchronous, with a context the caller already opened. The
///   provider's store path calls it while it has the store open, so every
///   store build leaves the lane full and the next tap is fast no matter what
///   happens to the refill below. Bounded: it draws only the shortfall, and a
///   lane that is already full costs it nothing.
/// - `scheduleRefill(...)`, off the critical path. After a card-served build
///   the provider has already decided its entry and must return it before
///   anything else, so the top-up runs in a detached task that outlives
///   `timeline(for:)`. WidgetKit keeps the extension resident to render the
///   entry it was just handed, which is more than the refill needs; if the
///   process is torn down first, nothing is lost -- the writes are one
///   defaults key, set atomically, and the second card already in hand serves
///   the next tap while the build after that fills again. Refills are
///   serialized through one actor so the widget process never holds two
///   containers open for this purpose at once, whatever the home screen does.
///
/// Why not in `perform()` after `reloadTimelines`: WidgetKit reloads an
/// interactive widget's timeline when `perform()` RETURNS, so store work
/// there sits squarely on the tap's critical path -- the exact wait this
/// removes.
enum WidgetPreDraw {
    /// Draws until the lane holds `depth` cards (never more than
    /// `nextCardDepth`), skipping what is already there. Cards equal to
    /// `currentID` or no longer showable are dropped first, so a lane that
    /// stepped Back onto a queued card does not keep it queued.
    static func fill(
        scope: String?,
        bookID: UUID?,
        currentID: UUID?,
        maxLength: Int?,
        in context: ModelContext,
        upTo depth: Int
    ) {
        let wanted = min(depth, WidgetHighlightHistory.nextCardDepth)
        var cards = WidgetHighlightHistory.nextCards(scope: scope)
            .filter { $0.highlightID != currentID && $0.isShowableWithoutStore }
        var draws = 0
        // One spare draw beyond the shortfall: the pool's exclusion is a
        // preference, so a draw can land on a card already queued.
        while cards.count < wanted, draws <= wanted {
            draws += 1
            let exclude = cards.last?.highlightID ?? currentID
            guard let picked = WidgetHighlightPool.randomHighlight(
                in: context, bookID: bookID, excluding: exclude, maxLength: maxLength
            ), let book = picked.book else { break }
            guard picked.id != currentID,
                  !cards.contains(where: { $0.highlightID == picked.id }) else { continue }
            cards.append(WidgetHighlightCard(highlight: picked, book: book))
        }
        WidgetHighlightHistory.storeNext(cards, scope: scope)
    }

    /// Tops the lane up to `nextCardDepth` without blocking the caller. Costs
    /// nothing when the lane is already full: that is checked from defaults
    /// before any task or container exists.
    static func scheduleRefill(scope: String?, bookID: UUID?, currentID: UUID?, maxLength: Int?) {
        guard needsRefill(scope: scope, currentID: currentID) else { return }
        Task.detached(priority: .utility) {
            await RefillLane.shared.run {
                // Re-checked inside the lane: an earlier refill may have
                // filled it while this one waited its turn.
                guard needsRefill(scope: scope, currentID: currentID),
                      let container = CobuxSchema.makeAppGroupContainer() else { return }
                let context = ModelContext(container)
                fill(scope: scope, bookID: bookID, currentID: currentID,
                     maxLength: maxLength, in: context,
                     upTo: WidgetHighlightHistory.nextCardDepth)
            }
        }
    }

    private static func needsRefill(scope: String?, currentID: UUID?) -> Bool {
        let usable = WidgetHighlightHistory.nextCards(scope: scope)
            .filter { $0.highlightID != currentID && $0.isShowableWithoutStore }
        return usable.count < WidgetHighlightHistory.nextCardDepth
    }
}

/// One refill at a time, process-wide. A synchronous actor method runs its
/// body to completion before the next caller gets in, which is exactly the
/// serialization wanted here -- and the reason the body is kept small.
private actor RefillLane {
    static let shared = RefillLane()

    func run(_ work: @Sendable () -> Void) {
        work()
    }
}
