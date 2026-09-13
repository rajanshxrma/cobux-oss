import CoreSpotlight
import Foundation

/// Indexes highlights into the system-wide Spotlight search index (Core
/// Spotlight), so users can find their book highlights from iOS search without
/// opening Cobux.
struct SpotlightIndexer {
    static let domainIdentifier = "com.rajansharma.Cobux.highlight"

    /// False on devices where Core Spotlight is not indexing at all. Checked
    /// before any awaited call: a completion handler that never arrives would
    /// otherwise park `SeedRunner`'s background chain for the life of the
    /// process.
    static var isAvailable: Bool { CSSearchableIndex.isIndexingAvailable() }

    static func index(_ highlight: Highlight) {
        CSSearchableIndex.default().indexSearchableItems([makeItem(for: highlight)], completionHandler: nil)
    }

    static func deindex(_ highlight: Highlight) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [highlight.id.uuidString], completionHandler: nil)
    }

    // MARK: - Paged rebuild

    /// The awaitable pair `SeedRunner.rebuildSpotlightIndex` drives: remove
    /// the whole domain, then hand over one PAGE of highlights at a time as
    /// the caller fetches them. This replaced a `reindexAll(_ highlights:)`
    /// that took the entire table as one array -- against the real library,
    /// 32,125 highlights across 156 seed books
    /// (`scripts/check-corpus-scale.py`, build 52), that meant 32,125 model
    /// objects (each faulting `book`) resident at once and as many
    /// `CSSearchableItem`s built in one go, on EVERY launch. Paging
    /// keeps the working set at one page, and awaiting Spotlight's completion
    /// per page is what actually paces the work -- the system is never
    /// handed more than it has finished writing. (A fresh install indexing
    /// those 32,125 highlights in one uninterruptible burst was part of
    /// why Amal's first launch was laggy.)
    ///
    /// Model-thread rule, unchanged from the old implementation: items are
    /// built BEFORE the hop into Spotlight's completion handler. That closure
    /// runs on Spotlight's own callback queue, and touching SwiftData models
    /// (`highlight.text`, `.book?.title`) off the thread of the context that
    /// fetched them is undefined behavior that can intermittently
    /// EXC_BAD_ACCESS. `CSSearchableItem`s are plain values and cross threads
    /// fine.
    ///
    /// Which is why `indexBatch` takes finished `CSSearchableItem`s and NOT
    /// `[Highlight]`. It briefly took the rows, and that quietly broke the
    /// rule from the other side: a nonisolated `async` function does not run
    /// on its caller's executor under this project's Swift 5.9 language mode
    /// (SE-0338), so `makeItem`'s reads of `book?.title`, `.text`, `.chapter`,
    /// `.tags` happened on the generic executor while the `@ModelActor`
    /// context that fetched them sat suspended one frame up. Serial exposure
    /// is why it never trapped here -- the same reason Build 5 looked fine
    /// until it didn't. Building the items on the actor, as
    /// `SeedRunner.rebuildSpotlightIndex` now does, is the fix that cannot
    /// regress by language-mode accident: the boundary is in the type.

    /// Removes every item under `domainIdentifier`, returning once Spotlight
    /// confirms. Errors are Spotlight's to report; a failed delete only means
    /// stale items linger until the next rebuild.
    static func removeAll() async {
        guard isAvailable else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { _ in
                continuation.resume()
            }
        }
    }

    /// Indexes one page of already-built items, returning once Spotlight
    /// confirms. Takes values, not rows, so no `@Model` property is ever read
    /// on this function's executor -- the caller builds the items while it is
    /// still isolated to the actor that owns them (`makeItem(for:)`).
    static func indexBatch(items: [CSSearchableItem]) async {
        guard isAvailable, !items.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            CSSearchableIndex.default().indexSearchableItems(items) { _ in
                continuation.resume()
            }
        }
    }

    /// Internal, not private: `SeedRunner.rebuildSpotlightIndex` calls it
    /// directly so the model reads below happen on its `@ModelActor`. Call it
    /// only from the executor that owns the row.
    static func makeItem(for highlight: Highlight) -> CSSearchableItem {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .text)
        attributeSet.title = highlight.book?.title ?? String(highlight.text.prefix(60))

        var description = highlight.text
        if let chapter = highlight.chapter, !chapter.isEmpty {
            description += " — \(chapter)"
        }
        attributeSet.contentDescription = description
        attributeSet.keywords = highlight.tags

        return CSSearchableItem(
            uniqueIdentifier: highlight.id.uuidString,
            domainIdentifier: domainIdentifier,
            attributeSet: attributeSet
        )
    }
}
