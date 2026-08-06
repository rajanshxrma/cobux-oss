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
