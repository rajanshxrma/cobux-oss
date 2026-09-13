import SwiftData
import Foundation

/// A photo attached to a `PersonalWritingEntry` -- the image bytes themselves
/// never live in SwiftData (a large blob column drags down every ordinary
/// fetch of the owning entry, the same reasoning `CoverImageCache` and
/// `Highlight.embedding`'s separate `embeddingData` column already both
/// follow). This row is purely the pointer + metadata; `JournalAttachmentStore`
/// is where the actual JPEG lives on disk, keyed by `id`.
@Model
final class JournalAttachment {
    /// Same explicit-assignment convention as `Highlight.id`/`PersonalWritingEntry.id`
    /// -- see `PersonalWritingEntry.id`'s own doc comment for why the `= UUID()`
    /// schema default alone isn't enough.
    var id: UUID = UUID()
    var entry: PersonalWritingEntry?
    var dateAdded: Date
    /// Voice notes only. The words, written on the phone after the entry
    /// saved (`VoiceTranscriptionService`) -- Rajan, build 58: "The voice
    /// recording transcript at the end of saving has to be a must." `nil` for
    /// a photo, for a note not yet transcribed, and for a note whose
    /// transcript came back empty (silence). Additive optional: the one
    /// schema change SwiftData handles in place -- see
    /// `PersonalWritingEntry.writingSeconds` for the migration ruling.
    var transcript: String?
    /// `VoiceTranscriptionService.State.rawValue`: "pending" / "done" /
    /// "failed" / "unavailable". A string, not an enum, for the same reason
    /// `PersonalWritingEntry.source` is: a value this build does not know
    /// must still load. `nil` on a photo and on a voice note recorded before
    /// transcripts existed, which the detail view treats as "not yet asked".
    var transcriptState: String?
    /// Voice notes only: the recorder's measured length, so the detail
    /// colophon can say "2 min voice note" without opening the file. `nil`
    /// for photos and for notes saved before this field; the detail view
    /// reads the file once, off-main, for those.
    var durationSeconds: Double?

    init(entry: PersonalWritingEntry?, dateAdded: Date = .now) {
        self.id = UUID()
        self.entry = entry
        self.dateAdded = dateAdded
    }
}
