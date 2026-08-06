import SwiftUI

/// Semantic color tokens, backed by real Asset Catalog color sets with light
/// AND dark variants (not a Swift-side ternary) — the values here are the
/// exact ones validated through the Phase 0b mockup: Studio's structural
/// grid, Aurora's light-mode warmth, Console's dark-mode edge.
///
/// This is also the fix for the two-indigo-accent bug: `AccentColor` used to
/// have only a single universal value (`#6366F1`), so anywhere the app used
/// system `.indigo` instead (≈`#5856D6` light / `≈#7D7AFF` dark) rendered a
/// visibly different color from the real brand accent — chat bubbles were a
/// different indigo from the tab bar. `AccentColor` now has a proper dark
/// variant (`#8385F5`, matching Aurora's dark accent from the mockup), and
/// `Color.cobuxAccent` is the one name every call site should use going
/// forward — `no_raw_system_color` (`.swiftlint.yml`) already flags any new
/// `Color.indigo` usage in Features/Components.
enum CobuxColor {
    static let background = Color("CobuxBackground")
    static let surface = Color("CobuxSurface")
    /// The slightly-elevated surface used inside a structural grid cell
    /// (`stat-grid`/`book-row` in the mockup) — distinct from `surface`,
    /// which is for freestanding cards.
    static let surface2 = Color("CobuxSurface2")
    static let ink = Color("CobuxInk")
    static let muted = Color("CobuxMuted")
    /// A real, solid hairline — not a translucent wash. The mockup's Studio
    /// direction (kept in the hybrid) uses actual dividers, not soft borders.
    static let line = Color("CobuxLine")
    static let good = Color("CobuxGood")
    static let danger = Color("CobuxDanger")
    /// Same value as system `.orange` (light `#FF9500` / dark `#FF9F0A`) --
    /// tokenized so alert/warning states (TestFlight expiry, budget banners,
    /// streak flame) go through a real name instead of the raw system color
    /// `no_raw_system_color` already flagged for everything else.
    static let warning = Color("CobuxWarning")
    /// The one accent every call site should reference — resolves to
    /// `AccentColor`, which now has both a light and dark value.
    static let accent = Color.accentColor

    /// `VoiceModeView`'s always-dark full-screen background — a deep indigo-to-black wash,
    /// distinct from `background`/`surface` since voice mode forces `.preferredColorScheme(.dark)`
    /// regardless of the system setting, the way the old Walk Mode did.
    static let voiceGradient: [Color] = [Color(hex: "#1E1B4B"), Color(hex: "#312E81"), Color(hex: "#0F0B2E")]
}

extension Color {
    static var cobuxBackground: Color { CobuxColor.background }
    static var cobuxSurface: Color { CobuxColor.surface }
    static var cobuxSurface2: Color { CobuxColor.surface2 }
    static var cobuxInk: Color { CobuxColor.ink }
    static var cobuxMuted: Color { CobuxColor.muted }
    static var cobuxLine: Color { CobuxColor.line }
    static var cobuxGood: Color { CobuxColor.good }
    static var cobuxDanger: Color { CobuxColor.danger }
    static var cobuxWarning: Color { CobuxColor.warning }
    static var cobuxAccent: Color { CobuxColor.accent }
}
