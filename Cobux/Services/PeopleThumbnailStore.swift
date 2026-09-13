import Foundation
import UIKit

/// Where a person's linked contact photo lives:
/// `Application Support/People/<personID>.jpg` — the `VolumeStore` convention,
/// excluded from backup.
///
/// The photo is a COPY made at pick time (`docs/people-in-the-journal.md` §4):
/// the picker hands the app one `CNContact` for the one he tapped, the app
/// keeps a few KB of JPEG and the contact's identifier, and never touches the
/// address book again. Excluded from backup for the same reason the volumes
/// are — regenerable (re-pick) and never the record. The scan ledger the
/// indexer keeps (`scan.json`) shares this directory, so "Forget the people
/// index" removes the whole folder in one call (`removeAll()`).
///
/// Nothing here is ever written to the App Group container: widgets and the
/// Messages extension never see a person (§6).
enum PeopleThumbnailStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("People", isDirectory: true)
    }

    /// The longest side a stored thumbnail may have. A 40pt row avatar and a
    /// 72pt page header at 3x need 216px; 240 leaves a margin and keeps the
    /// file at a few KB, which is what "a few KB of JPEG" in the design means.
    static let maxPixelSize: CGFloat = 240

    static func url(for personID: UUID) -> URL {
        directory.appendingPathComponent("\(personID.uuidString).jpg")
    }

    /// Whether a photo is on disk for this person. A file stat, no decode —
    /// safe to call from a `.task` per row.
    static func hasThumbnail(for personID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: personID).path)
    }

    /// Stores the contact's image, downscaled to `maxPixelSize`, as JPEG.
    /// Any earlier photo for the person is replaced ("Change photo").
    @discardableResult
    static func save(imageData: Data, for personID: UUID) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup(directory)
        let jpeg = downscaled(imageData) ?? imageData
        var target = url(for: personID)
        try jpeg.write(to: target, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
        return target
    }

    /// The decoded photo, or nil when none is linked. Decodes a few-KB JPEG;
    /// callers run it behind `.task` off the first frame, the way
    /// `JournalThumbnailImage` loads attachment thumbnails.
    static func image(for personID: UUID) -> UIImage? {
        guard let data = try? Data(contentsOf: url(for: personID)) else { return nil }
        return UIImage(data: data)
    }

    /// Unlink: the photo goes; the caller clears `contactIdentifier`.
    static func remove(for personID: UUID) {
        try? FileManager.default.removeItem(at: url(for: personID))
    }

    /// "Forget the people index": every thumbnail AND the indexer's scan
    /// ledger, which shares this folder. Entries are untouched — nothing in
    /// this directory is the record.
    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Private

    private static func excludeFromBackup(_ folder: URL) {
        var folder = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    /// Re-encodes to a bounded JPEG. Contact thumbnails from the picker are
    /// already small; a full `imageData` fallback can be a megabyte, and a
    /// megabyte per person is not "a few KB".
    private static func downscaled(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height) * image.scale
        guard longest > maxPixelSize else {
            return image.jpegData(compressionQuality: 0.85)
        }
        let ratio = maxPixelSize / longest
        let size = CGSize(width: image.size.width * image.scale * ratio,
                          height: image.size.height * image.scale * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.85)
    }
}
