import CoreGraphics

/// Corner-radius policy — resolved from the mockup's own contradiction-turned-
/// insight: Studio's structural grid discipline (radius 0, real hairlines)
/// applies to BOTH themes now, not just dark; freestanding single cards get
/// one consistent 14pt (Console's own card radius — the middle value across
/// all three original directions, reading as "considered" rather than either
/// extreme); pills/chips stay fully round. This replaces 6 different literal
/// radii (7/12/14/16/18/20) that had drifted in across the app with zero
/// rationale — `no_magic_corner_radius` (`.swiftlint.yml`) flags any new
/// literal outside this file.
enum CobuxRadius {
    /// Structural containers: stat grids, book-row lists, thread lists,
    /// choice-row stacks. Zero radius, real hairline dividers between cells —
    /// in both light and dark.
    static let structural: CGFloat = 0
    /// Freestanding single cards that aren't part of a grid — a quiz session
    /// card, a standalone panel.
    static let card: CGFloat = 14
    /// Fully round — chips, tags, pill buttons.
    static let pill: CGFloat = 100
}
