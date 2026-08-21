import SwiftData
import Foundation
import UIKit

/// One-time migration path for anyone with an existing Apple Journal habit --
/// exactly the case the new in-app Journal (`JournalListView`) exists for,
/// since Apple Journal itself can never be read by a third-party app going
/// forward (no read API in either direction, confirmed against
/// `JournalingSuggestions`'s actual scope: it only lets an app offer content
/// INTO a journaling app, never read one out). This closes that gap the only
/// way it can be closed -- a one-time import of whatever's already there.
///
/// Deliberately takes an already-uncompressed FOLDER, not the raw
/// `AppleJournalEntries.zip` Journal's own "Export Journal" produces. Cobux
/// has zero third-party dependencies today (only the local `CobuxCore` path
/// package -- see `project.yml`), and parsing a real ZIP container from
/// scratch (central directory, local file headers) to avoid adding one is
/// real, fragile work for a one-time migration path. iOS's Files app can
/// already uncompress a `.zip` in place (long-press it, "Uncompress") --
/// `SettingsView`'s import button instructs exactly that, then a folder
/// `.fileImporter` picks the result directly, so this reads plain files with
/// `FileManager` like anything else and needs no archive-parsing code at all.
///
/// The internal shape below (an `Entries/` folder of `.html` files) is
/// reconstructed from third-party reports of what Journal's export actually
/// contains -- Apple documents the export BUTTON, never the file format
/// behind it, and no verified sample was available to test this against
/// while writing it. Built defensively for exactly that reason: it walks
/// every `.html` file anywhere under the picked folder (not hard-coded to an
/// `Entries/` subpath), so a naming difference in a future export narrows
/// what's found rather than finding nothing at all. Whoever runs this first
/// should sanity-check the imported count and a couple of entries' text
/// against what Journal actually shows before trusting it as complete.
/// `@MainActor` -- `importFolder` was previously a plain `nonisolated static
/// func`, called from an unstructured `Task { }` in `SettingsView` (itself
/// only implicitly main-actor via SwiftUI's own body context). With no
/// annotation here, the compiler was free to run the whole body -- including
/// every `modelContext.fetch`/`.insert`/`.save()` call -- off the main
/// actor, which SwiftData's `ModelContext` doesn't support. It also happens
/// to be where Apple's own HTML-to-`NSAttributedString` importer runs, which
/// Apple documents as main-thread-only. Pinning the whole enum to the main
/// actor makes both of those a compile-time guarantee instead of a race that
/// only failed to crash by luck.
@MainActor
enum AppleJournalImportService {
    struct ImportResult {
        var imported: Int
        var skippedDuplicates: Int
        var htmlFilesFound: Int
    }

    /// Matches `PersonalWritingImportService.DedupeKey`'s exact shape and
    /// reasoning (a real `Hashable` struct, not a delimiter-joined string) --
    /// re-running this import after a later Journal export must not create
    /// duplicate rows for entries already migrated. `day` is included
    /// because `title` is always blank here (see the comment at its call
    /// site below) -- without it, two short entries that happen to share
    /// their exact text on two different days (e.g. both just say "Tired.")
    /// would collapse into one on the second import.
    private struct DedupeKey: Hashable {
        let source: String
        let title: String
        let text: String
        let day: DateComponents
    }

    /// Apple Journal's own export format is undocumented -- Apple documents
    /// the export BUTTON, never the file format behind it -- but two
    /// independent third-party projects that parse it agree on the same
    /// shape: entries live at `Entries/YYYY-MM-DD.html` (optionally suffixed
    /// with a title and a `_(n)` de-dup counter for same-day entries), and
    /// the rendered page itself repeats that date as a visible string like
    /// "Wednesday, May 14, 2025" inside a `div.pageHeader` element. Neither
    /// carries a time-of-day. Preferring the body string over the filename
    /// when both parse is deliberate: the filename regex below only reads
    /// digits, so it can't be fooled by a title that happens to start with
    /// something numeric, but the body string is the one actually rendered
    /// to the person who wrote the entry.
    private static let filenameDatePattern = try? NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-(\d{2})"#)

    private static let bodyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter
    }()

    /// Best-effort real entry date, in preference order: the visible date
    /// string Journal itself renders into the page, then the `YYYY-MM-DD`
    /// prefix Journal names the file with, then `nil` (the caller falls back
    /// to filesystem metadata -- the export/uncompress moment -- only when
    /// neither of these actually-authored signals is present).
    private static func extractedDate(fromBody bodyText: String, filename: String) -> Date? {
        for line in bodyText.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let date = bodyDateFormatter.date(from: trimmed) {
                return date
            }
        }

        let nsFilename = filename as NSString
        guard let match = filenameDatePattern?.firstMatch(
            in: filename,
            range: NSRange(location: 0, length: nsFilename.length)
        ), match.numberOfRanges == 4 else { return nil }

        var components = DateComponents()
        components.year = Int(nsFilename.substring(with: match.range(at: 1)))
        components.month = Int(nsFilename.substring(with: match.range(at: 2)))
        components.day = Int(nsFilename.substring(with: match.range(at: 3)))
        return Calendar.current.date(from: components)
    }

    /// `source: "Apple Journal"` keeps these visually and dedup-distinct from
    /// both `"journal"` (composed in `JournalEntryComposeView`) and whatever
    /// folder names appear in a Notes-based export -- `JournalEntryRow`
    /// already only hides the source badge for the exact string `"journal"`,
    /// so a migrated entry reads as imported, honestly, the same way a
    /// Notes-imported one already does.
    /// `async throws`, yielding every 10 entries -- same pattern
    /// `PersonalWritingImportService.importData` already uses, for the same
    /// reason: on-device embedding is real per-entry ML inference, and a
    /// years-deep journal export is exactly the "hundreds of entries" case
    /// that pattern exists for.
    @discardableResult
    static func importFolder(at folderURL: URL, modelContext: ModelContext) async throws -> ImportResult {
        guard folderURL.startAccessingSecurityScopedResource() else {
            throw ImportError.couldNotAccessFolder
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ImportError.couldNotAccessFolder
        }

        let htmlURLs = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "html" }

        let existing = (try? modelContext.fetch(FetchDescriptor<PersonalWritingEntry>())) ?? []
        var existingKeys = Set(existing.map { entry -> DedupeKey in
            let existingDay = (entry.modifiedDate ?? entry.dateImported)
            let components = Calendar.current.dateComponents([.year, .month, .day], from: existingDay)
            return DedupeKey(source: entry.source, title: entry.title, text: entry.text, day: components)
        })

        var imported = 0
        var skipped = 0
        var processedSinceSave = 0

        for url in htmlURLs {
            guard let data = try? Data(contentsOf: url) else { continue }
            // `NSAttributedString`'s own HTML document type is Apple's real
            // HTML-to-plain-text conversion (the same class of tool
            // `PersonalWritingImportService`'s own JSON export already
            // arrives pre-stripped by, on the export side) -- far more
            // robust than a hand-rolled tag-stripping regex against markup
            // this code has never actually seen a real sample of.
            guard let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
            ) else { continue }

            let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // Real authored date first (page body, then filename); only
            // falls back to filesystem metadata -- the export/uncompress
            // moment, not when the entry was actually written -- when
            // neither signal above is present. Getting this right matters
            // well beyond display: `JournalListView`'s own sort and the new
            // journal streak both key entirely off `modifiedDate`, so a
            // years-deep import landing with today's date on every row
            // would have silently destroyed its real chronology and could
            // have fabricated a streak that never happened.
            let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let filesystemDate = resourceValues?.contentModificationDate ?? resourceValues?.creationDate
            let modifiedDate = extractedDate(fromBody: text, filename: url.lastPathComponent) ?? filesystemDate
            let day = modifiedDate.map { Calendar.current.dateComponents([.year, .month, .day], from: $0) } ?? DateComponents()

            // Blank title, same convention `JournalEntryComposeView` already
            // established -- `JournalListView`'s row falls back to a
            // formatted date, and a title guessed from HTML (a heading tag
            // that may or may not exist) is more likely to be wrong than
            // simply absent.
            let key = DedupeKey(source: "Apple Journal", title: "", text: text, day: day)
            guard !existingKeys.contains(key) else {
                skipped += 1
                continue
            }
            existingKeys.insert(key)

            let entry = PersonalWritingEntry(source: "Apple Journal", title: "", text: text, modifiedDate: modifiedDate)
            entry.embedding = EmbeddingService.embed(text)
            modelContext.insert(entry)
            imported += 1

            processedSinceSave += 1
            if processedSinceSave >= 10 {
                try? modelContext.save()
                await Task.yield()
                processedSinceSave = 0
            }
        }

        try modelContext.save()
        return ImportResult(imported: imported, skippedDuplicates: skipped, htmlFilesFound: htmlURLs.count)
    }

    enum ImportError: LocalizedError {
        case couldNotAccessFolder

        var errorDescription: String? {
            "Couldn't read that folder. Make sure you picked the uncompressed AppleJournalEntries folder, not the .zip file itself."
        }
    }
}
