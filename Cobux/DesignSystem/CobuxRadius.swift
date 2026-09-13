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
    /// **Corner-adjacent controls.** A control placed in a rounded card's
    /// corner must have its CENTRE at least this radius in from both edges.
    /// Nearer than that and the control sits inside the corner's arc, where
    /// the background is already curving away from it, and it reads as
    /// slipping off the card rather than sitting on it. A 44pt tap frame
    /// pinned to the corner does this for free (centre at 22, clear of every
    /// radius here) -- which is why the same frame that satisfies the tap
    /// target also fixes the look. Reported on two surfaces at once: "the top
    /// corss here is weirdly palced formatted absed on the curve similarly the
    /// rigt arrow thingy here".
    static let card: CGFloat = 14
    /// Fully round — chips, tags, pill buttons.
    static let pill: CGFloat = 100
    /// Glass surfaces specifically (2.2.0) — `card`'s 14pt reads cramped once
    /// wrapped in `.glassEffect`, which visually wants a softer, more
    /// continuous curve than a flat solid card does at the same radius.
    /// Deliberately its own token rather than bumping `card` itself, since
    /// `card`'s 14pt is still correct for every existing flat-card call site
    /// this redesign isn't touching.
    static let glassCard: CGFloat = 20
    /// A small icon badge (`CobuxSettingsRow`'s leading glyph square) — too
    /// small a surface for `card`'s 14pt to read as anything but a circle;
    /// this is the standard "squircle-ish app icon glyph" radius at 28pt box
    /// size, distinct from `pill` (fully round, for chips/tags, not icons).
    static let iconBadge: CGFloat = 8

    /// A chat message bubble. Continuous-curvature at 18 reads as soft rather
    /// than as a box -- the old shape hand-plotted an iMessage tail with 20pt
    /// corners, and on a one-line reply the two corner curves plus the tail
    /// consumed the whole silhouette, which is what made short bubbles look
    /// lumpy and no two of them look alike.
    static let bubble: CGFloat = 18

    /// A quote card inside a reply. Smaller than a bubble on purpose: it is an
    /// object sitting ON the reply, not a peer of it.
    static let quote: CGFloat = 12
}
