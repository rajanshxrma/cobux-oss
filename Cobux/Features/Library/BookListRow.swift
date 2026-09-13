import SwiftUI
import UIKit

/// The library's list-layout row. His ask, near-verbatim: *"list view as well
/// option for the library books"* (ledger N19, docs/instruction-ledger.md) --
/// until now the grid's `BookCard` was the only shape a book on the shelf
/// ever had. `LibraryView` alternates between the two on the same
/// `filteredBooks`, keyed by the persisted `libraryLayout` choice; this file
/// owns only how ONE book reads as a row.
///
/// No highlight count, no progress, no tick -- the same standing ruling
/// `BookCard` and `LibraryView.shelfFooter` already follow: Cobux never
/// grades what's on the shelf, in either layout.
///
/// **Hue as identity (beauty checklist, Library 1 and 4).** His verdict on
/// this shelf, near-verbatim: *"the Library kinda looks dull, for the light
/// theme too; learn from the journal section."* The journal's grammar is the
/// day numeral in the month's own hue; the Quiz shelf already translated it
/// for books (`QuizBookRow`: a 4pt spine in `coverColorHex`). This row had
/// no equivalent -- thumbnail, title, grey line, grey chevron -- so the one
/// thing on it that carried the book's own colour was a 44pt thumbnail. The
/// spine leads now, before the cover, in the book's own ink; and the chevron
/// is `cobuxAccent`, because `Color.cobuxMuted` on the one interactive
/// affordance read as more inert text beside the secondary line
/// (`CobuxColor.swift`: violet "keeps every interactive accent it already
/// owns"). Content owns its hue; machinery stays violet. Both are static
/// fills -- nothing here costs a frame.
struct BookListRow: View {
    let book: Book

    @State private var coverImage: UIImage?

    /// "List scale," not the grid card's full 3:4 tile -- a dense list needs
    /// just enough of the cover to recognize the book at a glance, not the
    /// hero-sized art the card gives it room for.
    private static let coverWidth: CGFloat = 44
    private static let coverHeight: CGFloat = coverWidth * 4 / 3

    var body: some View {
        HStack(alignment: .center, spacing: CobuxSpacing.md) {
            // The book's spine: the same 4pt mark `QuizBookRow` draws, in
            // the same hue, so the Library list and the Quiz shelf read as
            // one grammar for "this is that book" rather than two. As tall
            // as its own cover here (Quiz's is 36pt beside two lines of
            // type) -- a spine is the height of the book it belongs to.
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: book.coverColorHex))
                .frame(width: 4, height: Self.coverHeight)

            cover
                .frame(width: Self.coverWidth, height: Self.coverHeight)
                .clipShape(RoundedRectangle(cornerRadius: CobuxRadius.iconBadge))

            VStack(alignment: .leading, spacing: 2) {
                BookTitleText(title: book.title, font: .body, weight: .semibold, lineLimit: 2)
                Text(secondaryLine)
                    .font(.subheadline)
                    .foregroundStyle(Color.cobuxMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: CobuxSpacing.sm)

            // Violet, not `cobuxMuted`: this is the row's one interactive
            // affordance, and painted the same grey as the author line it
            // read as caption text. The accent is what says "this opens".
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.cobuxAccent)
        }
        .padding(.vertical, CobuxSpacing.sm)
        .contentShape(Rectangle())
        // A soft hairline between rows -- `Color.cobuxLine`, the app's real
        // divider token (`CobuxColor.line`'s own doc comment: "not a
        // translucent wash"), never a `.cobuxCard()` border per row. This is
        // one list, not a stack of freestanding cards.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.cobuxLine)
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .task(id: book.id) { await loadCoverImage() }
    }

    /// Author, plus the tradition's own name for itself when the book has
    /// one -- same "· label" grammar Flow's kicker already uses
    /// (`FlowCardViews.swift`) rather than inventing a second way to say it.
    private var secondaryLine: String {
        guard let tradition = book.tradition else { return book.author }
        return "\(book.author) · \(tradition.label)"
    }

    // Same three-tier resolution as `BookCard.coverBackground` (bundled
    // asset -> on-device remote-fetch cache -> gradient), reused rather than
    // re-invented: `BookCoverThumbnails` and `CoverImageCache` are both
    // internal, so this row asks them the identical question a grid card
    // would for the same book, and warms/shares the very same process cache.
    @ViewBuilder
    private var cover: some View {
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

    // Off the main thread, exactly like `BookCard.loadCoverImage`: the
    // bundled-asset tier decodes and downsamples via `Task.detached` inside
    // `BookCoverThumbnails.thumbnail`, never a raw `UIImage(named:)` decode of
    // an up-to-11MB source image on this row's own `body`. Duplicated here
    // rather than shared because `BookCard`'s copy is `private` to that file.
    @MainActor
    private func loadCoverImage() async {
        if let assetName = book.coverAssetName {
            if let thumbnail = await Task.detached(priority: .userInitiated, operation: {
                BookCoverThumbnails.thumbnail(assetName: assetName)
            }).value {
                coverImage = thumbnail
                return
            }
            // Falls through when the imageset genuinely doesn't resolve --
            // same reasoning as `BookCard`'s identical fallthrough.
        }
        if let cached = CoverImageCache.cachedImage(for: book.id) {
            coverImage = cached
            return
        }
        guard let urlString = book.coverImageURL, let url = URL(string: urlString) else { return }
        coverImage = await CoverImageCache.downloadAndCache(bookID: book.id, remoteURL: url)
    }
}
