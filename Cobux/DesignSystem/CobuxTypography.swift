import SwiftUI

/// Two deliberate typographic breaks from stock, each scoped to exactly one
/// theme per the mockup resolution — not a "why not both" compromise, an
/// intentional split:
///
/// - Tabular monospace numerals (dark mode only): Console's "instrument
///   panel" numeral treatment reads as a dark-mode-specific metaphor
///   (cockpit, terminal, night). Next to Aurora's warm serif wordmark in
///   light mode, monospace numerals would look like two unrelated systems
///   stitched together.
/// - A serif wordmark/hero title (light mode only): Georgia/New York next to
///   Console's near-black instrument panel in dark mode would read the same
///   way, in reverse.
///
/// `Color.cobuxAccent`/`CobuxColor` already vary by theme automatically via
/// the Asset Catalog; these two need an explicit `colorScheme` check because
/// SwiftUI has no "font that varies by appearance" primitive.
enum CobuxTypography {
    // MARK: - Type scale (2.2.0)
    //
    // Everything above this point predates the redesign and stays exactly as
    // it was — the two theme-dependent treatments are real, deliberate, and
    // untouched. What was missing was an ordinary type SCALE: most of the app
    // used stock Dynamic Type roles (`.headline`, `.subheadline`, `.caption`)
    // directly and ad-hoc, with no shared vocabulary for "this is a screen
    // title" vs "this is a row label" vs "this is a row's trailing value" —
    // the actual reason ~15 Form/List screens (Settings, MoreView, etc.) read
    // as stock: no consistent type identity, not a glass/material problem.
    // Built on Dynamic Type text styles (not fixed point sizes) so accessibility
    // text-size settings keep working exactly as they already do everywhere else
    // in the app.

    /// A screen's primary title (used sparingly — most screens rely on the
    /// navigation bar title; this is for a hero title *within* content, like a
    /// sheet's heading).
    static let cobuxTitle: Font = .system(.title2, design: .default, weight: .bold)

    /// A `CobuxFormSection`'s header — matches the weight/size convention iOS
    /// section headers use, but through the design system instead of a bare
    /// `Text` + ad-hoc modifiers repeated per screen.
    static let cobuxSectionHeader: Font = .system(.footnote, design: .default, weight: .semibold)

    /// Ordinary body copy — the default for anything that isn't a row label,
    /// value, caption, or title.
    static let cobuxBody: Font = .system(.body, design: .default, weight: .regular)

    /// Secondary/supporting text — footnotes, helper copy under a control.
    static let cobuxCaption: Font = .system(.caption, design: .default, weight: .regular)

    /// A `CobuxSettingsRow`'s leading label (e.g. "Appearance", "Voice Mode").
    static let cobuxRowLabel: Font = .system(.body, design: .default, weight: .medium)

    /// A `CobuxSettingsRow`'s trailing value (e.g. the current selection, a
    /// status string) — one step down from the label so the label reads as
    /// primary and the value as its current state, not two equal-weight facts.
    static let cobuxRowValue: Font = .system(.subheadline, design: .default, weight: .regular)

    // MARK: - Existing theme-dependent treatments

    /// For any numeral-heavy UI — stat cards, timers, mastery percentages.
    /// Always `.monospacedDigit()` for column alignment regardless of theme;
    /// the *family* itself only switches to true monospace in dark mode.
    static func numeral(_ colorScheme: ColorScheme, size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        switch colorScheme {
        case .dark:
            return .system(size: size, weight: weight, design: .monospaced)
        default:
            return .system(size: size, weight: weight, design: .default)
        }
    }

    /// The COBUX wordmark / a book's hero title.
    static func display(_ colorScheme: ColorScheme, size: CGFloat, weight: Font.Weight = .bold) -> Font {
        switch colorScheme {
        case .dark:
            return .system(size: size, weight: weight, design: .default)
        default:
            return .system(size: size, weight: weight, design: .serif)
        }
    }
}

extension View {
    /// Convenience for the common case: numeral font + tabular alignment in
    /// one call, reading the active color scheme from the environment.
    func cobuxNumeralStyle(size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        modifier(CobuxNumeralStyleModifier(size: size, weight: weight))
    }
}

private struct CobuxNumeralStyleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content
            .font(CobuxTypography.numeral(colorScheme, size: size, weight: weight))
            .monospacedDigit()
    }
}
