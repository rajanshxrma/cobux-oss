import WidgetKit
import SwiftData
import Foundation

struct HighlightEntry: TimelineEntry {
    let date: Date
    let quote: String
    let bookTitle: String
    let author: String
    let chapter: String?
    let coverColorHex: String
    let isPlaceholder: Bool
}

struct HighlightProvider: TimelineProvider {
    private static let refreshInterval: TimeInterval = 2 * 60 * 60
    private static let entriesPerTimeline = 8

    func placeholder(in context: Context) -> HighlightEntry {
        HighlightEntry(
            date: .now,
            quote: "To stand up straight with your shoulders back is to accept the terrible responsibility of life, with eyes wide open.",
            bookTitle: "12 Rules for Life",
            author: "Jordan B. Peterson",
            chapter: "Rule 1",
            coverColorHex: "#D97706",
            isPlaceholder: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (HighlightEntry) -> Void) {
        completion(fetchEntries(count: 1).first ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HighlightEntry>) -> Void) {
        let entries = fetchEntries(count: Self.entriesPerTimeline)
        let timeline = Timeline(
            entries: entries.isEmpty ? [placeholder(in: context)] : entries,
            policy: .after(Date().addingTimeInterval(Self.refreshInterval * Double(Self.entriesPerTimeline)))
        )
        completion(timeline)
    }

    private func fetchEntries(count: Int) -> [HighlightEntry] {
        guard let container = try? ModelContainer(
            for: Book.self, Highlight.self, Chapter.self, ChatMessage.self, Theme.self,
            configurations: ModelConfiguration(groupContainer: .identifier("group.com.rajansharma.Cobux"))
        ) else { return [] }

        let context = ModelContext(container)
        let reminderDescriptor = FetchDescriptor<Highlight>(predicate: #Predicate { $0.isReminder == true })
        var pool = (try? context.fetch(reminderDescriptor)) ?? []
        if pool.isEmpty {
            pool = (try? context.fetch(FetchDescriptor<Highlight>())) ?? []
        }
        guard !pool.isEmpty else { return [] }

        let now = Date()
        return (0..<count).compactMap { index -> HighlightEntry? in
            guard let highlight = pool.randomElement(), let book = highlight.book else { return nil }
            return HighlightEntry(
                date: now.addingTimeInterval(Self.refreshInterval * Double(index)),
                quote: highlight.text,
                bookTitle: book.title,
                author: book.author,
                chapter: highlight.chapter,
                coverColorHex: book.coverColorHex,
                isPlaceholder: false
            )
        }
    }
}
