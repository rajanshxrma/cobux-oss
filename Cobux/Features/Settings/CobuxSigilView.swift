import SwiftUI

/// The mark that stands for everything accumulated here.
///
/// Rajan asked for a section that reflects what the app has collected of him,
/// which *"a user cannot click on"* — a treasure, not a dashboard. So this is
/// deliberately none of the obvious things:
///
/// - **Not a number.** A number is a score, and a score grades him. Worse, a
///   number that plateaus becomes an obligation — the exact frame he deleted a
///   guilt notification over.
/// - **Not a decodable pattern.** Rings-per-month or thickness-by-volume would
///   be a stats page wearing velvet, and would rebuild the census and monument
///   vetoes in graphics. The seed is hashed precisely so nothing here can be
///   read back as a quantity.
/// - **Not a page you navigate to.** What a tap opens is a dialog that arrives
///   in the MIDDLE of the screen — never a sheet, and never a push. His words,
///   after living with the version that grew in place: *"when we click on it,
///   it just expands. I actually wanted it to open ... for example when we go
///   deeper, it opens up a whole section from bottom, but I wanted to open up
///   in the middle, like when we click on something it opens a dialog box."*
///   So "Go deeper" keeps the bottom, and the mark gets the centre — the two
///   gestures stay legibly different. That is still not the thing he vetoed:
///   what he vetoed was a page BEHIND it, a stats screen you navigate to and
///   come back to. This opens over the same screen, says what the mark is made
///   of, and closes. Nothing quantified, nothing to come back to.
///
/// It is also **alive on its own, and it never stops**. The shimmer used to
/// happen only when you touched it, which taught exactly the wrong thing about
/// a mark that opens nothing. Rajan, on seeing that: *"the flotiaing mirrio
/// type thingy is lovely but a little cofising ai tshuld be live and floting
/// and the animation wookring the whole tinme than on click."* And then, on
/// the version that went ambient but died: *"it's still not life. I mean it is
/// life, but eventually it stops. I wanted it to just keep going, just keep
/// being life. For example on the Flow button there's like this animation, the
/// highlight, and it's constantly moving."* See `SigilMark` for why it used to
/// stop and what makes it endless now.
///
/// What it does do is **only ever grow**, in coarse steps, over months and
/// years — so a quiet week costs him nothing and a quiet month is invisible.
struct CobuxSigilView: View {
    let snapshot: DeltaLedger.Snapshot

    /// Purely local, never persisted — so the screen always opens with the
    /// mark at rest and this never becomes a state he has to manage.
    @State private var showingDialog = false

    var body: some View {
        SigilMark(snapshot: snapshot, height: 190)
            // THE FIX FOR "eventually it stops", half one. See `SigilMark`'s
            // own note for the mechanism; the barrier has to be installed
            // here, at the parent, because only the parent can promise not to
            // re-evaluate the child.
            .equatable()
            .contentShape(Rectangle())
            .onTapGesture { showingDialog = true }
            .background(dialogHost)
            .accessibilityLabel("Your Cobux. A mark grown from everything you have written and asked here.")
            .accessibilityHint("Double tap to open it")
            .accessibilityAddTraits(.isButton)
    }

    /// An inert host for the presentation, deliberately NOT the mark itself.
    ///
    /// `.fullScreenCover` slides up from the bottom, which is the one thing he
    /// contrasted the ask against ("when we go deeper, it opens up a whole
    /// section from bottom"). Suppressing that means disabling animation for
    /// the update that presents it — and `disablesAnimations` applies to the
    /// whole subtree it is attached to, which would freeze the mark's own
    /// endless animation the first time he opened the dialog. That is exactly
    /// the bug being fixed here, so the presentation is hung off a sibling
    /// `Color.clear` that has nothing to freeze. The cover then arrives with
    /// no motion of its own and `CobuxSigilDialog` does the centred
    /// scale-and-fade itself.
    ///
    /// `fullScreenCover` rather than an `.overlay`, because this row lives in
    /// a `Form`: an overlay would be clipped to the row's own bounds, and a
    /// dialog that opens "in the middle" has to be presented at the window.
    private var dialogHost: some View {
        Color.clear
            .allowsHitTesting(false)
            .fullScreenCover(isPresented: $showingDialog) {
                CobuxSigilDialog(snapshot: snapshot) { showingDialog = false }
                    // Clear, so Settings stays visible behind the dialog's own
                    // scrim -- a centred dialog over the screen it belongs to,
                    // not a new screen.
                    .presentationBackground(.clear)
            }
            .transaction(value: showingDialog) { $0.disablesAnimations = true }
    }
}

// MARK: - The mark

/// The mark itself: the rose curves, the band of light crossing them, and the
/// slow float. Split out of `CobuxSigilView` for one reason, and it is the
/// whole reason the animation used to die.
///
/// **Why it stopped.** Both ambient loops are `repeatForever` animations bound
/// to a `@State` flag that flips once on appear — the same idiom as
/// `FlowLaunchButton`, which he correctly points at as the thing that never
/// stops. The difference was never the animation; it was the body. The Flow
/// button's body has no state that ever changes after appear, so it is never
/// re-evaluated and its offsets are never re-applied. The sigil's body carried
/// the tap state, so every single tap re-evaluated it INSIDE a transaction
/// (`withAnimation(.easeInOut(duration: 0.6))` for the tap sweep, plus an
/// `.animation(_:value: expanded)` wrapped around the whole stack) — and
/// re-applying an animatable offset inside a live transaction re-targets it,
/// replacing the in-flight `repeatForever` with a 0.6s ease to where it
/// already was. `driftPhase` was still `true` afterwards, so nothing could
/// ever restart it: the mark was dead from the first tap onward, permanently.
/// "Eventually it stops" was the tap.
///
/// **Why it cannot stop now.** Three things, in order of how much they matter:
///
/// 1. The mark is its own view whose only inputs are an `Equatable` snapshot
///    and a height, and the parent applies `.equatable()`. A parent update
///    with unchanged inputs does not re-evaluate this body at all, so no
///    parent transaction can reach the offsets. The tap state that used to do
///    the damage now lives entirely on the other side of that barrier.
/// 2. The tap sweep and the tap wash are gone. They existed to acknowledge a
///    tap that opened nothing; the tap opens something now, so the one global
///    `withAnimation` in this file is deleted rather than merely fenced off.
/// 3. The band's animation is a literal constant, not a `reduceMotion ? nil :`
///    ternary — the whole band is conditionally absent instead, exactly as
///    `FlowLaunchButton.ground` does it.
///
/// The band and the float still cost nothing per frame: one state flip, then
/// `repeatForever`, and SwiftUI interpolates two offsets in the render server
/// without ever re-running this body. Nothing the Canvas draws reads those
/// phase flags.
///
/// **The strands move too (58), and that reverses a ruling written here.**
/// This comment used to say *deliberately NOT a `TimelineView(.animation)`*,
/// because rebuilding the rose curves tens of times a second for a decoration
/// was the exact cost the Flow button's sheen was rewritten to stop paying.
/// Then he looked at the live version: *"it's good that it's live now;
/// however the purple circle animation — the thing over it is moving, but I
/// wanted the circles to move as well."* There is no way to move what a
/// Canvas draws without redrawing it, so the redraw is the one cost this
/// buys, and everything around it is kept off the frame: the hashed geometry,
/// the periods and the colours are derived ONCE per snapshot into a flat
/// array (`StrandGeometry`, and see the six-subscripts-per-strand note in
/// `body`), the tick is capped at 30 Hz, and the timeline is paused under
/// Reduce Motion and whenever the scene is not active. One clock drives every
/// strand -- not one animation per strand -- and it drives only the Canvas:
/// the timeline's content closure is what re-runs per tick, never this body,
/// so the `.equatable()` barrier around the band and the float holds exactly
/// as before. Off screen, the system suspends all of it with the view; there
/// is still no timer anywhere.
private struct SigilMark: View, Equatable {
    let snapshot: DeltaLedger.Snapshot
    let height: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    /// Reduce Motion is a hard gate (`CobuxMotion`), not a slowdown: the band
    /// is not built, the float does not travel, and the strands' clock is
    /// paused with their amplitudes at zero. A light that crawls is worse
    /// than a still one.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var driftPhase = false
    @State private var breathPhase = false

    /// Only the two real inputs. The property wrappers below them are not
    /// comparable and are not identity — SwiftUI delivers environment changes
    /// through `EquatableView` regardless, which is why a theme change or
    /// switching Reduce Motion on still lands.
    static func == (lhs: SigilMark, rhs: SigilMark) -> Bool {
        lhs.snapshot == rhs.snapshot && lhs.height == rhs.height
    }

    private var strands: Int { DeltaLedger.strands(words: snapshot.words) }
    private var seed: [UInt8] { DeltaLedger.seed(for: snapshot) }

    /// Everything the draw loop needs about one strand, derived once.
    ///
    /// The Canvas now redraws thirty times a second, so anything that is not
    /// pure trigonometry has to be out of the loop before it starts: the three
    /// hashed bytes are already decoded into petals, phase and wobble; the
    /// colour is built rather than re-built; and the two rates are `2π /
    /// period`, so a frame does one multiply and one `sin` per motion. The
    /// per-frame body of the loop touches nothing but this array and the
    /// clock.
    private struct StrandGeometry {
        let petals: Double
        let phase: Double
        let wobble: Double
        let color: Color
        /// Radians per second for the breath and for the turn.
        let breathRate: Double
        let turnRate: Double
        /// Where in its cycle this strand sits relative to the others.
        let offset: Double
    }

    /// Prime periods, in seconds. *"I wanted the circles to move as well"* --
    /// so each strand breathes (radius ±3.5%) and turns (±4°) on its own
    /// period, and the periods are primes so no two strands ever fall into
    /// step: the pattern repeats only at the product of the primes in play,
    /// which for any real mark is longer than he will own the phone. Short
    /// enough to be caught from the corner of the eye, long enough never to
    /// read as a pulse. The strand index picks a pair, so neighbouring
    /// strands are never on the same clock.
    private static let breathPeriods: [Double] = [7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47]
    private static let turnPeriods: [Double] = [13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59]
    /// The golden angle, so the phase offsets never bunch up either.
    private static let goldenAngle = 2.399963229728653

    private static let breathAmplitude = 0.035
    private static let turnAmplitude = 4.0 * .pi / 180

    /// Derived once per snapshot, outside the timeline, so the redraw never
    /// pays for it. The SHA-per-subscript bug this file records (see `body`)
    /// was 66 hashes per pass at eleven strands; at thirty passes a second it
    /// would have been two thousand a second. Hence an array, not a closure.
    private func strandGeometry(seed: [UInt8], strands: Int, baseHue: Double) -> [StrandGeometry] {
        let seedCount = seed.count
        let brightness = colorScheme == .dark ? 0.95 : 0.72
        return (0..<strands).map { strand in
            let b = seed[(strand * 3) % seedCount]
            let c = seed[(strand * 3 + 1) % seedCount]
            let d = seed[(strand * 3 + 2) % seedCount]
            // A rose curve per strand, its petal count and phase drawn from
            // hashed bytes so nothing about the shape can be decoded into how
            // much he has written.
            let hue = baseHue + Double(strand) * 0.012
            return StrandGeometry(
                petals: Double(2 + Int(b % 7)),
                phase: Double(c) / 255.0 * 2 * .pi,
                wobble: 0.30 + Double(d) / 255.0 * 0.25,
                color: Color(hue: hue.truncatingRemainder(dividingBy: 1),
                             saturation: 0.55,
                             brightness: brightness)
                    .opacity(0.10 + Double(strands - strand) / Double(strands) * 0.16),
                breathRate: 2 * .pi / Self.breathPeriods[strand % Self.breathPeriods.count],
                turnRate: 2 * .pi / Self.turnPeriods[strand % Self.turnPeriods.count],
                offset: Double(strand) * Self.goldenAngle)
        }
    }

    private var baseHue: Double {
        // Stays inside the app's own violet-to-blue band, drifting with the
        // centroid rather than spanning the wheel -- it should always look like
        // Cobux, never like a mood ring.
        0.62 + DeltaLedger.hueAngle(for: snapshot) * 0.14
    }

    /// Restart the two ambient loops from a genuinely stopped state.
    ///
    /// `.equatable()` closes the way the animation used to die, but a
    /// `repeatForever` is still not self-healing on its own: the flag it is
    /// bound to is already `true`, so if the render server ever drops the
    /// animation — this row scrolled far enough out of the `Form` to be torn
    /// down and rebuilt with its state intact, a low-power transition, a long
    /// spell in the background — `onAppear` firing again would change nothing
    /// and the mark would be frozen with no way back short of relaunching.
    /// So restarting is a real reset: force the flags false with animation
    /// disabled, then set them true on the next runloop turn so SwiftUI sees
    /// an actual change to animate. Cheap (two Bools), and it runs on appear
    /// AND on every return to active.
    ///
    /// Reduce Motion short-circuits it: there is nothing to restart, and
    /// flipping the flags would only cost a body evaluation.
    @MainActor private func restartAmbientMotion() {
        guard !reduceMotion else { return }
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            driftPhase = false
            breathPhase = false
        }
        Task { @MainActor in
            driftPhase = true
            breathPhase = true
        }
    }

    var body: some View {
        // HOISTED OUT OF THE DRAW LOOP, and out of the Canvas closure entirely.
        //
        // `seed` was a computed property: every read ran
        // `DeltaLedger.seed(for:)`, which reads a 32-byte salt from
        // `UserDefaults` and then hashes five integers with SHA256. The draw
        // loop referenced it SIX times per strand -- three subscripts and three
        // `seed.count`s -- so at eleven strands one pass of the Canvas
        // performed 66 SHA256 hashes and 66 `UserDefaults` reads. `baseHue`
        // (an `atan2`) and `strands` (a `log2`) were re-derived per strand for
        // the same reason. This is the first screen of Settings.
        //
        // Read here, in the body and OUTSIDE the timeline below, so the
        // thirty-a-second redraw never repeats any of it: the three are read
        // once each, folded into `geometry`, and the Canvas closure captures
        // the array. This body runs only when `snapshot` changes, which is
        // the only thing any of these depend on.
        let geometry = strandGeometry(seed: seed, strands: strands, baseHue: baseHue)
        // Reduce Motion is the hard gate here as everywhere in this file: the
        // clock is paused AND the amplitudes are zero, so the mark is drawn
        // once at rest -- not slowed, not faded, still. Paused when the scene
        // is not active as well, for the same reason the deck's carousel
        // cancels its task on backgrounding: nothing here may tick for a
        // screen nobody is looking at.
        let still = reduceMotion
        let paused = still || scenePhase != .active
        // ONE clock for every strand. `TimelineView(.animation)` rather than a
        // `repeatForever` phase, because a Canvas cannot read an animated
        // value without its closure re-running, and the only thing that
        // re-runs it is this timeline. Capped at 30 Hz: a drift with a
        // seven-second shortest period gains nothing from 120.
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { timeline in
            // Wall-clock phase, not time-since-appear: the strands are at the
            // same point in their cycles whether the row is scrolled back into
            // view or the dialog opens over it, so the larger mark in the
            // dialog is visibly the SAME mark, mid-breath, and nothing ever
            // snaps to a start pose.
            let t = still ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) * 0.38
                for strand in geometry {
                    // The breath scales the ring; the turn rotates the whole
                    // rose by a few degrees. Both are sines of the one clock
                    // at this strand's own rate and offset -- nothing here is
                    // a per-strand animation, and under Reduce Motion both
                    // sines are of zero.
                    let breath = still ? 1
                        : 1 + Self.breathAmplitude * sin(t * strand.breathRate + strand.offset)
                    let turn = still ? 0
                        : Self.turnAmplitude * sin(t * strand.turnRate + strand.offset * 1.7)
                    let scaled = Double(radius) * breath
                    var path = Path()
                    let steps = 260
                    for step in 0...steps {
                        let theta = Double(step) / Double(steps) * 2 * .pi
                        let r = scaled * (0.55 + strand.wobble * sin(strand.petals * theta + strand.phase))
                        let point = CGPoint(x: center.x + CGFloat(r * cos(theta + turn)),
                                            y: center.y + CGFloat(r * sin(theta + turn)))
                        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color(strand.color), lineWidth: 1.1)
                }
            }
        }
        .frame(height: height)
        .overlay(ambientBand)
        .clipped()
        // Floating, the way he described it: a slow breath, three points of
        // travel, the same idiom as the Flow button's float.
        .offset(y: reduceMotion ? 0 : (breathPhase ? -3 : 3))
        .animation(reduceMotion ? nil
                   : .easeInOut(duration: 3.4).repeatForever(autoreverses: true),
                   value: breathPhase)
        .onAppear { restartAmbientMotion() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { restartAmbientMotion() }
        }
    }

    /// The band of light, crossing forever — his reference, verbatim: *"on the
    /// Flow button there's like this animation, the highlight, and it's
    /// constantly moving."* This is that same construction
    /// (`FlowLaunchButton.sheen`), kept at the sigil's own diagonal and its own
    /// far quieter brightness: 9% white on a 7-second crossing, roughly half
    /// the Flow button's light over nearly twice its period, because this sits
    /// on a page he reads rather than on a button he is looking for.
    ///
    /// The travel is derived from the measured width rather than a literal, so
    /// the band is fully clear of the mark at both ends of the cycle. That
    /// matters with `autoreverses: false`: the reset from one end to the other
    /// is instantaneous, and it is only invisible if there is nothing left on
    /// screen to snap. The old fixed ±260 left a lit edge on any row wider
    /// than 260pt, so the loop had a visible hitch every seven seconds.
    ///
    /// Built only when motion is allowed, which is also what keeps the
    /// animation below a literal constant rather than a ternary — the same
    /// shape as `FlowLaunchButton.ground`.
    @ViewBuilder private var ambientBand: some View {
        if !reduceMotion {
            GeometryReader { proxy in
                let travel = proxy.size.width * 1.15
                LinearGradient(colors: [.clear, .white.opacity(0.09), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .rotationEffect(.degrees(18))
                    .offset(x: driftPhase ? travel : -travel)
                    .animation(.linear(duration: 7).repeatForever(autoreverses: false),
                               value: driftPhase)
            }
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - The dialog

/// What the tap opens: a dialog in the centre of the screen.
///
/// **What is in it, and why.** The old expansion showed one sentence, which is
/// not worth opening anything for. What a mark like this actually leaves you
/// with is a single question — *what am I looking at* — so the dialog answers
/// it in the only honest way available: by naming what the drawing is made of.
/// Every line below is a real property of the code that draws it, not a
/// statistic and not an interpretation:
///
/// - the strand count only ever grows and is floored by a high-water mark, so
///   deleting a chat cannot dock it (`DeltaLedger.snapshot`, `strands`);
/// - the hue drifts with the embedding centroid's direction, which says
///   nothing about the subject (`DeltaLedger.hueAngle`);
/// - the shape is hashed with a device-minted salt precisely so it cannot be
///   read back as a quantity (`DeltaLedger.seed`).
///
/// **What is deliberately not in it.** No counts — not words, entries, chat
/// turns, highlights or keeps — because a census is the thing this whole
/// object exists instead of. No score, no streak, no completion state, no
/// progress toward anything. The one date shown is `firstEntry`, and it is
/// origin rather than duration: "since March 2025" cannot be broken, cannot
/// plateau, and asks nothing of him. It is omitted entirely when there is no
/// entry to date it from.
private struct CobuxSigilDialog: View {
    let snapshot: DeltaLedger.Snapshot
    let onClose: () -> Void

    /// Reduce Motion: the dialog is simply there, at full size, and simply
    /// gone. No scale, no fade — the hard gate from `CobuxMotion` applies to a
    /// presentation exactly as it applies to a decoration.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    /// The same key and the same possessive `SettingsView` already renders at
    /// the top of Settings ("<Name>'s Cobux"). His words, 12 Sep: "where it
    /// says 'Your mark' it should instead say the user's name and then Cobux,
    /// so it shows that's the Cobux we're talking about."
    @AppStorage("cobux.user.displayName") private var displayName: String = ""
    private var dialogTitle: String {
        displayName.isEmpty ? "Your Cobux" : "\(displayName)'s Cobux"
    }

    private var origin: String? {
        guard let first = snapshot.firstEntry else { return nil }
        return "Growing here since \(first.formatted(.dateTime.month(.wide).year()))."
    }

    var body: some View {
        ZStack {
            // Dismissal one: tap anywhere outside. Hidden from VoiceOver,
            // which gets the escape action below and the Close button instead
            // of a full-screen unlabelled target.
            Color.black
                .opacity(shown ? 0.45 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityHidden(true)

            card
                // Anchored in the middle and scaled from it -- the centre
                // arrival he asked for, explicitly not a rise from the bottom.
                .scaleEffect(reduceMotion ? 1 : (shown ? 1 : 0.92))
                .opacity(shown ? 1 : 0)
                .padding(CobuxSpacing.xl)
        }
        // VoiceOver's two-finger scrub, which is what a modal is expected to
        // answer to.
        .accessibilityAction(.escape, close)
        .onAppear {
            guard !reduceMotion else {
                shown = true
                return
            }
            withAnimation(CobuxMotion.flow) { shown = true }
        }
    }

    /// Animate out, then tear the cover down — the cover's own transition is
    /// disabled at the call site, so without this it would vanish on the frame
    /// the fade started.
    private func close() {
        guard !reduceMotion else {
            onClose()
            return
        }
        withAnimation(.easeOut(duration: 0.22)) {
            shown = false
        } completion: {
            onClose()
        }
    }

    /// `ViewThatFits` rather than an unconditional `ScrollView`: a scroll view
    /// expands to whatever height it is offered, which would make the dialog
    /// full-height on a large phone even when the content is short. This hugs
    /// its content when it fits and scrolls when it does not — which it will
    /// not at the larger Dynamic Type sizes, where a fixed dialog would simply
    /// clip the close button off the bottom.
    private var card: some View {
        ViewThatFits(in: .vertical) {
            cardContent
            ScrollView { cardContent }
        }
        .padding(CobuxSpacing.cardPadding)
        .frame(maxWidth: 360)
        // The floating layer, which is exactly what `.cobuxGlassCard()` is
        // scoped to (`View+CobuxGlass`): a panel over content, not a content
        // card. Opaque on iOS 18-25, real glass on 26.
        .cobuxGlassCard()
    }

    private var cardContent: some View {
        VStack(spacing: CobuxSpacing.lg) {
            Text(dialogTitle)
                .font(CobuxTypography.cobuxTitle)

            // The expansion he asked for: the same mark, larger, and still
            // moving. Its own `.equatable()` barrier, for the same reason as
            // in the row -- the dialog's fade and scale must not re-target the
            // band's endless crossing.
            SigilMark(snapshot: snapshot, height: 220)
                .equatable()

            Text("It grows from everything you write and ask here, a little at a time, and never the other way. There is nothing to keep up with — it is just yours.")
                .font(CobuxTypography.cobuxBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: CobuxSpacing.md) {
                part("The strands",
                     "They only ever grow. Nothing you delete ever takes one away.")
                part("The colour",
                     "It drifts with whatever you have been writing about lately, and says nothing about what that is.")
                part("The pattern",
                     "Drawn from a key minted on this device, so no one else's mark can look like yours — and nothing in it can be counted.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let origin {
                Text(origin)
                    .font(CobuxTypography.cobuxCaption)
                    .foregroundStyle(.secondary)
            }

            // Dismissal two: a real control, full width and a real 44pt
            // target, at the bottom rather than as a glyph in the corner --
            // `CobuxRadius` has the note on why a control sitting inside a
            // rounded card's corner arc reads as slipping off it.
            Button(action: close) {
                Text("Close")
                    .font(CobuxTypography.cobuxRowLabel)
                    .foregroundStyle(Color.cobuxAccent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func part(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: CobuxSpacing.xs) {
            Text(title)
                .font(CobuxTypography.cobuxSectionHeader)
            Text(text)
                .font(CobuxTypography.cobuxCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
