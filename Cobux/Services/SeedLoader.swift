import Foundation
import SwiftData

/// One book's seed content, authored as JSON rather than a Swift literal.
/// `SeedDataRobbins`/`SeedDataMicrobiology` stay as hand-written Swift (they
/// already work, and at ~1.6MB/~1.2MB of nested array literals they're
/// exactly the files a JSON-based approach exists to avoid repeating —
/// adding many more books at that density as Swift literals risks real
/// compiler type-checker slowdowns). Every other book goes through this path.
struct SeedBookDocument: Codable {
    let title: String
    let author: String
    let coverColorHex: String
    let coverImageURL: String?
    /// Maps to `BookContentProfile.rawValue`; unknown/missing values fall
    /// back to `.propositional` rather than failing the whole book.
    let contentProfile: String
    /// Compared against `Book.seedContentVersion` — a book already seeded at
    /// this version or newer is left untouched. Bump this whenever a book's
    /// JSON is revised so the update actually reaches devices that already
    /// seeded an older cut, instead of silently no-op-ing (the bug
    /// `Book.seedContentVersion` exists to fix — see its doc comment).
    let contentVersion: Int
    let chapters: [SeedChapterDocument]
    let highlights: [SeedHighlightDocument]
}

struct SeedChapterDocument: Codable {
    let title: String
    let summary: String
    let keyLessons: [String]
    let chapterNumber: Int?
}

struct SeedHighlightDocument: Codable {
    let text: String
    let chapter: String?
    let tags: [String]
    let isReminder: Bool
}

enum SeedLoader {
    /// Loads every `.json` file bundled under `Resources/SeedBooks/` and
    /// upserts each into the store. Safe to call on every launch:
    /// - A book that doesn't exist yet is inserted fresh.
    /// - A book that exists but is behind `contentVersion` gets its chapters
    ///   updated in place (matched by title, never deleted) and any new
    ///   highlights appended (deduped by exact text match) — this is the
    ///   actual fix for the seed-no-op bug; adding `Book.seedContentVersion`
    ///   alone didn't do anything until something consumed it.
    /// - A book already at or past `contentVersion` is left untouched.
    static func seedAllBundledBooks(modelContext: ModelContext) {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "SeedBooks") else {
            #if DEBUG
            print("SeedLoader: no bundled SeedBooks/*.json found")
            #endif
            return
        }
        let decoder = JSONDecoder()

        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let data = try Data(contentsOf: url)
                let doc = try decoder.decode(SeedBookDocument.self, from: data)
                upsert(doc, modelContext: modelContext)
            } catch {
                #if DEBUG
                print("SeedLoader: failed to load \(url.lastPathComponent): \(error)")
                #endif
            }
        }
    }

    private static func upsert(_ doc: SeedBookDocument, modelContext: ModelContext) {
        let title = doc.title
        let fetchDescriptor = FetchDescriptor<Book>(predicate: #Predicate<Book> { $0.title == title })
        let existingBook = (try? modelContext.fetch(fetchDescriptor))?.first

        let book: Book
        if let existingBook {
            guard existingBook.seedContentVersion < doc.contentVersion else { return }
            book = existingBook
            book.contentProfile = BookContentProfile(rawValue: doc.contentProfile) ?? .propositional
            if book.coverImageURL == nil {
                book.coverImageURL = doc.coverImageURL
            }
        } else {
            book = Book(
                title: doc.title,
                author: doc.author,
                coverColorHex: doc.coverColorHex,
                coverImageURL: doc.coverImageURL,
                contentProfile: BookContentProfile(rawValue: doc.contentProfile) ?? .propositional
            )
            modelContext.insert(book)
        }

        var chaptersByTitle = Dictionary(book.chapters.map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })
        for chapterDoc in doc.chapters {
            if let existingChapter = chaptersByTitle[chapterDoc.title] {
                existingChapter.summary = chapterDoc.summary
                existingChapter.keyLessons = chapterDoc.keyLessons
                if existingChapter.chapterNumber == nil {
                    existingChapter.chapterNumber = chapterDoc.chapterNumber
                }
            } else {
                let newChapter = Chapter(
                    title: chapterDoc.title,
                    summary: chapterDoc.summary,
                    keyLessons: chapterDoc.keyLessons,
                    chapterNumber: chapterDoc.chapterNumber
                )
                newChapter.book = book
                book.chapters.append(newChapter)
                chaptersByTitle[chapterDoc.title] = newChapter
            }
        }

        let existingTexts = Set(book.highlights.map(\.text))
        for highlightDoc in doc.highlights where !existingTexts.contains(highlightDoc.text) {
            let highlight = Highlight(
                text: highlightDoc.text,
                chapter: highlightDoc.chapter,
                tags: highlightDoc.tags,
                isReminder: highlightDoc.isReminder
            )
            highlight.book = book
            book.highlights.append(highlight)
        }

        book.seedContentVersion = doc.contentVersion
    }
}
