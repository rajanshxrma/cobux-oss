import SwiftUI
import CoreMotion

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
/// **And it answers a touch (61).** Not the old tap sweep -- that acknowledged
/// a tap that opened nothing, and it is what killed the animation (see
/// `SigilMark`). A finger resting on the mark pulls the rings toward it and
/// wakes the ring under it; lifting lets them settle back. The tap still opens
/// the dialog, from the `.onTapGesture` on this wrapper, exactly as before:
/// the press is a *simultaneous* gesture inside the mark and never claims the
/// touch.
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

/// The mark itself: the rose curves, the light crossing them, and the slow
/// float. Split out of `CobuxSigilView` for one reason, and it is the whole
/// reason the animation used to die.
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
///
/// **Alive, not slow; and it answers the hand and the phone (61).** His words
/// on 60: *"i love how the user's cobux rings are now moving but they are
/// still moving slow and it's not too interactive, make it more beautiful
/// moving and real."* Four changes, none of which touch the barrier:
///
/// - The periods come down to seconds (breath 2.9–8.9 s, turn 5.3–16.7 s,
///   both still primes, in tenths), the amplitudes go up (±7 %, ±12°), and
///   each ring's centre drifts on a slow circle of its own (±2 %, 11–47 s)
///   so the rings move as one cluster rather than a set of dials.
/// - A finger on the mark pulls every ring toward it -- a soft `1/(1+d)`
///   pull, capped at 6 % of the mark -- and the ring under the finger
///   breathes faster and brighter for as long as it is held. Lifting eases
///   everything back over ~0.8 s with a slight overshoot. The gesture lives in
///   `SigilTouchSurface`, a child with its own `@GestureState`, and the values
///   it produces go into `SigilLiveInput`, a plain reference box in `@State`
///   that the Canvas reads per tick. Nothing the finger does is SwiftUI state
///   of THIS view, so this body is never re-evaluated by a touch; the one
///   exception is under Reduce Motion (`reduceMotionTouching`), where nothing
///   is animating and a body pass costs nothing.
/// - The phone's tilt shifts the cluster by up to ±3 % (`SigilTilt`: one
///   `CMMotionManager` at 20 Hz, shared by every mark on screen, acquired on
///   appear and released on disappear, backgrounding, or Reduce Motion).
/// - The band is no longer a plate. See `ambientBand`.
///
/// **Cost.** The rose profile of each strand is time-invariant, so it is now
/// tabulated once per snapshot (`StrandGeometry.profile`), and the rotation
/// is applied as a 2×2 matrix against a shared unit circle: the 260-point
/// path costs no trigonometry at all per frame, where before it cost three
/// calls per point. Per strand per frame there are now six trig calls
/// (breath, turn, the drift's sine and cosine, and the turn's sine and
/// cosine), plus one table lookup for the ring under the band and, only
/// while a finger is down, one `atan2` and one lookup for the ring under the
/// finger. The frame is built once per tick and cached on `SigilLiveInput`,
/// so the mask Canvas that carries the light strokes the SAME paths without
/// rebuilding them.
private struct SigilMark: View, Equatable {
    let snapshot: DeltaLedger.Snapshot
    let height: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    /// Reduce Motion is a hard gate (`CobuxMotion`), not a slowdown: the band
    /// is not built, the float does not travel, the strands' clock is paused
    /// with their amplitudes at zero, and the tilt sensor is never started. A
    /// light that crawls is worse than a still one. The lean still happens --
    /// a finger on the mark is his own motion, not the app's -- but with no
    /// spring: it follows the finger and lets go instantly.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var driftPhase = false
    @State private var breathPhase = false
    /// Everything the finger and the phone feed the Canvas. A reference, not
    /// observable, deliberately: see the "Alive, not slow" note above.
    @State private var live = SigilLiveInput()
    /// Set ONLY under Reduce Motion, where the clock is otherwise paused and
    /// a touch has to be able to wake it; never touched when motion is on.
    @State private var reduceMotionTouching = false

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
    /// The Canvas redraws thirty times a second, so anything that is not
    /// pure arithmetic has to be out of the loop before it starts: the three
    /// hashed bytes are already decoded into petals, phase and wobble and
    /// then into a 261-entry radius profile; the colour is built rather than
    /// re-built; and the three rates are `2π / period`, so a frame does one
    /// multiply and one `sin` per motion. The per-frame body of the loop
    /// touches nothing but this array, the unit-circle tables and the clock.
    private struct StrandGeometry {
        /// `0.55 + wobble * sin(petals * θ + phase)` for θ over the 260 steps
        /// of the path, inclusive of the closing point.
        let profile: [Double]
        let hue: Double
        let brightness: Double
        let alpha: Double
        let color: Color
        /// Radians per second for the breath, the turn and the drift.
        let breathRate: Double
        let turnRate: Double
        let driftRate: Double
        /// Where in its cycle this strand sits relative to the others.
        let offset: Double

        /// The base colour, or a brighter one for the ring the band or the
        /// finger is on. A boost of 0.15 is the band's glint; the held ring
        /// gets up to 0.25. Built only when there is a boost to build.
        func shade(boost: Double) -> Color {
            guard boost > 0.005 else { return color }
            return Color(hue: hue,
                         saturation: 0.55,
                         brightness: min(1, brightness + boost * 0.5),
                         opacity: min(1, alpha * (1 + boost)))
        }

        /// The ring's radius factor at a world angle, as a table lookup: no
        /// trigonometry. `angle` is relative to the ring's own turn.
        func radiusFactor(atAngle angle: Double) -> Double {
            let twoPi = 2 * Double.pi
            var wrapped = angle.truncatingRemainder(dividingBy: twoPi)
            if wrapped < 0 { wrapped += twoPi }
            let index = Int(wrapped / twoPi * Double(profile.count - 1))
            return profile[min(max(index, 0), profile.count - 1)]
        }
    }

    /// Prime periods, in seconds -- primes in tenths now, so they can sit in
    /// the range he can actually see. 58's 7–47 s breath was *"still moving
    /// slow"*; the breath is now 2.9–8.9 s and the turn 5.3–16.7 s, and no
    /// two strands ever fall into step: the pattern repeats only at the
    /// product of the primes in play, which for any real mark is longer than
    /// he will own the phone. The strand index picks a pair, so neighbouring
    /// strands are never on the same clock. The drift is slower (11–47 s) and
    /// picks its period two places along, so a strand's breath and drift are
    /// never on related clocks either.
    private static let breathPeriods: [Double] = [2.9, 3.1, 3.7, 4.3, 4.7, 5.3, 5.9, 6.7, 7.1, 7.9, 8.3, 8.9]
    private static let turnPeriods: [Double] = [5.3, 6.1, 7.1, 7.9, 8.9, 9.7, 10.7, 11.3, 12.7, 13.7, 14.9, 16.7]
    private static let driftPeriods: [Double] = [11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53]
    /// The golden angle, so the phase offsets never bunch up either.
    private static let goldenAngle = 2.399963229728653

    private static let breathAmplitude = 0.07
    private static let turnAmplitude = 12.0 * .pi / 180
    /// Of the mark's radius: the drift of each ring's centre, the phone's
    /// tilt, and the most a finger can pull a ring.
    private static let driftAmplitude = 0.02
    private static let tiltAmplitude = 0.03
    private static let pullCap = 0.06
    /// The ring under the finger: extra breath on a 1.3 s cycle, and up to a
    /// quarter brighter, both scaled by how settled the press is.
    private static let heldBreath = 0.03
    private static let heldBreathRate = 2 * Double.pi / 1.3
    private static let heldGlow = 0.25
    /// The ring under the band's peak brightens by this much as it crosses.
    private static let bandGlint = 0.15

    /// The band's crossing, shared with `ambientBand` so the Canvas can tell
    /// which ring the light is on at any instant without reading the
    /// animation (which it cannot): the same period, the same tilt, the same
    /// travel, and a start time recorded when the crossing is (re)started.
    private static let bandPeriod = 7.0
    private static let bandTiltDegrees = 18.0

    /// The path's resolution, and the unit circle at that resolution: the one
    /// place per-point trigonometry happens, once per process.
    private static let steps = 260
    private static let unitCos: [Double] = (0...steps).map { cos(Double($0) / Double(steps) * 2 * .pi) }
    private static let unitSin: [Double] = (0...steps).map { sin(Double($0) / Double(steps) * 2 * .pi) }

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
            let hue = (baseHue + Double(strand) * 0.012).truncatingRemainder(dividingBy: 1)
            let petals = Double(2 + Int(b % 7))
            let phase = Double(c) / 255.0 * 2 * .pi
            let wobble = 0.30 + Double(d) / 255.0 * 0.25
            let alpha = 0.10 + Double(strands - strand) / Double(strands) * 0.16
            let profile = (0...Self.steps).map { step -> Double in
                let theta = Double(step) / Double(Self.steps) * 2 * .pi
                return 0.55 + wobble * sin(petals * theta + phase)
            }
            return StrandGeometry(
                profile: profile,
                hue: hue,
                brightness: brightness,
                alpha: alpha,
                color: Color(hue: hue, saturation: 0.55, brightness: brightness, opacity: alpha),
                breathRate: 2 * .pi / Self.breathPeriods[strand % Self.breathPeriods.count],
                turnRate: 2 * .pi / Self.turnPeriods[strand % Self.turnPeriods.count],
                driftRate: 2 * .pi / Self.driftPeriods[(strand + 2) % Self.driftPeriods.count],
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
    /// The band's start is recorded on the same turn, so the Canvas can model
    /// where the crossing is and brighten the ring under it.
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
        let live = self.live
        Task { @MainActor in
            driftPhase = true
            breathPhase = true
            live.bandStart = Date.timeIntervalSinceReferenceDate
        }
    }

    /// Hold the shared tilt sensor exactly while this mark is on screen, the
    /// scene is active and motion is allowed -- never in the background, and
    /// never under Reduce Motion. Balanced against `SigilTilt`'s holder count
    /// through `live.holdsTilt`, so every path in and out is one acquire or
    /// one release.
    private func syncTilt(onScreen: Bool? = nil) {
        if let onScreen { live.onScreen = onScreen }
        let wanted = live.onScreen && !reduceMotion && scenePhase == .active
        guard wanted != live.holdsTilt else { return }
        live.holdsTilt = wanted
        if wanted {
            SigilTilt.shared.acquire()
        } else {
            SigilTilt.shared.release()
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
        // once at rest -- not slowed, not faded, still -- and wakes only while
        // a finger is on it, to follow the finger. Paused when the scene is
        // not active as well, for the same reason the deck's carousel cancels
        // its task on backgrounding: nothing here may tick for a screen nobody
        // is looking at.
        let still = reduceMotion
        let paused = still ? !reduceMotionTouching : scenePhase != .active
        // ONE clock for every strand. `TimelineView(.animation)` rather than a
        // `repeatForever` phase, because a Canvas cannot read an animated
        // value without its closure re-running, and the only thing that
        // re-runs it is this timeline. Capped at 30 Hz.
        return livingRings(geometry: geometry, still: still, paused: paused, layer: .rings)
            .frame(height: height)
            .overlay(ambientBand(geometry: geometry, paused: paused))
            .overlay(SigilTouchSurface(live: live) { down in
                // Only under Reduce Motion is a touch SwiftUI state of this
                // view: the clock is paused there and has to be woken, and
                // there is no animation running for a body pass to disturb.
                if reduceMotion { reduceMotionTouching = down }
            })
            .clipped()
            // Floating, the way he described it: a slow breath, three points of
            // travel, the same idiom as the Flow button's float.
            .offset(y: reduceMotion ? 0 : (breathPhase ? -3 : 3))
            .animation(reduceMotion ? nil
                       : .easeInOut(duration: 3.4).repeatForever(autoreverses: true),
                       value: breathPhase)
            .onAppear {
                restartAmbientMotion()
                syncTilt(onScreen: true)
            }
            .onDisappear { syncTilt(onScreen: false) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { restartAmbientMotion() }
                syncTilt()
            }
            .onChange(of: reduceMotion) { _, _ in syncTilt() }
    }

    private enum RingLayer {
        /// The rings themselves: a wide translucent glow under a fine core.
        case rings
        /// The same strokes in white, as the mask the band's light falls
        /// through.
        case lightMask
    }

    /// The timeline and the Canvas, used twice: once for the rings, once as
    /// the mask that confines the band's light to them. Both read the one
    /// wall clock, quantised to the 30 Hz tick so the two Canvases share one
    /// cached frame per tick rather than each building the paths.
    private func livingRings(geometry: [StrandGeometry], still: Bool, paused: Bool, layer: RingLayer) -> some View {
        let live = self.live
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { timeline in
            // Wall-clock phase, not time-since-appear: the strands are at the
            // same point in their cycles whether the row is scrolled back into
            // view or the dialog opens over it, so the larger mark in the
            // dialog is visibly the SAME mark, mid-breath, and nothing ever
            // snaps to a start pose.
            let t = still ? 0 : (timeline.date.timeIntervalSinceReferenceDate * 30).rounded(.down) / 30
            Canvas { context, size in
                let frame = Self.tickFrame(at: t, size: size, geometry: geometry, still: still, live: live)
                for index in geometry.indices {
                    let path = frame.paths[index]
                    switch layer {
                    case .rings:
                        // The inner glow: the same path, twice the width, at
                        // 40 % of the ring's own alpha, under the core. A
                        // wider translucent stroke rather than `.blur`, which
                        // would rasterise every ring off-screen per frame.
                        let color = geometry[index].shade(boost: frame.boosts[index])
                        context.stroke(path, with: .color(color.opacity(0.4)), lineWidth: 2.4)
                        context.stroke(path, with: .color(color), lineWidth: 1.1)
                    case .lightMask:
                        context.stroke(path, with: .color(.white), lineWidth: 2.4)
                    }
                }
            }
        }
    }

    /// One tick's worth of rings: the paths, and how much brighter each ring
    /// is than its base colour.
    fileprivate struct Frame {
        let key: Double
        let size: CGSize
        let paths: [Path]
        let boosts: [Double]
    }

    /// The frame for this tick, built once and shared by both Canvases. Not
    /// cached under Reduce Motion, where the clock reads zero and the only
    /// thing that changes between frames is the finger.
    private static func tickFrame(at t: Double, size: CGSize, geometry: [StrandGeometry],
                                  still: Bool, live: SigilLiveInput) -> Frame {
        if !still, let cached = live.frame, cached.key == t, cached.size == size {
            return cached
        }
        let built = buildFrame(at: t, size: size, geometry: geometry, still: still, live: live)
        if !still { live.frame = built }
        return built
    }

    private static func buildFrame(at t: Double, size: CGSize, geometry: [StrandGeometry],
                                   still: Bool, live: SigilLiveInput) -> Frame {
        let count = geometry.count
        let radius = Double(min(size.width, size.height)) * 0.38
        let centerX = Double(size.width) / 2
        let centerY = Double(size.height) / 2
        // The phone's tilt moves the whole cluster, against the tilt, so the
        // rings read as sitting behind the glass rather than painted on it.
        // Zero whenever the sensor is off, which includes Reduce Motion.
        let tilt = SigilTilt.shared
        let tiltX = still ? 0 : -tilt.x * tiltAmplitude * radius
        let tiltY = still ? 0 : -tilt.y * tiltAmplitude * radius

        struct Transient {
            var breath: Double
            var turn: Double
            var cx: Double
            var cy: Double
            var boost: Double
        }
        var transients = [Transient]()
        transients.reserveCapacity(count)
        for strand in geometry {
            // The breath scales the ring; the turn rotates the whole rose; the
            // drift carries its centre on a slow circle. All sines of the one
            // clock at this strand's own rates and offset -- nothing here is a
            // per-strand animation, and under Reduce Motion all of it is zero.
            let breath = still ? 1 : 1 + breathAmplitude * sin(t * strand.breathRate + strand.offset)
            let turn = still ? 0 : turnAmplitude * sin(t * strand.turnRate + strand.offset * 1.7)
            var cx = centerX + tiltX
            var cy = centerY + tiltY
            if !still {
                let drift = t * strand.driftRate + strand.offset * 2.3
                cx += driftAmplitude * radius * cos(drift)
                cy += driftAmplitude * radius * sin(drift)
            }
            transients.append(Transient(breath: breath, turn: turn, cx: cx, cy: cy, boost: 0))
        }

        // The band's light: the ring whose edge sits under the band's peak
        // brightens as it crosses, so the sheen and the rings read as one
        // object. The crossing is modelled from the recorded start, the same
        // travel and the same period as the overlay animates.
        if !still, let crossing = bandCrossing(at: t, size: size, bandStart: live.bandStart) {
            var nearest = -1
            var nearestGap = Double.infinity
            for index in 0..<count {
                let factor = geometry[index].radiusFactor(atAngle: crossing.angle - transients[index].turn)
                let gap = abs(crossing.distance - radius * transients[index].breath * factor)
                if gap < nearestGap {
                    nearestGap = gap
                    nearest = index
                }
            }
            let reach = radius * 0.10
            if nearest >= 0, nearestGap < reach {
                transients[nearest].boost += bandGlint * (1 - nearestGap / reach)
            }
        }

        // The finger: every ring leans toward it, by a soft 1/(1+d) that is
        // capped at `pullCap`; the ring under it breathes faster and glows.
        // Under Reduce Motion the lean is instantaneous and there is no extra
        // breath -- the rings are still.
        let lean: (point: CGPoint, strength: Double)? = still
            ? live.touch.map { (point: $0, strength: 1.0) }
            : live.lean(at: t)
        if let lean, lean.strength > 0.001 {
            let px = Double(lean.point.x)
            let py = Double(lean.point.y)
            var gaps = [Double](repeating: .infinity, count: count)
            var nearest = -1
            var nearestGap = Double.infinity
            for index in 0..<count {
                let dx = px - transients[index].cx
                let dy = py - transients[index].cy
                let distance = (dx * dx + dy * dy).squareRoot()
                guard distance > 0.5 else { continue }
                let angle = atan2(dy, dx)
                let factor = geometry[index].radiusFactor(atAngle: angle - transients[index].turn)
                let gap = abs(distance - radius * transients[index].breath * factor)
                gaps[index] = gap
                if gap < nearestGap {
                    nearestGap = gap
                    nearest = index
                }
                let pull = pullCap * radius * lean.strength / (1 + distance / radius)
                transients[index].cx += dx / distance * pull
                transients[index].cy += dy / distance * pull
            }
            // Which ring is "under" the finger is decided while the finger is
            // down, with hysteresis so two rings breathing past each other do
            // not trade the glow back and forth; the choice is kept through
            // the release so the ease-back fades from the same ring.
            if live.touch != nil, nearest >= 0 {
                var held = nearest
                if live.heldStrand >= 0, live.heldStrand < count,
                   gaps[live.heldStrand] < nearestGap + radius * 0.05 {
                    held = live.heldStrand
                }
                live.heldStrand = held
            }
            let held = (live.heldStrand >= 0 && live.heldStrand < count) ? live.heldStrand : nearest
            if held >= 0 {
                transients[held].boost += heldGlow * lean.strength
                if !still {
                    transients[held].breath += heldBreath * lean.strength * sin(t * heldBreathRate)
                }
            }
        }

        // The paths: the tabulated profile against the shared unit circle,
        // rotated by the turn as a 2×2 matrix. No trigonometry per point.
        var paths = [Path]()
        paths.reserveCapacity(count)
        var boosts = [Double]()
        boosts.reserveCapacity(count)
        for index in 0..<count {
            let transient = transients[index]
            let profile = geometry[index].profile
            let scaled = radius * transient.breath
            let cosTurn = cos(transient.turn)
            let sinTurn = sin(transient.turn)
            var path = Path()
            for step in 0...steps {
                let r = scaled * profile[step]
                let ux = unitCos[step]
                let uy = unitSin[step]
                let point = CGPoint(x: transient.cx + r * (ux * cosTurn - uy * sinTurn),
                                    y: transient.cy + r * (uy * cosTurn + ux * sinTurn))
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            paths.append(path)
            boosts.append(transient.boost)
        }
        return Frame(key: t, size: size, paths: paths, boosts: boosts)
    }

    /// Where the band's peak line is at `t`: its distance from the mark's
    /// centre and the direction (from the centre) it lies in, in the Canvas's
    /// own coordinates. Mirrors `ambientBand` exactly: a gradient across the
    /// diagonal, rotated by the band's tilt, offset along x from `-travel` to
    /// `+travel` linearly over one period and snapping back.
    private static func bandCrossing(at t: Double, size: CGSize, bandStart: Double)
        -> (angle: Double, distance: Double)? {
        guard bandStart > 0, t >= bandStart else { return nil }
        let travel = Double(size.width) * 1.15
        let phase = ((t - bandStart) / bandPeriod).truncatingRemainder(dividingBy: 1)
        let offset = -travel + 2 * travel * phase
        let normal = atan2(Double(size.height), Double(size.width)) + bandTiltDegrees * .pi / 180
        let signed = offset * cos(normal)
        return (angle: signed >= 0 ? normal : normal + .pi, distance: abs(signed))
    }

    /// The light crossing forever — his reference, verbatim: *"on the Flow
    /// button there's like this animation, the highlight, and it's constantly
    /// moving."* This is that same construction (`FlowLaunchButton.sheen`),
    /// kept at the sigil's own diagonal and on a 7-second crossing, because
    /// this sits on a page he reads rather than on a button he is looking for.
    ///
    /// **Not a plate (61).** On 60: *"the white plate kinda thing that floats
    /// over the user's cobux rings animation is lovely animation but still
    /// strange and kinda weird and kinda obviously present to the user's eyes,
    /// it's not intertwined in the UI and made beautiful."* It was a white
    /// gradient the width of the whole diagonal, sweeping over the mark and
    /// the empty space around it alike -- light on a surface, not through the
    /// rings. Now it is narrow (28 % of the diagonal, feathered to nothing at
    /// both edges), tinted with the mark's own hue instead of white, and MASKED
    /// to the ring strokes and their glow by a second Canvas of the same
    /// frame: the light exists only where a ring is, so what he sees is the
    /// rings lighting up as it passes, and nothing at all in between. In dark
    /// mode it adds light (`plusLighter`); in light mode, where adding light to
    /// a violet stroke on white would only fade it, it deepens the stroke
    /// instead. The peak alpha is higher than the old 9 % because it now lands
    /// only on strokes a point or two wide -- the total light on screen is a
    /// fraction of what the plate put there.
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
    /// shape as `FlowLaunchButton.ground`. The mask is its own subtree: the
    /// timeline inside it re-runs the mask's Canvas per tick and nothing
    /// else, so the gradient's `repeatForever` offset is never re-applied.
    @ViewBuilder private func ambientBand(geometry: [StrandGeometry], paused: Bool) -> some View {
        if !reduceMotion {
            let tint = Color(hue: baseHue.truncatingRemainder(dividingBy: 1),
                             saturation: 0.45,
                             brightness: colorScheme == .dark ? 1.0 : 0.5)
            let peak = colorScheme == .dark ? 0.55 : 0.45
            GeometryReader { proxy in
                let travel = proxy.size.width * 1.15
                LinearGradient(stops: [
                    .init(color: tint.opacity(0), location: 0.36),
                    .init(color: tint.opacity(peak * 0.35), location: 0.44),
                    .init(color: tint.opacity(peak), location: 0.5),
                    .init(color: tint.opacity(peak * 0.35), location: 0.56),
                    .init(color: tint.opacity(0), location: 0.64),
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .rotationEffect(.degrees(Self.bandTiltDegrees))
                    .offset(x: driftPhase ? travel : -travel)
                    .animation(.linear(duration: Self.bandPeriod).repeatForever(autoreverses: false),
                               value: driftPhase)
            }
            .mask {
                livingRings(geometry: geometry, still: false, paused: paused, layer: .lightMask)
            }
            .blendMode(colorScheme == .dark ? .plusLighter : .normal)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - What the finger and the phone feed the mark

/// Everything that changes between ticks and is not the clock: the finger,
/// the band's start, the held ring, and the cached frame. A plain reference
/// held in `@State`, and deliberately NOT `@Observable`: the Canvas reads it
/// inside the timeline closure, which already re-runs every tick, and no
/// change to it may cause `SigilMark`'s body to run -- that body carries the
/// band's `repeatForever`, and a body pass inside a gesture's transaction is
/// exactly how the mark used to die. Nothing here is SwiftUI state.
private final class SigilLiveInput: @unchecked Sendable {
    /// Whether the owning mark is currently in the hierarchy.
    var onScreen = false
    /// Whether the owning mark currently holds `SigilTilt`.
    var holdsTilt = false
    /// When the band's crossing was last (re)started, on the reference clock.
    var bandStart: TimeInterval = 0
    /// The ring under the finger, decided with hysteresis in the frame
    /// builder; -1 for none.
    var heldStrand = -1
    /// The last built frame, shared by the ring Canvas and the light mask.
    var frame: SigilMark.Frame?

    /// The finger, in the mark's own points, while it is down.
    private(set) var touch: CGPoint?
    private var lastTouch = CGPoint.zero
    private var pressedAt: TimeInterval = 0
    private var releasedAt: TimeInterval = -1
    private var strengthAtRelease = 0.0

    /// How long the press takes to settle in, in seconds.
    private static let rampIn = 0.18
    /// The ease-back: `e^(-3.5u) · cos(3u)` dips to −4.6 % of the pull at
    /// 0.76 s and is under 1.5 % by 1.2 s -- back in about 0.8 s with a
    /// slight overshoot. Cut to zero at 1.6 s so the cache key stays the
    /// clock alone once it is over.
    private static let releaseSpan = 1.6

    func press(at point: CGPoint) {
        if touch == nil {
            pressedAt = Date.timeIntervalSinceReferenceDate
            heldStrand = -1
        }
        touch = point
        lastTouch = point
    }

    func release() {
        guard touch != nil else { return }
        let now = Date.timeIntervalSinceReferenceDate
        strengthAtRelease = pressStrength(at: now)
        touch = nil
        releasedAt = now
    }

    /// Where the rings lean and how hard, at `t`, or nil at rest.
    func lean(at t: TimeInterval) -> (point: CGPoint, strength: Double)? {
        if touch != nil { return (point: lastTouch, strength: pressStrength(at: t)) }
        let strength = releaseStrength(at: t)
        return strength == 0 ? nil : (point: lastTouch, strength: strength)
    }

    private func pressStrength(at t: TimeInterval) -> Double {
        let u = min(1, max(0, (t - pressedAt) / Self.rampIn))
        return u * u * (3 - 2 * u)
    }

    private func releaseStrength(at t: TimeInterval) -> Double {
        guard releasedAt >= 0 else { return 0 }
        let u = t - releasedAt
        guard u >= 0, u < Self.releaseSpan else { return 0 }
        return strengthAtRelease * exp(-3.5 * u) * cos(3 * u)
    }

    deinit {
        if holdsTilt { SigilTilt.shared.release() }
    }
}

/// The press, as a child with its own gesture state.
///
/// `@GestureState` rather than `onChanged`/`onEnded`, because a
/// `DragGesture(minimumDistance: 0)` inside a `Form` is cancelled -- not
/// ended -- the moment the list starts to scroll, and `onEnded` does not fire
/// for a cancellation. `@GestureState` resets on both, so the rings can never
/// be left leaning at a finger that has gone. It is a *simultaneous* gesture:
/// the row's `.onTapGesture` on the wrapper still sees every tap and still
/// opens the dialog, and the list still scrolls.
///
/// Its state is its own: a change to `pressed` re-evaluates this body -- a
/// clear colour -- and nothing above it.
private struct SigilTouchSurface: View {
    let live: SigilLiveInput
    let onPress: (Bool) -> Void

    @GestureState private var pressed = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .updating($pressed) { value, state, _ in
                        state = true
                        live.press(at: value.location)
                    }
            )
            .onChange(of: pressed) { _, down in
                if !down { live.release() }
                onPress(down)
            }
            .accessibilityHidden(true)
    }
}

/// One `CMMotionManager` for every mark on screen -- the row and the dialog
/// both hold one while the dialog is up -- started by the first holder and
/// stopped by the last. 20 Hz, on the main queue, low-pass filtered twice: a
/// fast filter (~0.12 s) for smoothness and a slow baseline (~6 s) the tilt
/// is measured against, so the cluster answers a movement and then settles,
/// rather than sitting permanently off-centre at whatever angle he holds the
/// phone. Skips silently where device motion is unavailable; `x` and `y`
/// simply stay zero.
private final class SigilTilt: @unchecked Sendable {
    static let shared = SigilTilt()

    /// Unit tilt, −1…1 on each axis, ±1 at about 20° from the baseline.
    private(set) var x = 0.0
    private(set) var y = 0.0

    private let manager = CMMotionManager()
    private var holders = 0
    private var baseRoll = 0.0
    private var basePitch = 0.0
    private var primed = false

    private init() {}

    func acquire() {
        holders += 1
        guard holders == 1, manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        primed = false
        manager.deviceMotionUpdateInterval = 1.0 / 20
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.ingest(roll: motion.attitude.roll, pitch: motion.attitude.pitch)
        }
    }

    func release() {
        holders = max(0, holders - 1)
        guard holders == 0 else { return }
        manager.stopDeviceMotionUpdates()
        x = 0
        y = 0
        primed = false
    }

    private func ingest(roll: Double, pitch: Double) {
        if !primed {
            baseRoll = roll
            basePitch = pitch
            primed = true
        }
        baseRoll += (roll - baseRoll) * 0.008
        basePitch += (pitch - basePitch) * 0.008
        let targetX = max(-1, min(1, (roll - baseRoll) / 0.35))
        let targetY = max(-1, min(1, (pitch - basePitch) / 0.35))
        x += (targetX - x) * 0.3
        y += (targetY - y) * 0.3
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
            // moving -- and it answers the finger here too, the press being
            // inside the mark. Its own `.equatable()` barrier, for the same
            // reason as in the row: the dialog's fade and scale must not
            // re-target the band's endless crossing.
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
