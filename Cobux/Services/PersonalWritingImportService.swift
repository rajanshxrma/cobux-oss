import SwiftData
import Foundation
import UIKit
import UniformTypeIdentifiers

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
        /// Photo filenames, resolved against `journal-images/` in the app's own
        /// ubiquity container.
        ///
        /// Optional because it did not exist until now, and every export
        /// written before this build omits it — an import must keep working
        /// against those files rather than failing to decode. His ask was for
        /// his Apple Notes and Apple Journal writing "even with the images",
        /// and the reason it never arrived is that NEITHER side had a field
        /// for one: the export carried title/text/source/date, and so did this
        /// struct. Re-running the sync was never going to fix that.
        ///
        /// Side-car files rather than base64 in this JSON on purpose: the
        /// export is ~478 KB today, and inlining photos would push it into
        /// tens of megabytes, making every launch's digest check expensive and
        /// risking the whole import failing on one bad entry.
        var imageFiles: [String]?
    }

    /// Why one picked file did not become an entry. Reported to the person,
    /// never swallowed: every entry an import creates is permanent (native
    /// entries have no delete path), so what it declines must be as visible
    /// as what it admits.
    enum SkipReason: Equatable {
        case unsupportedType
        case tooLarge
        case unreadable
        case empty

        var label: String {
            switch self {
            case .unsupportedType: "not a text, Markdown, RTF or HTML file"
            case .tooLarge: "over \(PersonalWritingImportService.maxFileBytes / (1024 * 1024)) MB"
            case .unreadable: "couldn't be read"
            case .empty: "empty"
            }
        }
    }

    struct SkippedFile: Equatable {
        let name: String
        let reason: SkipReason
    }

    struct ImportResult {
        var imported: Int
        var skippedDuplicates: Int
        /// Files the file-import path could not honestly turn into entries,
        /// each with its reason. Empty for the JSON path, which has no files.
        var skippedFiles: [SkippedFile] = []
    }

    /// Where the exporter drops photos alongside the JSON, inside the app's
    /// OWN ubiquity container. An iOS app cannot read arbitrary iCloud Drive
    /// paths without a picker, but it can always read its own container.
    static let imagesDirectoryName = "journal-images"

    /// Copies each exported photo into `JournalAttachmentStore` and links it to
    /// the entry, so an imported photo behaves exactly like one added in the
    /// app — it renders on the feed's photo card, in the detail hero, and it is
    /// carried by backup and restore.
    ///
    /// A missing or unreadable file skips THAT photo and leaves the entry
    /// intact. Losing the writing because a photo went missing would be a far
    /// worse outcome than a text-only entry, and these are irreplaceable: this
    /// is his record of everything he has ever written.
    private static func attachImages(_ names: [String]?,
                                     to entry: PersonalWritingEntry,
                                     imagesDirectory: URL?) {
        guard let names, !names.isEmpty, let imagesDirectory else { return }
        for name in names {
            // Defend the container boundary: a filename is a filename, never a
            // path that could climb out of the directory it is resolved in.
            let safe = (name as NSString).lastPathComponent
            guard !safe.isEmpty, safe != ".", safe != ".." else { continue }
            let url = imagesDirectory.appendingPathComponent(safe)
            guard let data = try? Data(contentsOf: url) else { continue }
            let attachment = JournalAttachment(entry: entry)
            // Write the file BEFORE linking the row. The reverse order is how a
            // failed write leaves a persisted attachment pointing at nothing,
            // which then renders as an empty tile -- the same ghost-row defect
            // the composer has.
            guard JournalAttachmentStore.save(data, id: attachment.id) else { continue }
            entry.attachments.append(attachment)
        }
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

    /// The plain-space twin of `modifiedDateFormatter`, hoisted for exactly the
    /// reason that one is. `parseModifiedDate` is not called once per file: the
    /// newest-first sort in `importData` calls it TWICE PER COMPARISON, and
    /// then again for every entry it inserts. On an export that uses a normal
    /// space rather than the narrow no-break one, every one of those calls
    /// built a `DateFormatter` from scratch -- locale, calendar and date
    /// symbols -- O(n log n) times for a 245-entry import.
    ///
    /// Safe to share on the same terms as its twin above: never mutated after
    /// construction, and `importData` (its only caller) is `@MainActor`.
    private static let fallbackModifiedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm:ss a"
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
        return fallbackModifiedDateFormatter.date(from: normalized)
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

    // ------------------------------------------------------------------
    // The file path: what the journal's first-run screen and its picker use.
    // ------------------------------------------------------------------

    /// What the picker admits, and exactly what `importPlainTextFiles` can
    /// honestly read. `.text` is deliberately ABSENT: it is the parent type of
    /// RTF and HTML, so it let a TextEdit .rtf or a saved web page through to
    /// be read as raw UTF-8 markup and imported as an entry -- permanently,
    /// because native entries have no delete path. RTF and HTML are admitted
    /// by name and decoded through Apple's own document importers instead.
    /// Markdown conforms to plain text, and is named too for pickers that
    /// resolve `.md` by extension. `.folder` is what lets a whole folder be
    /// picked at all -- the first-run screen promised one while the old list
    /// greyed every folder out.
    static let supportedContentTypes: [UTType] = {
        var types: [UTType] = [.plainText, .utf8PlainText, .rtf, .html, .folder]
        for ext in ["md", "markdown"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }()

    /// A sane ceiling per file. One journal entry is rarely 50 KB; a file
    /// past this is an archive or a formatted document with images embedded,
    /// and turning it into ONE entry -- rendered as one `Text`, embedded as
    /// one vector, permanent -- serves nobody. Skipped with the size named,
    /// so he can save it as plain text and try again.
    static let maxFileBytes = 1 * 1024 * 1024

    /// The one-line account the journal shows after a file import. Names what
    /// happened to EVERY picked file -- brought in, already here, or skipped
    /// and why. A skipped file used to vanish without a word.
    static func fileImportSummary(_ result: ImportResult) -> String {
        var parts: [String] = []
        if result.imported > 0 {
            parts.append("Brought in \(result.imported) entr\(result.imported == 1 ? "y" : "ies").")
        }
        if result.skippedDuplicates > 0 {
            parts.append("\(result.skippedDuplicates) already here.")
        }
        if !result.skippedFiles.isEmpty {
            let shown = result.skippedFiles.prefix(3).map { "\($0.name) (\($0.reason.label))" }
            let more = result.skippedFiles.count - shown.count
            parts.append("Skipped \(result.skippedFiles.count): "
                         + shown.joined(separator: ", ")
                         + (more > 0 ? ", and \(more) more." : "."))
        }
        if parts.isEmpty { parts.append("Nothing to bring in.") }
        return parts.joined(separator: " ")
    }

    private enum Kind {
        case plain, rtf, html
    }

    /// RTF and HTML first: both also conform to `.text`, and HTML never
    /// conforms to `.plainText`, so the order only matters for clarity.
    private static func kind(of type: UTType?) -> Kind? {
        guard let type else { return nil }
        if type.conforms(to: .rtf) { return .rtf }
        if type.conforms(to: .html) { return .html }
        if type.conforms(to: .plainText) { return .plain }
        return nil
    }

    private enum Decoded {
        case text(String)
        case skipped(SkipReason)
    }

    /// Every regular file under a picked folder. Hidden files and package
    /// internals are skipped; sorted by path so re-importing the same folder
    /// walks it in the same order. Must be called INSIDE the folder's
    /// security scope, and the files it returns must be read inside it too.
    private static func regularFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// UTF-8 first (a BOM is stripped by `normalise`), then Foundation's own
    /// encoding detection over the usual suspects, then those encodings tried
    /// directly. Only when all of that fails is the file unreadable -- and it
    /// says so. It used to be `String(contentsOf:encoding: .utf8)` and a
    /// silent `continue`, so a Latin-1 or UTF-16 export simply never arrived.
    static func decodePlainText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        let candidates: [String.Encoding] = [.utf16, .utf16LittleEndian, .utf16BigEndian,
                                             .windowsCP1252, .isoLatin1, .macOSRoman]
        var converted: NSString?
        let detected = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: candidates.map { NSNumber(value: $0.rawValue) },
                .allowLossyKey: false,
            ],
            convertedString: &converted,
            usedLossyConversion: nil
        )
        if detected != 0, let converted { return converted as String }
        for encoding in candidates {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return nil
    }

    /// A UTF-8 BOM survives `String(data:encoding:)` as U+FEFF, which
    /// `.whitespacesAndNewlines` does not trim -- so it became the first
    /// character of the title.
    private static func normalise(_ text: String) -> String {
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads and decodes one regular file. `nonisolated async`, so plain text
    /// and RTF -- Foundation's own parsers, safe on any thread -- decode off
    /// the main actor; HTML alone hops to main, where Apple documents its
    /// importer must run (`AppleJournalImportService` carries the same rule).
    private static func decode(_ url: URL, kind: Kind, size: Int?) async -> Decoded {
        if let size, size > maxFileBytes { return .skipped(.tooLarge) }
        guard let data = try? Data(contentsOf: url) else { return .skipped(.unreadable) }
        if data.count > maxFileBytes { return .skipped(.tooLarge) }

        let text: String?
        switch kind {
        case .plain:
            text = decodePlainText(data)
        case .rtf:
            text = (try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ))?.string
        case .html:
            text = await MainActor.run {
                (try? NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.html,
                              .characterEncoding: String.Encoding.utf8.rawValue],
                    documentAttributes: nil
                ))?.string
            }
        }
        guard let text else { return .skipped(.unreadable) }
        let clean = normalise(text)
        return clean.isEmpty ? .skipped(.empty) : .text(clean)
    }

    /// Imports files and folders of writing -- the shape a real first-run
    /// user actually has: a .txt or .md, a TextEdit .rtf, a saved .html, or a
    /// folder of them. Each file becomes one entry, titled from its first
    /// line when that reads as a title and from its filename otherwise, dated
    /// from its filesystem modification date (the best signal a bare file
    /// carries). This is the path the journal's first-run screen uses; the
    /// JSON path below is for Cobux's own structured exports.
    ///
    /// Careful and honest, because every entry it creates is permanent:
    /// - only `supportedContentTypes` are read, and by the right importer --
    ///   never RTF or HTML as raw bytes
    /// - a folder is walked inside its security scope, which stays open until
    ///   its last file has been read
    /// - a file over `maxFileBytes`, of another type, unreadable in any
    ///   encoding, or empty is SKIPPED and NAMED in the result, never dropped
    ///   in silence
    ///
    /// `@MainActor`: this inserts into and saves a main-context `ModelContext`,
    /// which SwiftData does not permit off the actor that owns it -- the same
    /// guarantee `AppleJournalImportService` makes for the same reason. The
    /// per-file reading and decoding hops off it (`decode`).
    ///
    /// - Parameter deferEmbeddings: leave `embedding` nil for
    ///   `backfillPersonalWritingEmbeddings` to fill in later. Embedding inline
    ///   is the slowest part of an import and delays the thing the user is
    ///   actually waiting for: seeing the writing in the app. Nothing is lost
    ///   -- an entry without an embedding is fully readable and editable, it
    ///   just isn't semantically searchable until the backfill runs.
    @discardableResult
    @MainActor
    static func importPlainTextFiles(
        urls: [URL],
        modelContext: ModelContext,
        deferEmbeddings: Bool = true
    ) async throws -> ImportResult {
        let existing = (try? modelContext.fetch(FetchDescriptor<PersonalWritingEntry>())) ?? []
        var keys = Set(existing.map { DedupeKey(source: $0.source, title: $0.title, text: $0.text) })
        var result = ImportResult(imported: 0, skippedDuplicates: 0)
        var processedSinceSave = 0

        for picked in urls {
            // A folder's scope covers its children only while it is open, so
            // it stays open for the whole walk and every read, not just the
            // listing.
            let scoped = picked.startAccessingSecurityScopedResource()
            defer { if scoped { picked.stopAccessingSecurityScopedResource() } }

            let isFolder = (try? picked.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
                ?? picked.hasDirectoryPath
            let files = isFolder ? regularFiles(in: picked) : [picked]

            for url in files {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .contentTypeKey])
                let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
                // `Self.`, not the bare name: the local `kind` being bound would
                // otherwise shadow the function inside its own initialiser.
                guard let kind = Self.kind(of: type) else {
                    result.skippedFiles.append(SkippedFile(name: url.lastPathComponent, reason: .unsupportedType))
                    continue
                }

                let text: String
                switch await decode(url, kind: kind, size: values?.fileSize) {
                case .skipped(let reason):
                    result.skippedFiles.append(SkippedFile(name: url.lastPathComponent, reason: reason))
                    continue
                case .text(let decoded):
                    text = decoded
                }

                // Title: an explicit first line if the file has one, else the
                // filename. Never invented.
                let firstLine = text.components(separatedBy: .newlines).first.map {
                    $0.trimmingCharacters(in: .whitespaces)
                } ?? ""
                let title = ((1...80).contains(firstLine.count) ? firstLine
                             : url.deletingPathExtension().lastPathComponent)

                let key = DedupeKey(source: "Imported", title: title, text: text)
                guard keys.insert(key).inserted else { result.skippedDuplicates += 1; continue }

                let row = PersonalWritingEntry(source: "Imported", title: title, text: text,
                                               modifiedDate: values?.contentModificationDate)
                if !deferEmbeddings { row.embedding = EmbeddingService.embed(text) }
                modelContext.insert(row)
                result.imported += 1

                // Same save-every-10-and-yield rhythm as `importData`, so a
                // folder of hundreds neither freezes the screen nor loses
                // everything already inserted if the app dies midway.
                processedSinceSave += 1
                if processedSinceSave >= 10 {
                    try? modelContext.save()
                    await Task.yield()
                    processedSinceSave = 0
                }
            }
        }
        try? modelContext.save()
        return result
    }

    // ------------------------------------------------------------------
    // The JSON path: Cobux's own structured export.
    // ------------------------------------------------------------------

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
    /// `@MainActor`, and that is load-bearing rather than decorative. This
    /// takes the caller's `modelContext` — the main context — and inserts and
    /// saves into it. A `nonisolated` `async` function does NOT stay on the
    /// caller's actor (SE-0338): every `await` here hopped to the cooperative
    /// pool and did SwiftData work on a context owned by the main actor. That
    /// is the Build-5 crash class this codebase has already paid for twice.
    ///
    /// Embeddings therefore default to DEFERRED now: on-device inference is
    /// the slow part, and with the isolation corrected an inline embed would
    /// run a model per entry on the main thread. The bounded, idempotent
    /// backfill fills them in afterwards, exactly as the composer's save path
    /// does; retrieval degrades to keyword for the few seconds in between.
    @MainActor
    static func importData(
        _ data: Data,
        modelContext: ModelContext,
        deferEmbeddings: Bool = true
    ) async throws -> ImportResult {
        let decoder = JSONDecoder()
        let decoded = try decoder.decode([ExportedEntry].self, from: data)

        // Resolved once, not per entry: the container lookup is an async hop
        // and 245 entries would otherwise pay for it 245 times. nil simply
        // means photos are unavailable this run, and every entry still
        // imports its text.
        let imagesDirectory = await UbiquityContainer.shared.documentsURL()?
            .appendingPathComponent(imagesDirectoryName, isDirectory: true)

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
            attachImages(entry.imageFiles, to: row, imagesDirectory: imagesDirectory)
            imported += 1

            processedSinceSave += 1
            if processedSinceSave >= 10 {
                try? modelContext.save()
                await Task.yield()
                processedSinceSave = 0
            }
        }

        try modelContext.save()

        // Whatever was deferred above is picked up here rather than at the
        // next launch, so an import is searchable within seconds of finishing
        // instead of only after the app is relaunched. Bounded and idempotent
        // (it only ever fetches rows whose `embeddingData` is nil), so a
        // second kick while one is running costs nothing.
        if deferEmbeddings && imported > 0 {
            let container = modelContext.container
            Task.detached(priority: .utility) {
                await CobuxApp.backfillPersonalWritingEmbeddings(container: container)
            }
        }

        return ImportResult(imported: imported, skippedDuplicates: skipped)
    }

    /// This content is genuinely personal (health, relationships, family,
    /// financial stress -- real examples from the actual export). Turning
    /// off `personalWritingContextEnabled` only stops it from being used in

    // `deleteAll` used to live here. It is gone, not merely unused.
    //
    // His ruling, 2026-09-02: a Cobux journal entry has no delete path. Its one
    // caller -- the Settings bulk delete -- was removed with it, which left a
    // function that could wipe every imported entry sitting in the codebase
    // with nothing calling it. Dead code that destroys data is not harmless;
    // it is the thing someone wires up later without knowing the rule.
    //
    // Nothing replaced it, and nothing is meant to yet: deleting a note in
    // Apple Notes does NOT remove the entry it was imported into. This import
    // is additive only, in both directions. The tombstone design -- deletion
    // happening at the SOURCE and arriving here guarded, which is the shape
    // `swiftui-regression-lint.py`'s `journal-delete-path` check already
    // exempts by name -- is unbuilt, and building it would first need a ruling
    // this file cannot make for him: an entry imported from a note and then
    // edited in Cobux is his own writing under the no-delete rule, and no
    // source-side tombstone can know that. That is his call to make, of the
    // kind docs/deferred.md's "Rulings held for him" table collects, and
    // guessing it would be origination. Until he makes it, an entry that is
    // here stays here.

}
