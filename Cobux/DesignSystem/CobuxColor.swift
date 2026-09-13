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

    /// The 3.0 identity's lead: crimson, on the near-black grounds above.
    ///
    /// Rajan's order, near-verbatim: "a new red-black theme... the purple
    /// should still be kept as the third color... a bold look of red-black
    /// main... introduction of red doesn't mean letting go of our OG color."
    /// The division of labor that keeps both bold AND legible:
    /// - CRIMSON leads the app's own chrome -- machinery badges, selection
    ///   tint, identity moments -- on grounds deepened toward true black
    ///   with a barely-there crimson cast.
    /// - VIOLET (the OG) keeps every interactive accent it already owns --
    ///   the Flow button, the icon, links, chips -- used as liberally as
    ///   ever.
    /// - CONTENT keeps its own hues: book covers, month colors, situations'
    ///   sky. Red never overwrites what content owns.
    /// The dark value is deliberately lifted (#EF4452) for contrast on
    /// black -- accessibility is part of the order, not a tax on it.
    static let crimson = Color("CobuxCrimson")

    /// Ebb's own hue -- teal, deliberately outside every month's palette and
    /// the app accent, because Ebb is neither a month nor machinery: it is
    /// the journal's other room. This was a raw `#0D9488` in two files while
    /// the door card under the calendar rendered the same wordmark in violet
    /// and the room itself in grey -- one pillar, three colours, which is how
    /// a hue drifts. One token, every door. The light value is `#0F766E`
    /// (5.3:1 on the paper ground, AA for the 11pt bold wordmark; the old
    /// teal was 3.6:1); the dark value keeps the `#0D9488` he approved, which
    /// already clears AA on the near-black ground (5.4:1).
    static let ebb = Color("CobuxEbb")

    /// `VoiceModeView`'s always-dark full-screen background — a deep indigo-to-black wash,
    /// distinct from `background`/`surface` since voice mode forces `.preferredColorScheme(.dark)`
    /// regardless of the system setting, the way the old Walk Mode did.
    static let voiceGradient: [Color] = [Color(hex: "#1E1B4B"), Color(hex: "#312E81"), Color(hex: "#0F0B2E")]

    /// The 3.0 identity ground: black falling into deep violet -- the app
    /// icon's field and the Flow button's capsule. Onboarding is the first
    /// full-screen use; the Flow button (`ContentView.FlowLaunchButton`) still
    /// spells the same three stops out by hand and should adopt this token
    /// when that file is next touched.
    static let identityGradient: [Color] = [Color(hex: "#0B0B0F"), Color(hex: "#2E1065"), Color(hex: "#4C1D95")]

    /// The dark ink for type set ON a light tint -- see `Color.cobuxOnTint`.
    /// A warm near-black in the same family as the dark ground, not pure
    /// black: pure black on a pastel pill reads as a printout, not a control.
    /// Fixed, not the adaptive `ink` token -- a pill's fill is the same colour
    /// in both themes, so the type on it must be too.
    static let onTintDark = Color(.sRGB, red: 0.090, green: 0.063, blue: 0.075, opacity: 1)
}

// MARK: - Contrast

/// WCAG 2.x relative luminance and contrast, on the values SwiftUI actually
/// resolves. `scripts/check-contrast.py` mirrors this arithmetic against the
/// asset catalogue and the seed covers so the numbers below are a ship gate,
/// not a memory.
enum CobuxContrast {
    /// Relative luminance of a resolved colour, composited over `ground`
    /// when it is translucent (a month hue at 0.85 over near-black is a
    /// darker colour than the opaque hue -- it has to be measured as what
    /// is painted, not what was asked for).
    static func luminance(_ color: Color.Resolved, over ground: Color.Resolved? = nil) -> Double {
        var red = Double(color.linearRed), green = Double(color.linearGreen), blue = Double(color.linearBlue)
        let alpha = Double(color.opacity)
        if alpha < 1, let ground {
            red = red * alpha + Double(ground.linearRed) * (1 - alpha)
            green = green * alpha + Double(ground.linearGreen) * (1 - alpha)
            blue = blue * alpha + Double(ground.linearBlue) * (1 - alpha)
        }
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    /// Contrast ratio between two luminances, 1...21.
    static func ratio(_ a: Double, _ b: Double) -> Double {
        let (light, dark) = a >= b ? (a, b) : (b, a)
        return (light + 0.05) / (dark + 0.05)
    }

    /// Whether type on a tint of this luminance reads better in the dark ink
    /// than in white. Picks whichever of the two candidates has the higher
    /// ratio -- no fixed threshold to drift from the arithmetic.
    static func prefersDarkInk(onTintLuminance tint: Double) -> Bool {
        ratio(tint, onTintDarkLuminance) > ratio(tint, 1.0)
    }

    /// Luminance of `CobuxColor.onTintDark`. Resolved once from the token
    /// itself rather than typed in, so the two can never disagree.
    static let onTintDarkLuminance: Double = luminance(CobuxColor.onTintDark.resolve(in: EnvironmentValues()))
}

extension Color {
    /// The colour for type or a glyph set ON `tint`: white, or the dark ink,
    /// whichever reads with more contrast against the tint as it will
    /// actually paint in this environment.
    ///
    /// `cobuxPrimaryPill` used to hardcode white on every tint. Measured:
    /// white on the dark-mode accent was 3.2:1, on Ebb's April-July hues
    /// 2.4-4.0:1, and Flow's Open Cobux pill painted white on the book's raw
    /// cover colour -- `#A3B29F` at 2.2:1. Fixed here, in the token, so every
    /// surface that already goes through the pill inherits it.
    static func cobuxOnTint(_ tint: Color, in environment: EnvironmentValues) -> Color {
        let resolved = tint.resolve(in: environment)
        let ground = CobuxColor.background.resolve(in: environment)
        let luminance = CobuxContrast.luminance(resolved, over: ground)
        return CobuxContrast.prefersDarkInk(onTintLuminance: luminance) ? CobuxColor.onTintDark : .white
    }

    /// Same rule for an opaque hex tint, when no environment is at hand.
    static func cobuxOnTint(hex: String) -> Color {
        let tint = Color(hex: hex).resolve(in: EnvironmentValues())
        return CobuxContrast.prefersDarkInk(onTintLuminance: CobuxContrast.luminance(tint))
            ? CobuxColor.onTintDark : .white
    }
}

extension Color {
    static var cobuxBackground: Color { CobuxColor.background }
    /// Situations' own hue -- sky, deliberately outside every book's palette
    /// and distinct from the app accent, because a situation is neither a
    /// book nor machinery: it is a thread about a person. Was hardcoded
    /// #0EA5E9 in two files, which is how a hue drifts.
    static var cobuxSituation: Color { Color(hex: "#0EA5E9") }
    static var cobuxSurface: Color { CobuxColor.surface }
    static var cobuxSurface2: Color { CobuxColor.surface2 }
    static var cobuxInk: Color { CobuxColor.ink }
    static var cobuxMuted: Color { CobuxColor.muted }
    static var cobuxLine: Color { CobuxColor.line }
    static var cobuxGood: Color { CobuxColor.good }
    static var cobuxDanger: Color { CobuxColor.danger }
    static var cobuxWarning: Color { CobuxColor.warning }
    static var cobuxCrimson: Color { CobuxColor.crimson }
    static var cobuxEbb: Color { CobuxColor.ebb }
    static var cobuxAccent: Color { CobuxColor.accent }
}

// MARK: - Wordmark

extension ShapeStyle where Self == LinearGradient {
    /// The fill for the COBUX wordmark wherever it is set in type: ink for
    /// the first letters, leaning into crimson by the last one.
    ///
    /// Rajan, 12 Sep: "the red should also come in icon and name with the
    /// cobux current colors a tiny bit, like tiktok icon has multiple colors
    /// right but we mostly remember it as black ... a light tint of red as
    /// well." So the mark stays ink -- it is read as ink -- and the tint is
    /// a second hue you notice only when you look: solid ink through 62 % of
    /// the width, then one ramp into `cobuxCrimson` that lands on the X.
    /// Crimson clears 5.5:1 on the light ground and 5.4:1 on the dark one
    /// (`scripts/check-contrast.py`, rule 1), so the last letter never reads
    /// weaker than the first. A fill changes no glyph metrics, so the chat
    /// bar's 85.1pt principal budget (see `ChatView`) is untouched.
    static var cobuxWordmark: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color.cobuxInk, location: 0.0),
                .init(color: Color.cobuxInk, location: 0.62),
                .init(color: Color.cobuxCrimson, location: 1.0),
            ],
            startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - Month hues

/// One hue per month, for the journal.
///
/// The journal was the only chromatically dead screen in the app — Library has
/// cover colours, Flow has atmospheres, and the journal was grey ink on grey
/// paper, which is literally what "dull" meant. These are used in exactly three
/// places: the day-thread line, the day header's date numeral, and the
/// calendar's intensity fill for that month. Cards themselves stay neutral, so
/// the feed gains colour life that changes as you scroll back through time
/// without a single card being decorated.
///
/// Curated, never hashed from the date — hashing produces uglies, and this has
/// to look chosen. Roughly seasonal: cold blues in deep winter, greens through
/// spring, warm through summer, ambers and rusts in autumn.
extension Color {
    static func cobuxMonthHue(_ month: Int, dark: Bool = false) -> Color {
        let light: [String] = [
            "#4A6FA5", // January   — cold blue
            "#5B7C99", // February  — slate
            "#5E8C61", // March     — first green
            "#7BA05B", // April     — spring
            "#9BB068", // May       — bright green
            "#C9A227", // June      — high sun
            "#D98E32", // July      — heat
            "#C7702D", // August    — late summer
            "#A85B32", // September — turning
            "#8C4A2F", // October   — rust
            "#6B4A3A", // November  — bare wood
            "#3F5A7A", // December  — deep winter
        ]
        let index = min(max(month - 1, 0), 11)
        let base = Color(hex: light[index])
        // Dark variants: desaturated a touch and lifted, so a hue that reads
        // rich on paper does not glow on near-black.
        return dark ? base.opacity(0.85) : base
    }
}
