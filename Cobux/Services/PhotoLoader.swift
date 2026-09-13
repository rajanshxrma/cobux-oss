import SwiftUI
import PhotosUI

/// Loads picker selections the way a shipping app has to: concurrently, with
/// a per-item timeout, in selection order.
///
/// `loadTransferable(type: Data.self)` can take arbitrarily long -- or never
/// return -- for an iCloud-offloaded original on a slow connection. The old
/// sequential loop meant ONE such item wedged the whole batch with no
/// feedback: "images are not getting attached, still shows loading." Reported
/// live from build 51, with the limited-access photo sheet spinning forever.
///
/// Rules:
/// - every item races a timeout; a timeout is a visible failure, never a hang
/// - items load concurrently, so a wedged item cannot block the others
/// - results return in SELECTION order regardless of completion order
/// - a display preview, when asked for, is built HERE, off the main thread,
///   at the size it will be drawn -- never by decoding the original later
enum PhotoLoader {
    static let timeout: Duration = .seconds(20)

    /// One loaded pick: the original bytes (what gets saved) and, when the
    /// caller asked for one, a small preview (what gets drawn). Kept apart on
    /// purpose -- the composer showed 72pt tiles by holding `UIImage(data:)`
    /// of the raw original for every pending photo, which on a modern iPhone
    /// is a ~190 MB bitmap per 48MP HEIC, decoded on the main thread and
    /// retained until save. The preview is a few hundred KB.
    struct LoadedPhoto {
        let data: Data
        let preview: UIImage?
    }

    private struct Loaded {
        let index: Int
        let photo: LoadedPhoto
    }

    /// Data for each loadable item, selection-ordered; `failures` counts
    /// items that could not be read or timed out. Bytes only -- chat's
    /// picker writes them straight to `ChatImageStore` and never displays
    /// the original, so it has no use for a preview.
    static func load(_ items: [PhotosPickerItem]) async -> (loaded: [Data], failures: Int) {
        let result = await loadWithPreviews(items, previewMaxPixelSize: nil)
        return (result.loaded.map(\.data), result.failures)
    }

    /// Same contract as `load(_:)`, plus a preview per photo decoded to at
    /// most `previewMaxPixelSize` on its long edge -- inside the same
    /// concurrent task group, so the decode happens off-main, alongside the
    /// download, before anything reaches a view. `nil` skips the preview.
    static func loadWithPreviews(
        _ items: [PhotosPickerItem],
        previewMaxPixelSize: CGFloat?
    ) async -> (loaded: [LoadedPhoto], failures: Int) {
        await withTaskGroup(of: Loaded?.self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    let data = await withTimeout {
                        try? await item.loadTransferable(type: Data.self)
                    }
                    guard let data = data ?? nil else { return nil }
                    // ImageIO thumbnailing reads straight to the target size
                    // and never materialises the full bitmap -- see
                    // `JournalAttachmentStore.preview(from:maxPixelDimension:)`.
                    let preview = previewMaxPixelSize.flatMap {
                        JournalAttachmentStore.preview(from: data, maxPixelDimension: $0)
                    }
                    return Loaded(index: index, photo: LoadedPhoto(data: data, preview: preview))
                }
            }
            var results: [Loaded] = []
            for await result in group {
                if let result { results.append(result) }
            }
            let ordered = results.sorted { $0.index < $1.index }.map(\.photo)
            return (ordered, items.count - ordered.count)
        }
    }

    /// Races `operation` against the timeout. A photo that needs longer than
    /// this is still downloading from iCloud -- tell him that, do not hang.
    ///
    /// The loser is ABANDONED, not awaited, and that is the whole point.
    ///
    /// This was a `withTaskGroup` with the load in one child and the sleep in
    /// the other, taking `group.next()` and calling `cancelAll()` -- the
    /// textbook shape, and it does not bound anything. A task group cannot
    /// return until every child has finished, and cancellation is cooperative:
    /// nothing promises `loadTransferable` checks `Task.isCancelled`, and if
    /// it does not, the group -- and this function, and the alert it exists to
    /// raise -- waits exactly as long as the load does. A twenty-second
    /// timeout that expires into a wait is not a timeout. Two unstructured
    /// tasks and a first-past-the-post box are what actually make the deadline
    /// real; the cost is one in-flight download whose result nobody reads.
    private static func withTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        let race = Race<T>()
        let work = Task(priority: .userInitiated) { await race.settle(await operation()) }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            await race.settle(nil)
        }
        let result = await race.wait()
        // Still asked to stop, so a well-behaved loader releases immediately.
        work.cancel()
        timer.cancel()
        return result
    }
}

/// Whichever of the load and its deadline finishes first, once.
///
/// An actor rather than a task group precisely because a group waits for its
/// children -- see `PhotoLoader.withTimeout`. A late `settle` from the loser
/// is a no-op, and a value that arrives before anyone is waiting is held for
/// the waiter that follows.
private actor Race<T: Sendable> {
    /// `.some` once settled -- the inner optional is the real answer (nil
    /// meaning "timed out or unreadable"), so the outer one has to exist to
    /// tell "settled with nothing" from "not settled yet".
    private var settled: T??
    private var waiter: CheckedContinuation<T?, Never>?

    func settle(_ value: T?) {
        guard settled == nil else { return }
        settled = .some(value)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: value)
        }
    }

    func wait() async -> T? {
        if let settled { return settled }
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            waiter = continuation
        }
    }
}
