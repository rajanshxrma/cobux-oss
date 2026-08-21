import SwiftData
import Foundation

/// Rajan's own personal writing (Apple Notes "21writing"/"Journal" folders,
/// plus reflective notes from his general Notes), imported once via
/// `PersonalWritingImportService` from a JSON export produced outside the
/// app. Lets chat draw on his own past reflections the same way it already
/// cites book highlights (see `SearchService.relevantPersonalWriting`),
/// gated behind an explicit, always-visible privacy toggle since this
/// content is genuinely personal.
@Model
final class PersonalWritingEntry {
    /// Same pattern as `Highlight.id`/`Figure.id`: assigned explicitly in
    /// `init` too, not left to the `= UUID()` schema default alone — a
    /// default-valued property is evaluated ONCE at schema-definition time,
    /// not per instance, so every row would otherwise share one UUID the
    /// moment more than one gets migrated in under an old schema version.
    /// See `CobuxApp.repairDuplicateIDs`, which this type is also covered by.
    var id: UUID = UUID()
    /// Which Apple Notes folder this came from — "21writing", "Journal", or
    /// "Notes(reflective)" in the real export, but stored as a plain string
    /// (not an enum) so a future export with a differently-named folder never
    /// fails to import.
    var source: String
    var title: String
    var text: String
    /// AppleScript's raw date-to-string output couldn't be parsed for every
    /// entry (see `PersonalWritingImportService`'s date parsing) — `nil` here
    /// means "unknown," not "never modified," and callers should fall back to
    /// `dateImported` for sorting/display rather than treating `nil` as an
    /// error.
    var modifiedDate: Date?
    var dateImported: Date
    var embeddingData: Data?
    /// Photos attached to this entry -- see `JournalAttachment`'s own doc
    /// comment for why the image bytes live on disk (`JournalAttachmentStore`)
    /// rather than here. Cascade delete only removes these rows, not the
    /// files they point to; every call site that deletes an entry or a
    /// single attachment must also call `JournalAttachmentStore.delete(id:)`
    /// itself, the same "SwiftData delete + explicit file cleanup" pairing
    /// `CoverImageCache`-cached covers never needed (they're a cache, safe to
    /// leak until the OS reclaims Caches) but a Documents-rooted, only-copy
    /// file genuinely does.
    @Relationship(deleteRule: .cascade, inverse: \JournalAttachment.entry)
    var attachments: [JournalAttachment] = []

    init(source: String, title: String, text: String, modifiedDate: Date? = nil, dateImported: Date = .now) {
        self.id = UUID()
        self.source = source
        self.title = title
        self.text = text
        self.modifiedDate = modifiedDate
        self.dateImported = dateImported
    }

    /// Packs/unpacks `embeddingData` as a `[Float]` sentence vector for
    /// semantic search — identical encode/decode pattern to
    /// `Highlight.embedding`, deliberately not reinvented.
    var embedding: [Float]? {
        get {
            guard let embeddingData else { return nil }
            // `loadUnaligned`, not `bindMemory` -- see `Highlight.embedding`'s
            // identical comment on why `bindMemory`'s alignment assumption
            // doesn't hold for a `Data` slice from SwiftData's own storage.
            return embeddingData.withUnsafeBytes { rawBuffer in
                let count = rawBuffer.count / MemoryLayout<Float>.size
                return (0..<count).map { rawBuffer.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self) }
            }
        }
        set {
            guard let newValue else {
                embeddingData = nil
                return
            }
            embeddingData = newValue.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }
}
