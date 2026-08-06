import AppIntents
import SwiftData

struct BookEntity: AppEntity {
    let id: UUID
    let title: String
    let author: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Book"
    static var defaultQuery = BookEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(author)")
    }
}

struct BookEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [BookEntity] {
        guard let container = try? ModelContainer(
            for: Book.self, Highlight.self, Chapter.self, ChatMessage.self, Theme.self,
            configurations: ModelConfiguration(groupContainer: .identifier("group.com.rajansharma.Cobux"))
        ) else { return [] }

        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Book>()
        descriptor.fetchLimit = 200
        let allBooks = (try? context.fetch(descriptor)) ?? []
        return allBooks
            .filter { identifiers.contains($0.id) }
            .map { BookEntity(id: $0.id, title: $0.title, author: $0.author) }
    }

    func suggestedEntities() async throws -> [BookEntity] {
        guard let container = try? ModelContainer(
            for: Book.self, Highlight.self, Chapter.self, ChatMessage.self, Theme.self,
            configurations: ModelConfiguration(groupContainer: .identifier("group.com.rajansharma.Cobux"))
        ) else { return [] }

        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Book>()
        // A defensive bound, not a real-world limit — this library realistically has a
        // handful to a few dozen books, but an intent/extension runs under a tight memory
        // ceiling and an unbounded fetch shouldn't be the thing that finds that out.
        descriptor.fetchLimit = 200
        let allBooks = (try? context.fetch(descriptor)) ?? []
        return allBooks.map { BookEntity(id: $0.id, title: $0.title, author: $0.author) }
    }
}
