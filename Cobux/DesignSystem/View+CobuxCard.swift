import SwiftUI

/// Replaces the "card" treatment that had been copy-pasted independently at
/// 6+ call sites (`BookDetailView`, `WisdomGraphView`, `ChatView`,
/// `QuizResultsView`, ...) with drifted corner radii (7/12/14/16/18/20) and
/// border opacities (0.12/0.15/none, or no border at all). Also drops
/// `.ultraThinMaterial` per the mockup resolution: Aurora's blur was never
/// actually praised by name in review — its color and font were — and blur
/// doesn't combine cleanly with Studio's real hairline borders, so the
/// hybrid direction uses a flat solid surface instead.
extension View {
    /// A freestanding single card — one consistent 14pt radius, a real
    /// hairline border, no blur.
    func cobuxCard() -> some View {
        modifier(CobuxCardModifier())
    }

    /// One cell inside a structural grid/list (a stat tile, a book row) —
    /// zero radius, a real hairline border. Use `cobuxCard()` instead for a
    /// card that stands alone rather than sitting inside a grid.
    ///
    /// Was just `.background(Color.cobuxSurface2)` -- no radius, no border --
    /// silently contradicting this doc comment since it was written. Found
    /// while touching this file for the 2.2.0 glass work; fixed to actually
    /// match what it claims (real pre-existing bug, unrelated to glass).
    func cobuxStructuralCell() -> some View {
        modifier(CobuxStructuralCellModifier())
    }
}

private struct CobuxCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.cobuxSurface)
            .clipShape(RoundedRectangle(cornerRadius: CobuxRadius.card))
            .overlay(
                RoundedRectangle(cornerRadius: CobuxRadius.card)
                    .stroke(Color.cobuxLine, lineWidth: 1)
            )
    }
}

private struct CobuxStructuralCellModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.cobuxSurface2)
            .clipShape(RoundedRectangle(cornerRadius: CobuxRadius.structural))
            .overlay(
                RoundedRectangle(cornerRadius: CobuxRadius.structural)
                    .stroke(Color.cobuxLine, lineWidth: 1)
            )
    }
}
