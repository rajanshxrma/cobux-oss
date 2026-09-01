import SwiftData
import Foundation

/// Imports Rajan's personal-writing export (Apple Notes 
/// "Journal" folders, plus reflective notes from his general Notes) into
/// `PersonalWritingEntry` rows, so chat can draw on them the same way it
/// already draws on book highlights (`SearchService.relevantPersonalWriting`).
///
/// The export file itself is produced OUTSIDE the app (an AppleScript export
/// to JSON) and never touched by this service beyond reading it — see
/// `SettingsView`'s `.fileImporter` call site.
enum PersonalWritingImportService {
    /// Matches the real export file's shape exactly: a flat JSON array of
    /// objects with `source`, `title`, `modifiedDate` (AppleScript's raw
    /// date-to-string output, NOT a fixed ISO format), and `text` (plain
    /// text, HTML already stripped).
    struct ExportedEntry: Codable {
        var source: String
        var title: String
        var modifiedDate: String
        var text: String
    }

    struct ImportResult {
        var imported: Int
        var skippedDuplicates: Int
    }

    /// AppleScript's date-to-string output for a US-locale Mac, e.g.
    /// "Monday, June 15, 2026 at 5:34:00 AM" — except the space before AM/PM
    /// is actually U+202F (NARROW NO-BREAK SPACE), confirmed against every
    /// entry in the real export file, not a plain space. `en_US_POSIX` keeps
    /// weekday/month names and AM/PM markers fixed regardless of the device's
    /// own locale/calendar settings (the standard "parsing a fixed-format
    /// string" formatter recipe), and `nil` is returned — not thrown — the
    /// moment any entry doesn't match, so a format variation in a future
    /// export degrades to "no date for this entry" rather than aborting the
    /// whole import.
    private static let modifiedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm:ss\u{202F}a"
        return formatter
    }()

    /// Best-effort parse, tried with the narrow-no-break-space format first
    /// (the real export's actual shape) and a plain-space fallback second, in
    /// case a differently-produced export ever uses a normal space instead.
    /// Never throws — parse failure is explicitly non-fatal per the task's
    /// own design, so a date this can't parse just imports with
    /// `modifiedDate == nil` rather than being dropped or crashing the import.
    static func parseModifiedDate(_ raw: String) -> Date? {
        if let date = modifiedDateFormatter.date(from: raw) {
            return date
        }
        let normalized = raw.replacingOccurrences(of: "\u{202F}", with: " ")
        let fallbackFormatter = DateFormatter()
        fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
        fallbackFormatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm:ss a"
        return fallbackFormatter.date(from: normalized)
    }

    /// Dedup key mirrors `BackupService`'s own no-stored-UUID convention
    /// (e.g. `(book title, highlight text)` for `HighlightMemoryDTO`): an
    /// entry is a duplicate of one already in the store when its
    /// `(source, title, text)` triple matches exactly, so re-importing the
    /// same export (or an export that grew since last time) never creates
    /// duplicate rows.
    ///
    /// A real `Hashable` struct, not a `"\(a)|||\(b)|||\(c)"` string
    /// concatenation -- a delimiter-joined string key can theoretically
    /// collide when a field's own content happens to contain the delimiter
    /// (e.g. source="A", title="", text="|||B|||C" vs. source="A|||",
    /// title="B", text="C" both joining to the same string). A struct's
    /// `Hashable` conformance hashes each field independently, so this class
    /// of collision can't happen regardless of what the real text contains.
    private struct DedupeKey: Hashable {
        let source: String
        let title: String
        let text: String
    }

    /// Parses `data` as the export JSON, inserts one `PersonalWritingEntry`
    /// per new (non-duplicate) entry, embeds its text on-device via
    /// `EmbeddingService.embed` (free, local, no network/cost — the same call
    /// already used for highlights), and saves periodically so a mid-import
    /// interruption doesn't lose everything already inserted.
    ///
    /// Batches with a `try? context.save()` and `await Task.yield()` every 10
    /// entries, mirroring `CobuxApp.backfillEmbeddingsAndReindex`'s exact
    /// yielding pattern, so importing ~100 entries doesn't freeze the UI
    /// thread the way one long unyielded loop of on-device ML inference
    /// would.
    @discardableResult
    /// - Parameter deferEmbeddings: skip the per-entry embedding pass, leaving
    ///   `embedding` nil for `backfillPersonalWritingEmbeddings` to fill in later.
    ///   Embedding every entry inline is the single slowest part of an import
    ///   (one model call each, hundreds of entries), and it delays the thing the
    ///   user is actually waiting for: seeing today's journal in the app. Nothing
    ///   is lost -- an entry without an embedding is fully readable and editable,
    ///   it just isn't semantically searchable until the backfill runs.
    static func importData(
        _ data: Data,
        modelContext: ModelContext,
        deferEmbeddings: Bool = false
    ) async throws -> ImportResult {
        let decoder = JSONDecoder()
        let decoded = try decoder.decode([ExportedEntry].self, from: data)

        // Newest first. The file arrives in whatever order it was assembled, so
        // a 245-entry import could spend a minute on 2019 before reaching the
        // entry written this morning -- which is the one he opened the app for.
        // Combined with the save-every-10 below, the most recent entries are on
        // screen within the first fraction of the work.
        let entries = decoded.sorted { a, b in
            (parseModifiedDate(a.modifiedDate) ?? .distantPast) > (parseModifiedDate(b.modifiedDate) ?? .distantPast)
        }

        let existing = (try? modelContext.fetch(FetchDescriptor<PersonalWritingEntry>())) ?? []
        var existingKeys = Set(existing.map { DedupeKey(source: $0.source, title: $0.title, text: $0.text) })

        var imported = 0
        var skipped = 0
        var processedSinceSave = 0

        for entry in entries {
            let key = DedupeKey(source: entry.source, title: entry.title, text: entry.text)
            guard !existingKeys.contains(key) else {
                skipped += 1
                continue
            }
            existingKeys.insert(key)

            let modifiedDate = parseModifiedDate(entry.modifiedDate)
            let row = PersonalWritingEntry(source: entry.source, title: entry.title, text: entry.text, modifiedDate: modifiedDate)
            if !deferEmbeddings, let vector = EmbeddingService.embed(entry.text) {
                row.embedding = vector
            }
            modelContext.insert(row)
            imported += 1

            processedSinceSave += 1
            if processedSinceSave >= 10 {
                try? modelContext.save()
                await Task.yield()
                processedSinceSave = 0
            }
        }

        try modelContext.save()

        return ImportResult(imported: imported, skippedDuplicates: skipped)
    }

    /// This content is genuinely personal (health, relationships, family,
    /// financial stress -- real examples from the actual export). Turning
    /// off `personalWritingContextEnabled` only stops it from being used in
    /// future chat turns -- it doesn't remove anything already imported,
    /// still included in every future "Export Backup", and instantly usable
    /// again the moment the toggle flips back on. A real, permanent removal
    /// path matters here in a way it wouldn't for ordinary book highlights.
    @discardableResult
    static func deleteAll(modelContext: ModelContext) throws -> Int {
        let existing = try modelContext.fetch(FetchDescriptor<PersonalWritingEntry>())
        for entry in existing {
            // SwiftData's cascade delete removes the `JournalAttachment` rows
            // but never the JPEGs on disk they point to -- leaving those
            // behind would directly contradict this function's own "a real,
            // permanent removal path" doc comment above, not just leak
            // storage. Same pairing `JournalListView.delete(_:)` and
            // `JournalEntryComposeView.save()`'s attachment removal already
            // follow.
            for attachment in entry.attachments {
                JournalAttachmentStore.delete(id: attachment.id)
            }
            modelContext.delete(entry)
        }
        try modelContext.save()
        return existing.count
    }
}
