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
/// - `.ground`: Journal, and since P9 every tab room (Library, Wisdom, Quiz,
///   More, via `CobuxGround`) -- the color is the paper. Same as `.reading`
///   in light; in dark it is the one strength that stays VISIBLE.
/// - `.room`: Chat in dark -- a thread hue leaning toward crimson, strong
///   enough to be seen and weak enough for an hour of reading. Identical to
///   `.reading` in light.
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
///
/// Why `.room` exists rather than Chat simply taking `.ground` in dark: the
/// journal's wash is always crimson, so 0.26 was measured against one hue.
/// Chat's wash is the open thread's cover colour, and the seed shelf holds
/// 121 of them, cream to navy. Measured with the same arithmetic over every
/// seed cover, blended half-way toward crimson (`ChatView.atmosphereAccent`):
/// `CobuxMuted` on the worst wash (#FEE9BC, a cream cover) reads 4.64:1 at a
/// dark top of 0.18 and 4.24:1 at 0.22 -- so 0.18 is the strongest stop that
/// keeps every thread's secondary type above the 4.5:1 floor. Today's
/// `.reading` at 0.10 has that same cover at 4.54:1, so this is no worse
/// than the ground he already reads on, and visible where 0.10 was not.
struct CobuxAtmosphere: View {
    enum Strength {
        case card, reading, ground, room

        /// Light-theme stops. `scripts/check-contrast.py` reads THIS property
        /// by name and shape (`case .x: n`), so it keeps that shape.
        var top: Double {
            switch self { case .card: 0.22; case .reading: 0.10; case .ground: 0.10; case .room: 0.10 }
        }
        var bottom: Double {
            switch self { case .card: 0.08; case .reading: 0.04; case .ground: 0.04; case .room: 0.04 }
        }

        /// Dark-theme stops. Only `.ground` and `.room` differ from light --
        /// see the type's doc comment for why the other two must not.
        var darkTop: Double {
            switch self { case .card: 0.22; case .reading: 0.10; case .ground: 0.26; case .room: 0.18 }
        }
        var darkBottom: Double {
            switch self { case .card: 0.08; case .reading: 0.04; case .ground: 0.10; case .room: 0.08 }
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

/// The ground every tab room stands on: in dark, the journal's crimson wash
/// at `.ground`; in light, the flat paper -- light mode is untouched by P9.
///
/// Rajan, 12 Sep, on the journal list in dark: "the red black theme i tested
/// in the journal section super cool. make similar ui consistency in the
/// whole app". Until now that wash lived only under the journal
/// (`JournalListView.JournalGround`), and Library, Wisdom, Quiz and More each
/// painted a flat near-black -- five rooms in one building, one of them
/// warm. This is the same wash at the same numbers, named once so the tabs
/// cannot drift from the journal or from each other. Lists keep their inset
/// cards: a `List` caller hides only the list's own backdrop
/// (`.scrollContentBackground(.hidden)`), never the rows.
///
/// Sits in the design system rather than in a feature so `ThemePreference
/// .crimson` -- which is nothing more than forcing the dark scheme -- gets
/// every room for free.
struct CobuxGround: View {
    /// What light mode paints. The flat paper for a screen that already
    /// painted it (Library); `.clear` for a screen that never painted a
    /// ground of its own, so light stays exactly what it was.
    var light: Color = .cobuxBackground

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .dark {
            CobuxAtmosphere(accent: Color.cobuxCrimson, strength: .ground)
        } else {
            light
        }
    }
}

extension View {
    /// `CobuxGround` under a screen that never painted a ground of its own --
    /// a `List` on the system's grouped backdrop, a bare `ScrollView`. In
    /// dark the list's own backdrop steps aside so the wash shows through
    /// (rows keep their inset cards -- `.scrollContentBackground` hides the
    /// list's ground, never the cells); in light nothing changes, down to
    /// the grouped grey the inset cards sit on.
    func cobuxRoomGround() -> some View {
        modifier(CobuxRoomGroundModifier())
    }
}

private struct CobuxRoomGroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(colorScheme == .dark ? .hidden : .automatic)
            .background { CobuxGround(light: .clear) }
    }
}
