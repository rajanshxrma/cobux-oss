import SwiftUI

/// Liquid Glass entry points (2.2.0) — the ONE place in the app allowed to call
/// `.glassEffect`/`GlassEffectContainer` directly; `.swiftlint.yml`'s reworked
/// material/glass rule bans those APIs everywhere else, so the `#available(iOS 26.0, *)`
/// gate below exists exactly once and can never be forgotten at a call site.
///
/// Deliberately scoped to the FLOATING layer — banners, overlays, HUDs — not content
/// cards. Apple's own Liquid Glass guidance treats glass as a control layer that sits
/// above content, not a replacement for content surfaces; glassing every card in the
/// app (there are ~20) would read as mush, not "modern." `.cobuxCard()` stays the
/// content-card default; these are for things that visually float.
///
/// Every modifier below falls back to a flat, solid, hairline-bordered treatment on
/// iOS 17-25 (this app's deployment target is 17.0) — visually equivalent to what the
/// app already looked like before this redesign, not a degraded second-class look.
extension View {
    /// A floating element in an arbitrary shape — a banner, a HUD chip, a floating
    /// action element. `shape` is used on BOTH branches so the fallback matches the
    /// glass version's silhouette exactly (e.g. `.capsule` for a pill-shaped banner).
    ///
    /// `tintColor` defaults to `nil` (neutral glass, no tint). Pass a semantic color
    /// (`.cobuxAccent`, `.cobuxWarning`, `.cobuxDanger`, ...) to tint the glass toward
    /// that meaning — e.g. a warning banner should tint warning-colored, not brand-
    /// accent-colored. Was a bare `tinted: Bool` that always tinted accent regardless
    /// of what the caller actually meant; caught while wiring up `storeHealthBanner`,
    /// which needs warning, not accent.
    func cobuxGlassFloating<S: Shape>(shape: S, tintColor: Color? = nil) -> some View {
        modifier(CobuxGlassFloatingModifier(shape: shape, tintColor: tintColor))
    }

    /// The glass counterpart to `.cobuxCard()` — a freestanding rounded-rect surface,
    /// but meant for something that floats over content (a HUD panel), not a list/grid
    /// content card. Uses `CobuxRadius.glassCard` (20pt), not `CobuxRadius.card` (14pt)
    /// — a flat 14pt card reads cramped once wrapped in real glass, which wants a
    /// softer, more continuous curve.
    func cobuxGlassCard(tintColor: Color? = nil) -> some View {
        modifier(CobuxGlassFloatingModifier(shape: .rect(cornerRadius: CobuxRadius.glassCard, style: .continuous), tintColor: tintColor))
    }

    /// The glass counterpart to a pill/capsule chip.
    func cobuxGlassChip(tintColor: Color? = nil) -> some View {
        modifier(CobuxGlassFloatingModifier(shape: .capsule, tintColor: tintColor))
    }
}

private struct CobuxGlassFloatingModifier<S: Shape>: ViewModifier {
    let shape: S
    let tintColor: Color?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // Glass supplies its own edge -- deliberately no additional hairline
            // stroke here, unlike the fallback branch below. Layering a manual
            // border on top of real glass double-draws an edge glass already
            // renders itself.
            let glass: Glass = tintColor.map { .regular.tint($0.opacity(0.12)) } ?? .regular
            content.glassEffect(glass.interactive(), in: shape)
        } else {
            // iOS 17-25: the exact flat/solid/hairline treatment `.cobuxCard()`
            // already uses elsewhere in the app, just parameterized over an
            // arbitrary shape instead of being locked to a rounded rectangle --
            // `Color.cobuxSurface` is fully opaque, so this remains visually
            // identical to what these elements looked like before this redesign.
            content
                .background(Color.cobuxSurface, in: shape)
                .overlay(shape.stroke(Color.cobuxLine, lineWidth: 1))
        }
    }
}

/// Wraps `GlassEffectContainer` on iOS 26+ (required for correct visual merging when
/// multiple glass elements sit adjacent and may need to morph/combine), plain passthrough
/// below. Use around any group of `.cobuxGlassFloating`/`.cobuxGlassCard`/`.cobuxGlassChip`
/// elements that are visually adjacent (e.g. a HUD with more than one floating piece).
struct CobuxGlassContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                content()
            }
        } else {
            content()
        }
    }
}
