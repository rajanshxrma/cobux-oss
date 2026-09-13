import UIKit
import ImageIO

/// Resolves a `Figure.fileName` to its bundled image, mirroring `SeedLoader`'s bundle-lookup
/// pattern. `Cobux/Resources/Figures/` now holds the real extracted images (1,597 of them).
enum FigureImageLoader {
    /// Takes the file NAME, never the `Figure` row. This used to take the
    /// model and read `figure.fileName` in its own first line -- but this is a
    /// nonisolated `async` function, and under this project's Swift 5.9
    /// language mode SE-0338 runs such a body on the generic executor rather
    /// than the caller's, so that read happened off the main actor that owns
    /// the fetched row: the same undefined behaviour, and the same
    /// intermittent `EXC_BAD_ACCESS`, that `SpotlightIndexer`'s section
    /// comment describes. A `String` is a plain value and crosses executors
    /// fine, so the read now happens on the `@MainActor` caller, where the row
    /// actually lives.
    ///
    /// `async`, not a plain sync function returning `UIImage?` directly: the disk read +
    /// JPEG decode below are genuinely blocking work, and every call site (`MessageBubbleView`,
    /// `FigureIDView`) runs on `@MainActor`. Without the `Task.detached` hop, calling this from
    /// a chat bubble's `.task` would still execute the blocking I/O ON the main thread despite
    /// the `await` keyword being present at the call site -- an `async` signature alone doesn't
    /// move work off the calling actor unless something inside actually hops. Matters here
    /// because chat bubbles render inside a `LazyVStack`, which re-creates bubble state (and
    /// re-triggers this load) every time a figure-bearing reply scrolls back into view -- a
    /// synchronous decode on every one of those would show up as real scroll stutter.
    static func image(fileName: String) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let url = Bundle.main.url(forResource: fileName, withExtension: nil, subdirectory: "Figures")
                    ?? Bundle.main.url(forResource: (fileName as NSString).deletingPathExtension, withExtension: (fileName as NSString).pathExtension, subdirectory: "Figures") else {
                return nil
            }
            return downsampled(at: url, maxPixelDimension: 800)
        }.value
    }

    /// ImageIO thumbnail decode instead of `UIImage(data:)`: a chat thread's
    /// `LazyVStack` retains each figure-bearing bubble's decoded image for
    /// every row scrolled past, so on a 4GB device a long study session can
    /// accumulate toward a jetsam kill. Decoding straight to display size
    /// (~800px covers the widest bubble on any current phone at 2-3x) caps
    /// each retained image at a fraction of a full decode, and never holds
    /// the original bitmap in memory at all.
    private static func downsampled(at url: URL, maxPixelDimension: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
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
