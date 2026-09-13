import SwiftUI

/// The living background: one animated gradient keyed to the content's own
/// color, with everything above it transparent so the atmosphere melts
/// through.
///
/// This is Flow's signature move (`FlowView` carried the original), named and
/// extracted because Ebb and Chat each re-derived it by hand with their own
/// stops and their own timing -- three copies of one idea, already drifting.
/// From now on a screen adopts an accent by USING this view; the stops and
/// the ease live here and cannot drift.
///
/// Three strengths, because a card deck, a reading surface and a paper ground
/// want different presences:
/// - `.card`: Flow/Ebb -- the color is the room.
/// - `.reading`: Chat and any text-dense screen -- the color is a memory of
///   the room, faint enough to read against for an hour.
/// - `.ground`: Journal -- the color is the paper. Same as `.reading` in light;
///   in dark it is the one strength that stays VISIBLE.
///
/// Why `.ground` exists rather than `.reading` simply being stronger in dark:
/// `.reading` at 0.10 over the near-white light ground is a visible blush;
/// the same 0.10 over the near-black dark ground composites to a couple of
/// percent of luminance and is simply not there. That is what Rajan was
/// looking at on build 57, dark mode, having been told the journal now carried
/// a warm tint: "i dont relly see what dark mode warm tint theres none." He
/// was right -- the number was tuned on white. But `.reading` is also Ebb's
/// ground, and Ebb sets small type in the month hue ON that wash (the kicker);
/// `scripts/check-contrast.py` rule 4 measured what 0.30 would do to it in
/// dark -- Sep 2.77:1 -> 1.90:1, every month roughly halved -- and that ratchet
/// forbids sinking a known-failing pairing further. So Ebb and Chat keep the
/// stops they were measured at, and the journal, which sets no small tinted
/// type on its ground, takes a strength of its own. Its dark top is 0.26, not
/// the 0.30 first proposed: measured with `CobuxColor.swift`'s arithmetic,
/// `CobuxMuted` on the crimson wash reads 4.59:1 at 0.26 and 4.29:1 at 0.30,
/// and 4.5:1 is the floor the design system holds secondary type to. 0.26 is
/// the strongest stop that keeps it. `.card` is left alone in both themes:
/// Flow's 0.22 of a saturated cover colour already reads in dark, and he has
/// never said otherwise.
struct CobuxAtmosphere: View {
    enum Strength {
        case card, reading, ground

        /// Light-theme stops. `scripts/check-contrast.py` reads THIS property
        /// by name and shape (`case .x: n`), so it keeps that shape.
        var top: Double {
            switch self { case .card: 0.22; case .reading: 0.10; case .ground: 0.10 }
        }
        var bottom: Double {
            switch self { case .card: 0.08; case .reading: 0.04; case .ground: 0.04 }
        }

        /// Dark-theme stops. Only `.ground` differs from light -- see the
        /// type's doc comment for why the other two must not.
        var darkTop: Double {
            switch self { case .card: 0.22; case .reading: 0.10; case .ground: 0.26 }
        }
        var darkBottom: Double {
            switch self { case .card: 0.08; case .reading: 0.04; case .ground: 0.10 }
        }

        func top(dark: Bool) -> Double { dark ? darkTop : top }
        func bottom(dark: Bool) -> Double { dark ? darkBottom : bottom }
    }

    let accent: Color
    var strength: Strength = .card

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        LinearGradient(
            colors: [accent.opacity(strength.top(dark: dark)),
                     Color.cobuxBackground,
                     accent.opacity(strength.bottom(dark: dark))],
            startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: accent)
    }
}
