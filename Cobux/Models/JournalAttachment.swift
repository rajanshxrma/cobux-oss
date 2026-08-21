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

    init(entry: PersonalWritingEntry?, dateAdded: Date = .now) {
        self.id = UUID()
        self.entry = entry
        self.dateAdded = dateAdded
    }
}
