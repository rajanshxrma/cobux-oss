import Foundation

@Observable
final class GoodreadsSyncService {
    private static let goodreadsUserID = "143546502"
    private static let cacheFileName = "goodreads_cache.json"
    private static let lastSyncedKey = "goodreadsLastSynced"
    private static let staleAfter: TimeInterval = 6 * 60 * 60 // 6 hours

    var books: [GoodreadsBook] = []
    var isSyncing = false
    var lastSyncedDate: Date? {
        get { UserDefaults.standard.object(forKey: Self.lastSyncedKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastSyncedKey) }
    }
    var syncError: String?

    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.cacheFileName)
    }

    func loadCacheIfNeeded() {
        guard books.isEmpty, let data = try? Data(contentsOf: cacheURL) else { return }
        if let decoded = try? JSONDecoder().decode([GoodreadsBook].self, from: data) {
            books = decoded
        }
    }

    var isStale: Bool {
        guard let lastSyncedDate else { return true }
        return Date().timeIntervalSince(lastSyncedDate) > Self.staleAfter
    }

    func syncIfStale() async {
        guard isStale, !isSyncing else { return }
        await sync()
    }

    @MainActor
    func sync() async {
        isSyncing = true
        syncError = nil
        defer { isSyncing = false }

        do {
            var merged: [GoodreadsBook] = []
            for shelf in GoodreadsShelf.allCases {
                let shelfBooks = try await fetchShelf(shelf)
                merged.append(contentsOf: shelfBooks)
            }
            books = merged.sorted { $0.dateAdded > $1.dateAdded }
            lastSyncedDate = Date()
            try? JSONEncoder().encode(books).write(to: cacheURL)
        } catch {
            syncError = "Couldn't sync your Goodreads shelf. Check your connection and try again."
        }
    }

    private func fetchShelf(_ shelf: GoodreadsShelf) async throws -> [GoodreadsBook] {
        let urlString = "https://www.goodreads.com/review/list_rss/\(Self.goodreadsUserID)?shelf=\(shelf.rawValue)"
        guard let url = URL(string: urlString) else { return [] }

        let (data, _) = try await URLSession.shared.data(from: url)
        let parser = GoodreadsRSSParser(shelf: shelf)
        return parser.parse(data: data)
    }
}

/// Parses a Goodreads shelf RSS feed (https://www.goodreads.com/review/list_rss/<user_id>?shelf=<shelf>)
/// into GoodreadsBook values. No API key required — Goodreads serves this feed publicly for public profiles.
private final class GoodreadsRSSParser: NSObject, XMLParserDelegate {
    private let shelf: GoodreadsShelf
    private var books: [GoodreadsBook] = []

    private var currentElement = ""
    private var currentText = ""
    private var inItem = false

    private var title = ""
    private var bookID: Int?
    private var author = ""
    private var coverImageURL: String?
    private var averageRating: Double = 0
    private var bookDescription = ""
    private var dateAdded: Date?

    init(shelf: GoodreadsShelf) {
        self.shelf = shelf
    }

    func parse(data: Data) -> [GoodreadsBook] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return books
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
        if elementName == "item" {
            inItem = true
            title = ""
            bookID = nil
            author = ""
            coverImageURL = nil
            averageRating = 0
            bookDescription = ""
            dateAdded = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard inItem else { return }
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "title":
            title = text
        case "book_id":
            bookID = Int(text)
        case "author_name":
            author = text
        case "book_large_image_url":
            coverImageURL = text
        case "average_rating":
            averageRating = Double(text) ?? 0
        case "book_description":
            bookDescription = text
        case "user_date_added":
            dateAdded = Self.parseRFC822(text)
        case "item":
            inItem = false
            if let bookID {
                books.append(GoodreadsBook(
                    id: bookID,
                    title: title,
                    author: author,
                    coverImageURL: coverImageURL,
                    averageRating: averageRating,
                    bookDescription: bookDescription,
                    shelf: shelf,
                    dateAdded: dateAdded ?? .now
                ))
            }
        default:
            break
        }
    }

    private static func parseRFC822(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: text)
    }
}
