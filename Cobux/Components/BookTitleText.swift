import SwiftUI

/// One render site for a book title, replacing four independent ones
/// (`BookDetailView`, `BookCard`, `QuizHomeView`, `LibraryView`'s search
/// result) — none of which set `.multilineTextAlignment`,
/// so a short title (one line) read left-aligned by coincidence while a long
/// one (e.g. "Robbins & Cotran Pathologic Basis of Disease", which wraps to
/// 2-3 lines) had its wrapped lines centered against each other by SwiftUI's
/// default. Alignment is now a property of the system, not something each
/// call site has to remember.
///
/// `expandsWidth` controls whether the title's bounding box spans the full
/// available width (appropriate over a hero image/card background, where the
/// title should span edge-to-edge) or sizes to its own content (appropriate
/// inline alongside other short text, e.g. a search-result row, where
/// forcing full width would push sibling content around).
struct BookTitleText: View {
    let title: String
    var font: Font = .headline
    var weight: Font.Weight?
    var color: Color = .primary
    var lineLimit: Int?
    var expandsWidth: Bool = false

    var body: some View {
        Text(title)
            .font(font)
            .fontWeight(weight)
            .foregroundStyle(color)
            .lineLimit(lineLimit)
            .multilineTextAlignment(.leading)
            .modifier(ExpandWidthIfNeeded(expandsWidth: expandsWidth))
    }
}

private struct ExpandWidthIfNeeded: ViewModifier {
    let expandsWidth: Bool
    func body(content: Content) -> some View {
        if expandsWidth {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content
        }
    }
}
