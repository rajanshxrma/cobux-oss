import SwiftUI

/// One spring vocabulary, used everywhere — the "modern and interactive" ask
/// is mostly motion, not color, and a single consistent set of springs is
/// what makes transitions across the app feel like one system instead of
/// scattered one-off `.spring(...)` calls at each call site.
/// STANDING MOTION RULES (build 52, the consistency pass):
///
/// - The settle transition: cards in a paging feed scale to 0.94 / fade to
///   0.55 off-detent, content layers parallax at -40 and decorative glyphs at
///   a deeper plane (-52 in Flow, -12 relative in Ebb). Two planes moving at
///   different rates is the entire depth illusion; do not add a third.
/// - The settle haptic: `.impact(weight: .light, intensity: 0.7)` on paging
///   detents, skipping the nil->first transition -- opening a surface is not
///   a page turn.
/// - Reduce Motion is a hard gate, not a suggestion: every scrollTransition,
///   parallax and entrance spring added anywhere checks
///   `accessibilityReduceMotion` and degrades to opacity-only. A settle that
///   still scales under Reduce Motion is a bug.
///
enum CobuxMotion {
    /// Selection, toggles, chips — quick and light.
    static let snap = Animation.spring(response: 0.28, dampingFraction: 0.86)
    /// Sheets, card enter/exit, chat bubbles.
    static let flow = Animation.spring(response: 0.42, dampingFraction: 0.82)
    /// `matchedGeometryEffect` transitions — book card flying into its hero.
    static let hero = Animation.spring(response: 0.55, dampingFraction: 0.78)
    /// Numeric/count changes — a stat rolling to its new value.
    static let settle = Animation.spring(response: 0.70, dampingFraction: 0.90)
}
