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

    /// The dimension is IN THE FILENAME on purpose. A thumbnail is written once
    /// and reused forever, so raising `thumbnailMaxPixelDimension` would
    /// otherwise improve only photos imported after the change and leave every
    /// existing one soft — the fix would look like it had not worked.
    /// Encoding the size means a new constant simply misses the old file and
    /// regenerates at the new one.
    private static func thumbnailFileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(
            "\(id.uuidString)-thumb\(Int(thumbnailMaxPixelDimension)).jpg")
    }

    /// Voice notes live beside the photos deliberately: this directory is
    /// already on the automatic backup/restore path, so a recording is covered
    /// by the same guarantees as an image without any new plumbing.
    static func audioURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString + ".m4a")
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
    /// Bytes for an attachment, whatever KIND it is.
    ///
    /// This used to read `<id>.jpg` and nothing else, so a voice note was
    /// silently skipped by `BackupService` -- present on the device, absent from
    /// every backup, and therefore gone on restore or a new phone. Resolving by
    /// the id rather than by a hardcoded extension means a new attachment type
    /// is covered the day it is added instead of the day someone notices.
    static func data(for id: UUID) -> Data? {
        guard let url = existingFileURL(for: id) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Every attachment container Cobux writes. Declared ONCE and read by the
    /// store, the automatic backup and the restore: the voice-note data-loss bug
    /// existed in three separate places precisely because each of them had its
    /// own hardcoded "jpg", and fixing one left the others wrong.
    static let knownExtensions = ["jpg", "m4a"]

    // MARK: - Resolved-kind cache

    /// Which extension an id's file was last FOUND under.
    ///
    /// `existingFileURL` is a `FileManager.fileExists` loop, and the journal
    /// feed asks it constantly: `JournalEntryCard` calls `isVoiceNote` for
    /// every attachment twice (once to find a photo, once to ask whether any
    /// voice note exists), `JournalListView` does the same again for its own
    /// row, and all of it runs inside a `ForEach`, per card, per body
    /// evaluation. Four to nine syscalls per card per pass, for an answer that
    /// changes only when a file is written, moved or deleted.
    ///
    /// **POSITIVE RESULTS ONLY.** A miss is never remembered, and that
    /// asymmetry is the entire safety argument. A cached "it is a .m4a" can
    /// only become wrong if that file is deleted or moved, and after this
    /// change every path that deletes or moves one goes through this type and
    /// invalidates (`save`, `restore`, `delete`, `deleteAudio`, `moveAudio`).
    /// A cached "there is nothing here" could become wrong the moment a file
    /// ARRIVES -- which is exactly what `AutoRestoreService
    /// .downloadPendingAttachments` does, on a background pass, for rows it
    /// found empty -- and a stale negative would render a real voice note as a
    /// broken photo forever. So a missing file simply costs what it always
    /// cost. The expensive case is the common one (a photo or a note that is
    /// actually there); the uncached case is the rare one.
    ///
    /// The lock is real, not decorative: `existingFileURL` is called from view
    /// bodies on the main actor AND from `AutoBackupService`/
    /// `JournalAutoExportService`/`AutoRestoreService`, which are not
    /// guaranteed to be.
    private nonisolated(unsafe) static var resolvedExtensions: [UUID: String] = [:]
    private static let cacheLock = NSLock()

    private static func cachedExtension(for id: UUID) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return resolvedExtensions[id]
    }

    private static func cache(_ ext: String, for id: UUID) {
        cacheLock.lock()
        resolvedExtensions[id] = ext
        cacheLock.unlock()
    }

    /// Called by EVERY path in this file that writes, moves or removes a file.
    /// Adding a new one without calling this is the way a voice note goes
    /// silently unplayable, so the mutating functions below are the only
    /// sanctioned way to touch this directory from outside.
    private static func invalidate(_ id: UUID) {
        cacheLock.lock()
        resolvedExtensions.removeValue(forKey: id)
        cacheLock.unlock()
    }

    /// The file actually on disk for this id, image or audio.
    static func existingFileURL(for id: UUID) -> URL? {
        if let ext = cachedExtension(for: id) {
            return directory.appendingPathComponent(id.uuidString + "." + ext)
        }
        for ext in knownExtensions {
            let url = directory.appendingPathComponent(id.uuidString + "." + ext)
            if FileManager.default.fileExists(atPath: url.path) {
                cache(ext, for: id)
                return url
            }
        }
        // Deliberately NOT cached -- see `resolvedExtensions`.
        return nil
    }

    /// Whether this attachment is a voice note rather than a photo -- the view
    /// layer needs to know which control to render for it.
    static func isVoiceNote(id: UUID) -> Bool {
        existingFileURL(for: id)?.pathExtension == "m4a"
    }

    /// Removes a voice note's file, cache included.
    ///
    /// Exists so `JournalEntryComposeView.cancelPendingVoiceNotes` and
    /// `JournalVoiceRecorder.cancel` stop reaching past this type with a bare
    /// `FileManager.removeItem`. They were the reason a cache could not safely
    /// exist here at all; routing them through the store is what makes it safe,
    /// not a comment asking future callers to remember.
    static func deleteAudio(id: UUID) {
        try? FileManager.default.removeItem(at: audioURL(for: id))
        invalidate(id)
    }

    /// Moves a recording from its staging id onto the attachment row's real id.
    ///
    /// The compose view did this with `FileManager.moveItem` directly. Both
    /// ids are invalidated: the source's file is gone, and the destination's
    /// has just appeared.
    @discardableResult
    static func moveAudio(from stagingID: UUID, to attachmentID: UUID) -> Bool {
        defer {
            invalidate(stagingID)
            invalidate(attachmentID)
        }
        do {
            try FileManager.default.moveItem(at: audioURL(for: stagingID),
                                             to: audioURL(for: attachmentID))
            return true
        } catch {
            return false
        }
    }

    /// Writes bytes to disk exactly as given, with no downsample/re-encode --
    /// for `BackupService.importData` restoring a backup's own
    /// `PersonalWritingEntryDTO.attachments`, which are already the output of
    /// `save(_:id:maxPixelDimension:)` below from whenever the backup was
    /// taken. Running restored bytes back through `save` would decode and
    /// re-JPEG-encode data that's already processed, for no benefit and a
    /// second generation of lossy compression.
    static func restore(_ data: Data, id: UUID) {
        // Sniff the bytes rather than assuming JPEG. This wrote everything to
        // `<id>.jpg` unconditionally, so a restored voice note came back with a
        // .jpg extension and was unplayable -- the backup would have looked
        // complete while quietly destroying the recording on the way back in.
        try? data.write(to: isM4A(data) ? audioURL(for: id) : localFileURL(for: id))
        // A file has just appeared, and this is the one path that can write
        // EITHER kind for the same id -- so a previously resolved extension
        // must not survive it.
        invalidate(id)
    }

    /// MPEG-4 audio carries an `ftyp` box at byte offset 4; JPEG starts FF D8.
    /// Checking the container rather than trusting a filename means restore
    /// stays correct even for a backup written before voice notes existed.
    private static func isM4A(_ data: Data) -> Bool {
        guard data.count > 8 else { return false }
        return data[4..<8].elementsEqual([0x66, 0x74, 0x79, 0x70])
    }

    /// 900, not 300.
    ///
    /// A journal card spans nearly the full screen width — roughly 350pt, which
    /// is ~1,050 physical pixels on a 3x phone. A 300px thumbnail stretched
    /// across that is being magnified more than threefold, which is exactly the
    /// "really compressed" look Rajan reported: soft in the card, perfect when
    /// tapped, because the detail view reads the full image instead.
    ///
    /// 900 is still a thumbnail — a fraction of the 1600px stored original —
    /// but it is sharp at card width on every current iPhone.
    private static let thumbnailMaxPixelDimension: CGFloat = 900

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
            invalidate(id)
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
        // Voice notes too -- deleting an entry used to leave its recording
        // orphaned on disk forever, the same class of leak this function's own
        // doc comment already warns about for images.
        try? FileManager.default.removeItem(at: audioURL(for: id))
        invalidate(id)
    }

    /// A small DISPLAY image straight from picker bytes, for the composer's
    /// 72pt strip while a photo is still pending -- the one ImageIO path this
    /// file already trusts for its stored tiers, exposed so `PhotoLoader` can
    /// build previews without a second implementation.
    ///
    /// Exists because the composer used to hold `UIImage(data:)` of the RAW
    /// picker bytes for every pending photo: a 48MP HEIC decodes to ~190 MB,
    /// so ten picks was on the order of 1.9 GB of full-resolution bitmaps,
    /// decoded on the main thread and retained until save, to draw ten
    /// 72×72 tiles. `CGImageSourceCreateThumbnailAtIndex` never inflates the
    /// full bitmap -- it decodes straight to the target size. Safe off-main:
    /// no shared state, pure function of its input.
    static func preview(from data: Data, maxPixelDimension: CGFloat) -> UIImage? {
        downsampled(from: data, maxPixelDimension: maxPixelDimension)
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
