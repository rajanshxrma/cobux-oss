import SwiftUI
import SwiftData
import UIKit

struct BookCard: View {
    let book: Book

    // Crash root cause (build 5, confirmed against a real device .ips):
    // `book.highlights.count` faults SwiftData's entire to-many relationship
    // synchronously, inside this view's body, during LibraryView's LazyVGrid
    // layout pass. On a fresh launch that fault can land at the exact moment
    // CobuxApp's background seeding context is merging a large transaction
    // (1,597 new Figure inserts, an id-repair pass across 8 model types) into
    // the main context -- SwiftData asserts trying to resolve the relationship
    // members mid-merge, and the app dies ~2.6s after launch. A `fetchCount`
    // query does a SQL COUNT against the store instead of materializing/
    // faulting the relationship's member objects, so it can't hit this fault
    // at all -- and running it from `.task` (after the card has already laid
    // out) rather than synchronously in `body` keeps it off the render path
    // that raced the background merge in the first place.
    @Environment(\.modelContext) private var modelContext
    @State private var highlightCount: Int = 0
    @State private var coverImage: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            coverBackground

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 4) {
                    BookTitleText(
                        title: book.title,
                        font: .headline,
                        weight: .bold,
                        color: .white,
                        lineLimit: 2,
                        expandsWidth: true
                    )
                    // Same guard `BookDetailView`'s hero title already has (see
                    // its `heroHeight`/`minimumScaleFactor` comment) -- without
                    // it, a long title at a large Dynamic Type accessibility
                    // size has nowhere to grow inside this fixed-aspect-ratio
                    // card (unlike the hero, which is free to grow the whole
                    // screen) and its second line gets clipped mid-character by
                    // this view's `.clipShape` instead of shrinking to fit.
                    .minimumScaleFactor(0.75)

                    Text(book.author)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)

                    if highlightCount > 0 {
                        Text("\(highlightCount) highlights")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.3))
                            .clipShape(Capsule())
                            .foregroundStyle(.white)
                            .padding(.top, 4)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.7), .clear],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
            }
        }
        .aspectRatio(3/4, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: CobuxRadius.card))
        // The shadow is cast by a plain rounded rectangle behind the card, not
        // by the card itself. Same geometry, same colour, same result on
        // screen -- the card's content is opaque edge to edge (a cover fills
        // the frame, and the gradient fallback is opaque too), so this shape is
        // never visible, only its spill.
        //
        // The reason is what Core Animation has to do to draw it. A `.shadow`
        // on composited content has no known silhouette, so CA renders that
        // content to an offscreen buffer, derives its alpha mask, and blurs
        // that -- per card, per frame. A shadow cast by a *shape* has a path CA
        // can use directly. And this grid applies `.scrollTransition` with a
        // `.scaleEffect` (LibraryView), so the transform changes every frame
        // while a finger is moving, which invalidates any cached rasterisation
        // the offscreen pass might otherwise have been reused from. Every
        // visible card was paying that offscreen pass on every frame of every
        // scroll.
        //
        // The shadow is the book's own ink, not flat black (beauty checklist,
        // Library 2). Every card used to cast the same grey regardless of
        // what was on it -- generic chrome under content that carries its own
        // hue everywhere else in this app (the spine in `BookListRow` and
        // `QuizBookRow`, the gradient fallback, all from this same
        // `coverColorHex`). Now a crimson cover casts crimson and an ochre
        // one ochre, so a scroll past four books reads as four books rather
        // than four tiles. Two guards keep it a shadow and not a glow: the
        // hue is pulled 40 % toward black first, so a near-white cover
        // (`#FEE9BC`, the palest seed) still separates from the light
        // ground instead of vanishing into it; and the opacity rises to
        // compensate for the ink being lighter than black. Measured in
        // `check-contrast.py`'s own arithmetic, shadow-over-ground against
        // the light Background: the old black at 0.2 was 1.60:1 under every
        // card; this is 1.44:1 under the palest seed cover, 1.99:1 at the
        // median and 2.4:1 under a near-black one -- above the 1.3:1 the
        // gate's rule 2 calls "visibly distinct" for every cover on the
        // shelf, and darker than before for most. In dark it is the faintest
        // lift of the cover's own hue off the near-black ground (1.0-1.7:1),
        // where the old black shadow was 1.01:1 -- invisible. Same shape,
        // same path-based shadow, same single blur per card -- the cost is
        // identical, only the colour changed.
        .background {
            RoundedRectangle(cornerRadius: CobuxRadius.card)
                .fill(Color.black)
                .shadow(color: Color(hex: book.coverColorHex).mix(with: .black, by: 0.4).opacity(0.36),
                        radius: 6, x: 0, y: 3)
        }
        .task(id: book.id) {
            await loadHighlightCount()
            await loadCoverImage()
        }
    }

    // `.persistentModelID` traversal inside `#Predicate` has known macro-support
    // quirks across SDK versions -- `Book.id` is a stable stored `UUID`
    // (Book.swift), so keying the count query off that is the safer, well-
    // supported pattern rather than the relationship's persistent identifier.
    @MainActor
    private func loadHighlightCount() async {
        let targetBookID = book.id
        let descriptor = FetchDescriptor<Highlight>(
            predicate: #Predicate<Highlight> { $0.book?.id == targetBookID }
        )
        highlightCount = (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    // Resolution order, single source of truth (matches `BookDetailView`):
    // bundled `Assets.xcassets` cover (every seed book) -> the on-device
    // remote-fetch cache (a book added by hand, the only case that still has
    // a `coverImageURL` with no `coverAssetName`) -> the gradient. Unchanged.
    //
    // What changed is that the bundled tier now renders from a downsampled
    // process cache (`BookCoverThumbnails`) rather than straight from
    // `UIImage(named:)`. It still paints on the card's first frame whenever
    // that cache is warm -- which was the property the previous version of
    // this comment was defending -- and the first sight of a given cover in a
    // process now costs a downsample on a background task instead of a
    // full-resolution decode under his thumb. `BookDetailView` deliberately
    // keeps the full-resolution path: it shows one cover at hero size, not a
    // scrolling grid of them.
    @ViewBuilder
    private var coverBackground: some View {
        // `UIImage(named:)` used to be called RIGHT HERE, in `body`.
        //
        // It looks free, and on a warm UIKit cache it nearly is. The problem is
        // what it returns and how often the cache is warm. These 158 bundled
        // covers are shipped at their source resolution: 67 of them are wider
        // than 600px and 38 decode to more than 5MB of bitmap each, the largest
        // being 1400x2100 -- 11.2MB decoded, for a card that is about 196pt
        // wide (roughly 590px on his phone). Resident all at once they would be
        // 587MB, so UIKit's own image cache is under constant pressure while
        // this grid scrolls and purges aggressively. Every purge turns the next
        // `body` evaluation of that card into a full-resolution JPEG decode on
        // the main thread, mid-scroll.
        //
        // So `body` now only ever does a cache lookup -- a dictionary read, no
        // decode, cheap enough for a view body by the same argument
        // `ChatImageStore.image(for:)` already makes for its own. Both tiers
        // keep rendering on the first frame whenever the cover is warm, which
        // is what the previous version of this comment was protecting; the
        // difference is that warming it now costs a downsampled 1.7MB off the
        // main thread instead of 11.2MB on it.
        //
        // `Cover-<slug>` is the real imageset name (see `Book.coverAssetName`'s
        // doc comment) -- `coverAssetName` itself only ever stores the bare
        // slug. A prior version of this code looked up the bare slug directly
        // and got nil back for all 26 seed books, silently falling to the
        // gradient tier every time; the prefix has to be added here.
        if let coverImage {
            Image(uiImage: coverImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let assetName = book.coverAssetName,
                  let warm = BookCoverThumbnails.cached(assetName: assetName) {
            Image(uiImage: warm)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            CoverGradientView(colorHex: book.coverColorHex)
        }
    }

    // On-device cache, not `AsyncImage` (2.2.0 offline resilience): a cache
    // hit renders instantly from disk with no network dependency at all,
    // which is what makes this offline-safe -- see `CoverImageCache`'s doc
    // comment for why `AsyncImage` + `URLCache` wasn't actually reliable here.
    //
    // Skipped only when the bundled asset genuinely resolves -- checking
    // `coverAssetName != nil` alone (the previous guard here) skipped this
    // unconditionally the moment the field was set, even on a build where
    // `UIImage(named:)` failed to find it (exactly what the missing-prefix
    // bug this comment sits next to did to all 26 seed books). A
    // `coverAssetName` that doesn't actually resolve must fall through to
    // this remote/cache path instead of dead-ending at a blank gradient.
    @MainActor
    private func loadCoverImage() async {
        if let assetName = book.coverAssetName {
            // Off the main thread: the asset-catalog decode and the downsample
            // are exactly the work a scrolling grid must not do on the thread
            // that scrolls it -- the same reasoning, and the same shape, as
            // `JournalThumbnailImage`. A hit on the process cache returns
            // without touching the decoder at all.
            if let thumbnail = await Task.detached(priority: .userInitiated, operation: {
                BookCoverThumbnails.thumbnail(assetName: assetName)
            }).value {
                coverImage = thumbnail
                return
            }
            // Falls through deliberately when the imageset does not actually
            // resolve. Checking `coverAssetName != nil` alone (the guard that
            // used to be here) skipped the remote path unconditionally the
            // moment the field was set, even on a build where the lookup
            // failed -- exactly what the missing-prefix bug did to all 26 seed
            // books, leaving them dead-ended on a blank gradient.
        }
        if let cached = CoverImageCache.cachedImage(for: book.id) {
            coverImage = cached
            return
        }
        guard let urlString = book.coverImageURL, let url = URL(string: urlString) else { return }
        coverImage = await CoverImageCache.downloadAndCache(bookID: book.id, remoteURL: url)
    }
}

/// Display-size bitmaps for the bundled cover imagesets, decoded once per
/// process and held in a cost-bounded cache.
///
/// Lives here rather than in `Services/` only because this project lists every
/// source file individually in `project.pbxproj` (no synchronised folder
/// groups), so a brand-new file would not join the target without a project
/// edit. `BookCard` is its sole caller.
///
/// The covers ship at source resolution -- up to 1400x2100, 11.2MB of bitmap
/// each, against a card roughly 590px wide on a Pro Max. Handing the GPU an
/// 11MB texture to sample into a 590px box is waste on every frame, and holding
/// enough of them to fill a scrolling grid is what keeps UIKit's own image
/// cache thrashing. This is the pattern `ChatImageStore` and
/// `JournalAttachmentStore` already established for images in scrolling
/// surfaces, applied to the one image surface that never got it.
enum BookCoverThumbnails {
    /// Longest edge, in pixels, of a stored thumbnail.
    ///
    /// The grid is `GridItem(.adaptive(minimum: 160))` inside 16pt padding, so
    /// on his iPhone 17 Pro Max it lays out two columns of about 196pt; at 3x
    /// that is ~590px wide and ~785px tall for the 3:4 card. 800 covers the
    /// tall edge with a little room and still never upscales a small cover.
    private static let maxPixelEdge: CGFloat = 800

    /// `NSCache` is thread-safe by contract (hence `nonisolated(unsafe)`, this
    /// codebase's idiom for exactly this), evicts under memory pressure on its
    /// own, and is bounded in bytes of bitmap rather than in images -- the
    /// covers vary enough in aspect ratio that a count limit would mean
    /// something different for each one.
    nonisolated(unsafe) private static let decoded: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    /// Cache-only lookup: a dictionary read, no decode, no disk. Safe to call
    /// from a view body, which is the point -- a warm cover still renders on
    /// the card's very first frame.
    static func cached(assetName: String) -> UIImage? {
        decoded.object(forKey: assetName as NSString)
    }

    /// The full path: cache, else decode the imageset and downsample it, then
    /// cache. Safe off the main actor and meant to be called there -- it
    /// touches no shared state beyond the thread-safe cache and no `@Model`
    /// row. Returns nil only when the imageset genuinely does not resolve, so
    /// the caller can fall through to its remote/gradient tiers.
    static func thumbnail(assetName: String) -> UIImage? {
        if let hit = cached(assetName: assetName) { return hit }
        guard let full = UIImage(named: "Cover-" + assetName) else { return nil }

        let size = full.size
        guard size.width > 0, size.height > 0 else { return nil }
        // Aspect ratio is preserved rather than forced to a fixed box: the
        // covers run from 0.56 to 0.68 wide-over-tall, and the card renders
        // them `.aspectRatio(contentMode: .fill)` inside a 3:4 clip. Distorting
        // them here would make that fill crop the wrong part of the art.
        // `min(..., 1)` so a cover already smaller than the tier is stored as
        // it is and never upscaled.
        let factor = min(maxPixelEdge / max(size.width, size.height), 1)
        let target = CGSize(width: (size.width * factor).rounded(),
                            height: (size.height * factor).rounded())

        let format = UIGraphicsImageRendererFormat.default()
        // Scale 1: `target` is already in the pixels we want. Leaving this at
        // the screen's scale would silently render a 3x-larger bitmap and undo
        // the whole point.
        format.scale = 1
        format.opaque = true
        let thumbnail = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            full.draw(in: CGRect(origin: .zero, size: target))
        }

        let cost = Int(target.width * target.height) * 4
        decoded.setObject(thumbnail, forKey: assetName as NSString, cost: cost)
        return thumbnail
    }
}
