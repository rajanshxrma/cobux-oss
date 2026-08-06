import CoreSpotlight
import Foundation

/// Indexes highlights into the system-wide Spotlight search index (Core
/// Spotlight), so users can find their book highlights from iOS search without
/// opening Cobux.
struct SpotlightIndexer {
    static let domainIdentifier = "com.rajansharma.Cobux.highlight"

    static func index(_ highlight: Highlight) {
        CSSearchableIndex.default().indexSearchableItems([makeItem(for: highlight)], completionHandler: nil)
    }

    static func deindex(_ highlight: Highlight) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [highlight.id.uuidString], completionHandler: nil)
    }

    /// Batch re-index: clears every item under `domainIdentifier`, then indexes
    /// all provided highlights in a single `indexSearchableItems` call.
    static func reindexAll(_ highlights: [Highlight]) {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { _ in
            let items = highlights.map(makeItem(for:))
            CSSearchableIndex.default().indexSearchableItems(items, completionHandler: nil)
        }
    }

    private static func makeItem(for highlight: Highlight) -> CSSearchableItem {
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
