import CoreGraphics

/// Spacing policy — `.swiftlint.yml`'s `no_bare_padding` rule has told developers to use a
/// spacing token since this project's design-system pass, but no such type actually existed
/// until now (confirmed by grep: zero `CobuxSpacing` references anywhere). Fills that real gap
/// as part of the 2.2.0 redesign.
///
/// A 4pt base scale, plus semantic aliases matched to the values already dominant across the
/// app's existing `.padding()` calls — chosen deliberately so adopting this token doesn't shift
/// anything visually on its own; it just replaces literals with names.
enum CobuxSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32

    /// Leading/trailing margin for a screen's primary content.
    static let screenMargin: CGFloat = 20
    /// Interior padding for a `.cobuxCard()`/`.cobuxGlassCard()`.
    static let cardPadding: CGFloat = 16
    /// Vertical gap between rows in a list/section (e.g. `CobuxSettingsRow`).
    static let rowGap: CGFloat = 12
    /// Vertical gap between distinct sections on a screen.
    static let sectionGap: CGFloat = 24
}
