import UIKit
import ImageIO

/// Persists journal-entry photo attachments to disk, keyed by
/// `JournalAttachment.id`. Rooted in Documents, not Caches unlike
/// `CoverImageCache` -- a cover can always be re-downloaded if evicted, but a
/// journal photo picked from the user's library is the only copy this app
/// will ever have; losing it to a Caches purge under disk pressure would be
/// real, unrecoverable data loss, not a minor inconvenience.
enum JournalAttachmentStore {
    // `static let` with a closure initializer runs exactly once per process,
    // lazily, thread-safely -- same fix already applied to `CoverImageCache`.
    // This directory is now on the automatic-restore launch path
    // (`AutoRestoreService.downloadPendingAttachments` calls `fileURL(for:)`
    // once per pending attachment row), where a `static var` computed
    // property re-running `createDirectory` -- a real filesystem syscall --
    // on every single access would mean one syscall per row at launch.
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("JournalAttachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func localFileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString + ".jpg")
    }

    private static func thumbnailFileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString + "-thumb.jpg")
    }

    /// Same file `localFileURL(for:)` resolves, exposed internally for
    /// `AutoBackupService`'s sidecar sync -- a direct file-to-file copy into
    /// the iCloud container, not a load-into-memory-then-write round trip.
    static func fileURL(for id: UUID) -> URL {
        localFileURL(for: id)
    }

    /// Synchronous, cheap local-disk read -- no network involved, safe to
    /// call from a view body's `.task` without an await first, same
    /// convention as `CoverImageCache.cachedImage(for:)`.
    static func image(for id: UUID) -> UIImage? {
        guard let data = try? Data(contentsOf: localFileURL(for: id)) else { return nil }
        return UIImage(data: data)
    }

    /// A small (`thumbnailMaxPixelDimension`) decode for list/grid rows --
    /// without this, showing a photo preview in a journal list meant
    /// decoding the same 1600px full-size JPEG `image(for:)` returns, on
    /// every row, every scroll. Falls back to the full image for an
    /// attachment saved before this tier existed (no thumbnail file on
    /// disk yet) rather than showing nothing -- every NEW save writes both
    /// tiers together (see `save(_:id:maxPixelDimension:)`), so this
    /// fallback only ever applies to already-saved photos, never a growing
    /// gap.
    static func thumbnail(for id: UUID) -> UIImage? {
        if let data = try? Data(contentsOf: thumbnailFileURL(for: id)), let image = UIImage(data: data) {
            return image
        }
        return image(for: id)
    }

    /// The raw already-downsampled JPEG bytes, for `BackupService.exportData`
    /// -- reads the file directly rather than round-tripping through
    /// `image(for:)` + re-encoding, which would silently apply a second lossy
    /// JPEG compression pass on every single backup taken.
    static func data(for id: UUID) -> Data? {
        try? Data(contentsOf: localFileURL(for: id))
    }

    /// Writes bytes to disk exactly as given, with no downsample/re-encode --
    /// for `BackupService.importData` restoring a backup's own
    /// `PersonalWritingEntryDTO.attachments`, which are already the output of
    /// `save(_:id:maxPixelDimension:)` below from whenever the backup was
    /// taken. Running restored bytes back through `save` would decode and
    /// re-JPEG-encode data that's already processed, for no benefit and a
    /// second generation of lossy compression.
    static func restore(_ data: Data, id: UUID) {
        try? data.write(to: localFileURL(for: id))
    }

    private static let thumbnailMaxPixelDimension: CGFloat = 300

    /// Downsamples then writes as JPEG. `Data`-based rather than URL-based --
    /// `PhotosPicker`/`Transferable` delivers raw `Data`, not a file URL, so
    /// this is `FigureImageLoader.downsampled`'s sibling for that input
    /// shape, not a duplicate of it. 1600px covers the widest journal photo
    /// display size this app has (a full-width detail view on the largest
    /// current iPhone) at a fraction of an original camera photo's footprint.
    @discardableResult
    static func save(_ data: Data, id: UUID, maxPixelDimension: CGFloat = 1600) -> Bool {
        guard let downsampled = downsampled(from: data, maxPixelDimension: maxPixelDimension),
              let jpegData = downsampled.jpegData(compressionQuality: 0.85) else { return false }
        do {
            try jpegData.write(to: localFileURL(for: id))
        } catch {
            return false
        }
        // Generated from the original `data`, not a re-downsample of the
        // just-written full image -- `CGImageSourceCreateThumbnailAtIndex`
        // works directly off the source regardless of target size, so this
        // avoids stacking a second JPEG generation's quality loss on top of
        // the first. Best-effort: a failed thumbnail write still leaves the
        // full-size save above intact, and `thumbnail(for:)` falls back to
        // the full image when this file is missing. `Self.downsampled`,
        // not the bare name -- the `downsampled` local binding a few lines
        // up (the full-size `UIImage`) shadows the static function of the
        // same name within this scope.
        if let thumb = Self.downsampled(from: data, maxPixelDimension: thumbnailMaxPixelDimension),
           let thumbData = thumb.jpegData(compressionQuality: 0.8) {
            try? thumbData.write(to: thumbnailFileURL(for: id))
        }
        return true
    }

    /// Every deletion of a `JournalAttachment` row (whether directly, or via
    /// `PersonalWritingEntry`'s cascade) must pair with a call here -- see
    /// `PersonalWritingEntry.attachments`'s own doc comment for why SwiftData's
    /// cascade alone doesn't remove the file this points to.
    static func delete(id: UUID) {
        try? FileManager.default.removeItem(at: localFileURL(for: id))
        try? FileManager.default.removeItem(at: thumbnailFileURL(for: id))
    }

    private static func downsampled(from data: Data, maxPixelDimension: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
