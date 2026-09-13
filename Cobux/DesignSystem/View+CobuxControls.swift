import SwiftUI

/// The two-tier control grammar, named.
///
/// Flow established it and every premium surface since has copied it by hand:
/// a QUIET CHIP for secondary actions (caption weight, tinted wash, never
/// saturated) and ONE filled PRIMARY PILL per surface -- full saturation
/// appears exactly once on a screen, which is most of why Flow reads as
/// expensive while a screen of equally-loud buttons reads as a form.
///
/// The one-saturation rule is the doctrine, not a suggestion: if a surface
/// wants two pills, one of them is actually a chip.
extension View {
    /// Secondary action: tinted wash, quiet type. As many as a surface needs.
    func cobuxQuietChip(tint: Color) -> some View {
        self
            .font(.caption.weight(.semibold))
            .padding(.horizontal, CobuxSpacing.chipH)
            .padding(.vertical, CobuxSpacing.chipV)
            .background(tint.opacity(0.15), in: Capsule())
            .contentShape(Capsule())
    }

    /// The primary action: filled, one per surface. The type is white OR the
    /// dark ink, whichever actually reads on this tint (`Color.cobuxOnTint`)
    /// -- it used to be white unconditionally, which on the dark-mode accent
    /// measured 3.2:1 and on a pale book cover 2.2:1.
    func cobuxPrimaryPill(tint: Color) -> some View {
        modifier(CobuxPrimaryPillModifier(tint: tint))
    }

    /// The kicker grammar: small caps naming the MECHANISM that put this in
    /// front of him ("ON THIS DAY", "FROM YOUR ARCHIVE"), in the content's
    /// own hue. `.inline` for cards, `.screen` for full-screen surfaces.
    func cobuxKicker(tint: Color, scale: CobuxKickerScale = .inline) -> some View {
        self
            .font(scale.font)
            .textCase(.uppercase)
            .kerning(scale.kerning)
            .foregroundStyle(tint)
    }
}

/// A modifier rather than a plain extension method because the on-tint
/// colour has to be resolved against the live environment (colour scheme,
/// so an asset-catalogue tint measures as the value it paints).
private struct CobuxPrimaryPillModifier: ViewModifier {
    let tint: Color
    @Environment(\.self) private var environment

    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.cobuxOnTint(tint, in: environment))
            .padding(.horizontal, CobuxSpacing.pillH)
            .padding(.vertical, CobuxSpacing.pillV)
            .background(tint, in: Capsule())
            .contentShape(Capsule())
    }
}

enum CobuxKickerScale {
    case inline, screen

    var font: Font {
        switch self {
        case .inline: .caption2.weight(.semibold)
        case .screen: .caption.weight(.semibold)
        }
    }
    var kerning: CGFloat {
        switch self { case .inline: 0.7; case .screen: 1.2 }
    }
}
