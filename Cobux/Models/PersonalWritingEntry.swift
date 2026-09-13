import SwiftData
import Foundation

/// Rajan's own personal writing (Apple Notes the user's own writing folders,
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
    /// Which Apple Notes folder this came from — a folder name, or
    /// "a Notes folder" in the real export, but stored as a plain string
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
    /// Accumulated seconds the compose sheet was open across every writing
    /// session that saved into this entry -- what the detail view's stats bar
    /// reads as "writing time," mirroring Apple Journal's own per-entry
    /// stats. Optional (not `= 0`) so existing rows migrate untouched and an
    /// imported entry -- whose writing time is genuinely unknown -- shows no
    /// number rather than a fake zero. Lightweight migration only: adding an
    /// optional attribute is the one schema change SwiftData handles in place.
    var writingSeconds: Int?
    /// The entry this one answers, when it was written as a reply to his own
    /// past writing -- The Correspondence. A reference, never a copy: the
    /// original is never touched, and the reply is an ordinary entry in every
    /// other respect (streaks, export, embedding, widgets). Same contract as
    /// `JournalKeep.entryID`.
    ///
    /// Additive optional -- the one schema change SwiftData handles in place
    /// (see `writingSeconds` above, which carries the migration ruling).
    var answersEntryID: UUID?
    /// The original's date AS IT STOOD when he answered it --
    /// `JournalKeep.sourceDate`'s exact reasoning. "Continue Entry" moves the
    /// original's `modifiedDate` forward, so reading the live date later could
    /// postdate the reply; this pins "what he was answering" to something that
    /// stays true. Also what lets a dangling link (post-restore) still render
    /// an honest dated line.
    var answersEntryDate: Date?
    /// Where this was written -- the locality name, captured once at first
    /// save when ambient context knows it. HIS order, 2026-09-05: "in journal
    /// the location should also be saved." Saved ALWAYS (unlike the stamp,
    /// which stays quiet about the usual place -- that rule governs what the
    /// TEXT says; this is data he owns, on-device, shown quietly in the
    /// colophon). Never transmitted as a field; additive optional.
    var locality: String?
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
            // See `Highlight.embedding` -- one shared, unaligned-safe bulk
            // decoder rather than three copies of a per-element load.
            return EmbeddingCodec.decode(embeddingData)
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
