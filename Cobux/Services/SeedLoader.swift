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
    /// The bundled `Cover-<slug>` imageset name for this book -- see
    /// `Book.coverAssetName`'s doc comment. Optional only so a JSON file that
    /// predates this field still decodes; every current seed book sets it.
    let coverAssetName: String?
    /// Groups this book in the chat thread picker's category sections.
    /// Optional so a JSON file that predates this field decodes fine and the
    /// book simply lands in the picker's "Other" bucket.
    let category: String?
    /// Maps to `BookContentProfile.rawValue`; unknown/missing values fall
    /// back to `.propositional` rather than failing the whole book.
    let contentProfile: String
    /// What game this book's counsel plays. Optional so every seed file written
    /// before traditions existed still decodes.
    let tradition: String?
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
            // Nil-only backfills run BEFORE the version guard: a device that
            // seeded a book before these fields existed must still pick them
            // up even when the book's contentVersion never changes. Keeping
            // them behind the guard is exactly the bug that left every
            // pre-category install showing "Medical Reference" + "Other" as
            // the only picker sections.
            if existingBook.coverImageURL == nil {
                existingBook.coverImageURL = doc.coverImageURL
            }
            // Same nil-only backfill, same reasoning -- a device that seeded
            // this book before `coverAssetName` existed must still pick up
            // the bundled cover on the very next launch, not stay on
            // whatever the old `coverImageURL` fetch happened to render.
            if existingBook.coverAssetName == nil {
                existingBook.coverAssetName = doc.coverAssetName
            }
            if existingBook.category == nil {
                existingBook.category = doc.category
            }
            guard existingBook.seedContentVersion < doc.contentVersion else { return }
            book = existingBook
            book.contentProfile = BookContentProfile(rawValue: doc.contentProfile) ?? .propositional
            book.tradition = doc.tradition.flatMap(BookTradition.init(rawValue:))
        } else {
            book = Book(
                title: doc.title,
                author: doc.author,
                coverColorHex: doc.coverColorHex,
                coverImageURL: doc.coverImageURL,
                coverAssetName: doc.coverAssetName,
                category: doc.category,
                contentProfile: BookContentProfile(rawValue: doc.contentProfile) ?? .propositional
            )
            book.tradition = doc.tradition.flatMap(BookTradition.init(rawValue:))
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

        // `var`, updated inside the loop -- when a `contentVersion` bump's own
        // JSON has two highlights sharing exact text (a duplicate that slips
        // past content authoring, e.g. the same quote pasted into two
        // chapters), a `let` snapshot taken before the loop only ever reflects
        // what was already in the store, so both copies pass the "not
        // existing yet" check and both get inserted -- a visible duplicate
        // quote in the library. Inserting into this set as each highlight is
        // added keeps later duplicates in the same document from re-passing
        // the check.
        var existingTexts = Set(book.highlights.map(\.text))
        for highlightDoc in doc.highlights where !existingTexts.contains(highlightDoc.text) {
            let highlight = Highlight(
                text: highlightDoc.text,
                chapter: highlightDoc.chapter,
                tags: highlightDoc.tags,
                isReminder: highlightDoc.isReminder
            )
            highlight.book = book
            book.highlights.append(highlight)
            existingTexts.insert(highlightDoc.text)
        }

        book.seedContentVersion = doc.contentVersion
    }
}
