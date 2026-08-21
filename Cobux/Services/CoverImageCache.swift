import UIKit

/// Persists downloaded book cover images to disk, keyed by `Book.id`.
///
/// Every seeded book ships with a real remote `coverImageURL` (openlibrary.org/
/// goodreads static images), and every cover-rendering call site (`BookCard`,
/// `BookDetailView`) used to fetch it lazily via `AsyncImage` on whatever
/// render happened to need it first, relying on `URLCache.shared`'s ordinary
/// HTTP cache -- which is capacity-bounded, can be evicted under disk
/// pressure, and isn't fetched at all until some view actually renders that
/// URL. A fresh install that goes offline (airplane mode, dead zone) before
/// ever opening a book screen shows the gradient fallback for every cover,
/// even though the whole point of `coverImageURL` is a real cover image --
/// exactly the "thumbnails... look weird" report this fixes.
///
/// This cache is deliberately proactive, not just a nicer lazy-load: seeding
/// (`CobuxApp.swift`) kicks off a background download for every seeded book's
/// cover right after seeding completes, so covers are already on disk before
/// the user ever opens Library for the first time. Lazy fallback (download
/// on first render) still exists for books added later (e.g. added by hand
/// in Library), so nothing regresses to "never cached" for those.
enum CoverImageCache {
    // `static let` with a closure initializer runs exactly once per process,
    // lazily, thread-safely -- unlike the `static var` computed property this
    // replaces, which re-ran `createDirectory` (a real filesystem syscall) on
    // every single cover render, not just the first.
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("CoverImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func localFileURL(for bookID: UUID) -> URL {
        directory.appendingPathComponent(bookID.uuidString + ".img")
    }

    /// Sweeps cache files left behind by a book that no longer exists --
    /// `CobuxApp.dedupeDuplicateBooks` deletes duplicate `Book` rows but has
    /// no reason to know about (or reach into) this cache, so a deleted
    /// duplicate's cover file was orphaned forever until now. Cheap and
    /// idempotent: safe to call on every launch alongside the dedup pass it
    /// follows.
    static func pruneOrphans(validBookIDs: Set<UUID>) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            guard let bookID = UUID(uuidString: name), !validBookIDs.contains(bookID) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Synchronous, cheap local-disk read -- no network involved, safe to call
    /// from a view body's `.task` without an await first.
    static func cachedImage(for bookID: UUID) -> UIImage? {
        guard let data = try? Data(contentsOf: localFileURL(for: bookID)) else { return nil }
        return UIImage(data: data)
    }

    /// Downloads `remoteURL` and writes it to disk keyed by `bookID`. Safe to
    /// call unconditionally -- overwrites if already cached, and silently
    /// returns nil on any failure (no connection, bad URL, decode failure)
    /// rather than throwing, since every call site already has the gradient
    /// fallback for "no cover available."
    @discardableResult
    static func downloadAndCache(bookID: UUID, remoteURL: URL) async -> UIImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: remoteURL),
              let image = UIImage(data: data) else { return nil }
        try? data.write(to: localFileURL(for: bookID))
        return image
    }
}
