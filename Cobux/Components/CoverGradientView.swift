import SwiftUI

/// Shared placeholder cover treatment for a book with no `coverImageURL` (or
/// while one is loading) — was previously duplicated near-verbatim between
/// `BookCard` and `BookDetailView`, with the two copies' opacity already
/// drifted apart (0.6 vs 0.5). One shared source now.
struct CoverGradientView: View {
    let colorHex: String

    var body: some View {
        LinearGradient(
            colors: [Color(hex: colorHex), Color(hex: colorHex).opacity(0.6)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
