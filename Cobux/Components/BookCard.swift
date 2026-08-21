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
        .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 3)
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
    // a `coverImageURL` with no `coverAssetName`) -> the gradient. A bundled
    // asset needs no cache and no `.task` round-trip at all -- it's already
    // in the binary, so it renders on the very first frame instead of
    // popping in a beat later like every network-sourced cover before it.
    @ViewBuilder
    private var coverBackground: some View {
        // `Cover-<slug>` is the real imageset name (see `Book.coverAssetName`'s
        // doc comment) -- `coverAssetName` itself only ever stores the bare
        // slug. A prior version of this code looked up the bare slug directly
        // and got nil back for all 26 seed books, silently falling to the
        // gradient tier every time; the prefix has to be added here.
        if let assetName = book.coverAssetName, let bundled = UIImage(named: "Cover-" + assetName) {
            Image(uiImage: bundled)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let coverImage {
            Image(uiImage: coverImage)
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
        if let assetName = book.coverAssetName, UIImage(named: "Cover-" + assetName) != nil {
            return
        }
        if let cached = CoverImageCache.cachedImage(for: book.id) {
            coverImage = cached
            return
        }
        guard let urlString = book.coverImageURL, let url = URL(string: urlString) else { return }
        coverImage = await CoverImageCache.downloadAndCache(bookID: book.id, remoteURL: url)
    }
}
