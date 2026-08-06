import SwiftUI

/// One spring vocabulary, used everywhere — the "modern and interactive" ask
/// is mostly motion, not color, and a single consistent set of springs is
/// what makes transitions across the app feel like one system instead of
/// scattered one-off `.spring(...)` calls at each call site.
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
