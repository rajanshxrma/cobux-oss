import Foundation

struct GoodreadsBook: Codable, Identifiable, Hashable {
    var id: Int // Goodreads book_id
    var title: String
    var author: String
    var coverImageURL: String?
    var averageRating: Double
    var bookDescription: String
    var shelf: GoodreadsShelf
    var dateAdded: Date
}

enum GoodreadsShelf: String, Codable, CaseIterable, Identifiable {
    case currentlyReading = "currently-reading"
    case read = "read"
    case toRead = "to-read"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .currentlyReading: return "Currently Reading"
        case .read: return "Read"
        case .toRead: return "Want to Read"
        }
    }
}
