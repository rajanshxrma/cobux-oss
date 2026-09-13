import UIKit
import ImageIO
import UniformTypeIdentifiers
import SwiftData

/// Where chat images live, and the cost strategy that makes vision affordable.
///
/// Images are downscaled AT ATTACH TIME to the Anthropic vision sweet spot --
/// a long edge of 1024pt covers virtually every real question about a photo
/// while costing a fraction of a full-resolution upload's tokens. JPEG 0.72
/// halves the bytes again with no visible loss at chat sizes. The original
/// never leaves the device; only the downscaled copy is stored or sent.
///
/// Files by UUID under Application Support/ChatImages — the same regenerable-
/// artifact root convention as drafts and volumes. `ChatMessage.imageIDs`
/// (additive) references them. Nothing else does, so the rows are the ONLY
/// record of which files belong to which thread -- which is why deleting a
/// thread's rows without first sweeping its files leaked every attached photo
/// forever: `prune` had been written and never called, and Clear Chat plus
/// both situation-delete paths batch-deleted rows and left the JPEGs behind.
/// For a situation thread that is the exact record ("photos of a real person
/// after he chose to end it") the feature promises not to keep.
///
/// Two mechanisms now, both required:
/// - `removeImages(inThread:context:)` -- every thread delete calls this
///   FIRST, while the rows still exist to say which files are theirs.
/// - `pruneOrphans(context:keeping:)` -- once per launch, the backstop for any
///   file the sweep could not have known about (a crash between the two
///   steps, a bounded sweep on a pathological thread, files from builds that
///   predate the sweep).
///
/// Decoding: `CGImageSourceCreateThumbnailAtIndex` everywhere, never
/// `UIImage(data:)` of the original. A 12-48MP camera photo decoded in full is
/// 50-200 MB of bitmap; ImageIO decodes straight to the target size and never
/// inflates the original. Decoded thumbnails are cached, so a bubble or the
/// composer strip stops re-reading disk and re-decoding on every body
/// evaluation -- which, with the composer re-rendering per keystroke, was a
/// disk read plus a JPEG decode per staged image per character typed.
enum ChatImageStore {
    static let maxImagesPerMessage = 3
    static let maxLongEdge: CGFloat = 1024
    static let jpegQuality: CGFloat = 0.72

    /// Files older than this are eligible for the launch prune. A photo staged
    /// seconds ago is referenced by no row yet (the message that will own it
    /// has not been sent), and the moment between `save` returning off-main
    /// and the id landing in the composer's strip is exactly that shape too.
    /// One hour is long past any real composing session and still catches
    /// everything from earlier launches.
    private static let pruneGracePeriod: TimeInterval = 60 * 60

    // `static let` with a closure initializer runs exactly once per process,
    // lazily, thread-safely -- the same fix `CoverImageCache` and
    // `JournalAttachmentStore` already carry. The `static var` computed
    // property this replaces ran `createDirectory` (a real syscall) on every
    // save AND every prune listing.
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ChatImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Decoded thumbnails by id. `NSCache` is thread-safe by contract (hence
    /// `nonisolated(unsafe)`, the codebase's idiom for exactly this), evicts
    /// under memory pressure on its own, and is cost-bounded here in bytes of
    /// bitmap rather than in images -- three 1024x768 decodes cost what one
    /// square one does, and the limit should say so.
    nonisolated(unsafe) private static let decoded: NSCache<NSUUID, UIImage> = {
        let cache = NSCache<NSUUID, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    private static func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).jpg")
    }

    /// Downscales and stores. Returns nil (never throws into the UI) when the
    /// data isn't an image or the write fails -- the composer simply doesn't
    /// add a chip, matching how every other attach path degrades.
    ///
    /// Safe off-main, and meant to be called there: no shared state beyond
    /// the thread-safe cache, a pure function of its input otherwise. The
    /// caller (`ChatView`'s picker handler) runs it inside `Task.detached`
    /// because a SwiftUI `Task {}` inherits the main actor and would have
    /// done all of this under his thumb.
    @discardableResult
    static func save(_ imageData: Data) -> UUID? {
        guard let transcoded = transcode(imageData) else { return nil }
        let id = UUID()
        do {
            try transcoded.jpeg.write(to: url(for: id), options: .atomic)
        } catch {
            return nil
        }
        // The bitmap is already decoded at display size -- seeding the cache
        // with it makes the composer strip's first body evaluation free.
        cache(transcoded.image, for: id)
        return id
    }

    /// The stored JPEG bytes, for the API request. Deliberately NOT cached or
    /// decoded: the request wants the bytes as written.
    static func imageData(for id: UUID) -> Data? {
        try? Data(contentsOf: url(for: id))
    }

    /// The decoded image for display. Cache first; on a miss, an ImageIO
    /// decode of the stored (already <=1024) file, then cached. Called from
    /// view bodies, so the miss path is the only disk touch and happens once
    /// per image per process, not once per evaluation.
    static func image(for id: UUID) -> UIImage? {
        if let cached = decoded.object(forKey: id as NSUUID) { return cached }
        guard let data = imageData(for: id),
              let cgImage = downsampledCGImage(from: data) else { return nil }
        return cache(cgImage, for: id)
    }

    static func remove(_ id: UUID) {
        decoded.removeObject(forKey: id as NSUUID)
        try? FileManager.default.removeItem(at: url(for: id))
    }

    static func remove<S: Sequence>(_ ids: S) where S.Element == UUID {
        for id in ids { remove(id) }
    }

    /// Removes every image attached to a thread's messages. Call BEFORE the
    /// thread's rows are deleted: the rows are the only record of which files
    /// are theirs, so files-then-rows is the only order that works.
    ///
    /// Bounded, and `propertiesToFetch` keeps every row to its `imageIDs`
    /// column -- no content, no embedding blob -- so a thread with years of
    /// history costs a single light query. The bound is 10x the deepest
    /// thread anyone has; whatever a pathological thread leaves past it is
    /// exactly what `pruneOrphans` exists to catch.
    ///
    /// Main actor because it reads SwiftData models (the documented Build-5
    /// crash class otherwise); the file removals themselves are cheap unlinks.
    @MainActor
    static func removeImages(inThread threadID: UUID?, context: ModelContext) {
        var descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate<ChatMessage> { $0.bookID == threadID })
        descriptor.propertiesToFetch = [\.imageIDs]
        descriptor.includePendingChanges = true
        descriptor.fetchLimit = 4000
        let rows = (try? context.fetch(descriptor)) ?? []
        for row in rows {
            remove(row.imageIDs ?? [])
        }
    }

    @MainActor private static var didPruneThisLaunch = false

    /// Once per launch: removes every stored image no message references.
    ///
    /// The reference set is gathered COMPLETE (no fetch limit) on purpose: a
    /// bounded fetch here would miss references and delete photos that are
    /// still in his transcript, which is worse than the leak. `keeping` is the
    /// composer's staged ids -- referenced by no row until their message is
    /// sent -- and the grace period covers the same window for anything the
    /// caller could not name. The fetch is one light query on the main actor
    /// (models); the directory walk and the unlinks run detached.
    @MainActor
    static func pruneOrphans(context: ModelContext, keeping staged: [UUID]) {
        guard !didPruneThisLaunch else { return }
        didPruneThisLaunch = true

        var descriptor = FetchDescriptor<ChatMessage>()
        descriptor.propertiesToFetch = [\.imageIDs]
        descriptor.includePendingChanges = true
        guard let rows = try? context.fetch(descriptor) else {
            // A failed fetch means an UNKNOWN reference set -- never prune
            // against one. Next launch tries again.
            didPruneThisLaunch = false
            return
        }
        var referenced = Set(staged)
        for row in rows {
            for id in row.imageIDs ?? [] { referenced.insert(id) }
        }
        let cutoff = Date().addingTimeInterval(-pruneGracePeriod)
        Task.detached(priority: .utility) {
            prune(referencedIDs: referenced, modifiedBefore: cutoff)
        }
    }

    /// Removes any stored image no live message references, leaving recently
    /// written files alone (see `pruneGracePeriod`). Pure filesystem work;
    /// safe on any thread.
    private static func prune(referencedIDs: Set<UUID>, modifiedBefore cutoff: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "jpg" {
            let name = file.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: name), !referencedIDs.contains(id) else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard modified < cutoff else { continue }
            decoded.removeObject(forKey: id as NSUUID)
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Decoding

    @discardableResult
    private static func cache(_ cgImage: CGImage, for id: UUID) -> UIImage {
        let image = UIImage(cgImage: cgImage)
        decoded.setObject(image, forKey: id as NSUUID, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    /// Decodes straight to at most `maxLongEdge` on the long side -- never
    /// the full bitmap -- with EXIF orientation baked in, so the stored copy
    /// needs no orientation metadata and displays upright everywhere. A
    /// smaller input is returned at its own size: ImageIO's max pixel size
    /// is a cap, not a target, so nothing is ever upscaled.
    private static func downsampledCGImage(from data: Data) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
    }

    /// The downscaled JPEG bytes plus the decoded bitmap they were made from,
    /// so `save` can write one and cache the other without a second decode.
    private static func transcode(_ data: Data) -> (jpeg: Data, image: CGImage)? {
        guard let cgImage = downsampledCGImage(from: data) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage,
                                   [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (out as Data, cgImage)
    }
}
