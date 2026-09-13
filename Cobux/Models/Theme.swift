import SwiftData
import Foundation

@Model
final class Theme {
    var id: UUID = UUID()
    var name: String
    var themeDescription: String
    var relatedThemeNames: [String]
    var dateGenerated: Date

    @Relationship(inverse: \Highlight.themes)
    var highlights: [Highlight] = []

    /// How many highlights carry this theme, written when the graph is
    /// (re)built and repaired by `WisdomProbe` after a highlight deletion.
    ///
    /// WHY THIS EXISTS (build 61). The Wisdom tab's only expensive question
    /// is "how many highlights carry each theme", and `highlights.count` can
    /// only answer it by faulting the relationship -- every row with its
    /// full text and 2 KB vector, ~33,000 rows across the library, on every
    /// first open of the tab. 58 tried to ask the store instead with a
    /// predicate through the tag join and trapped (SwiftData cannot
    /// translate a to-many `contains` with a nested closure; the crash was
    /// on his phone within the hour). 60 put the relationship read on a
    /// probe actor, which stopped it blocking the frame but not from taking
    /// seconds on an older phone. This is the third shape: the number is
    /// STORED on the row at the one moment it is cheap to know -- the graph
    /// build already holds every highlight of every theme in hand -- and
    /// read back as one column. Additive and optional, so SwiftData's
    /// lightweight migration adds it to existing rows as `nil` (the same
    /// shape as `Highlight.isLiked` and `Book.coverImageURL`); a `nil` means
    /// "not written yet" and falls back to the relationship read, which
    /// then writes the value so it is `nil` exactly once per theme.
    var cachedHighlightCount: Int?

    /// The same count broken down by owning book, so the count under a book
    /// filter is arithmetic rather than a query.
    ///
    /// The Robbins and Microbiology seed books are `.academicReference`,
    /// which `BookSourceFilter` switches off by default -- so on EVERY
    /// install the Wisdom grid's numbers are "this theme, minus the
    /// reference texts' share", and a cache that only knew the total would
    /// fall back to the relationship read on the common path. Stored as a
    /// JSON `[uuidString: count]` blob in `Data?` -- the one stored shape in
    /// this schema with a blob precedent (`Highlight.embeddingData`) -- and
    /// read through `cachedBookCounts`. A highlight with no book counts in
    /// the total and under no book, which is `BookSourceFilter.isVisible`'s
    /// own rule (an orphan is never hidden).
    var cachedBookCountsData: Data?

    init(name: String, themeDescription: String = "", relatedThemeNames: [String] = [], dateGenerated: Date = .now) {
        self.id = UUID()
        self.name = name
        self.themeDescription = themeDescription
        self.relatedThemeNames = relatedThemeNames
        self.dateGenerated = dateGenerated
    }

    /// `cachedBookCountsData` decoded, or `nil` when it was never written.
    /// A blob that fails to decode reads as `nil` -- "not written" -- and
    /// the relationship read repairs it, never a trap.
    var cachedBookCounts: [UUID: Int]? {
        get {
            guard let cachedBookCountsData,
                  let raw = try? JSONDecoder().decode([String: Int].self, from: cachedBookCountsData) else { return nil }
            var counts: [UUID: Int] = [:]
            counts.reserveCapacity(raw.count)
            for (key, value) in raw {
                if let id = UUID(uuidString: key) { counts[id] = value }
            }
            return counts
        }
        set {
            guard let newValue else {
                cachedBookCountsData = nil
                return
            }
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.uuidString, $0.value) })
            cachedBookCountsData = try? JSONEncoder().encode(raw)
        }
    }

    /// The count of this theme's highlights that survive a book filter,
    /// from the cached columns alone -- `nil` when they have not been
    /// written for this row yet. Exact, not an estimate: a highlight belongs
    /// to at most one book, so the subtraction cannot double-count.
    func cachedVisibleHighlightCount(excluding excludedBookIDs: Set<UUID>) -> Int? {
        guard let total = cachedHighlightCount else { return nil }
        guard !excludedBookIDs.isEmpty else { return total }
        guard let byBook = cachedBookCounts else { return nil }
        var hidden = 0
        for bookID in excludedBookIDs {
            hidden += byBook[bookID] ?? 0
        }
        return max(0, total - hidden)
    }
}
