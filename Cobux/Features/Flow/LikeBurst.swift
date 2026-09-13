import SwiftUI

/// The double-tap like animation.
///
/// Rajan: "I love the kind of little animation that we have but I want it to be
/// much more better, like Instagram or TikTok have better liking animations, and
/// it should be a red heart."
///
/// What those apps actually do, and what the old version was missing:
/// - the heart is RED, not white. The colour is the confirmation; a white heart
///   on a dark card reads as a generic flash.
/// - it OVERSHOOTS and settles, rather than scaling linearly to its final size.
///   The overshoot is what makes it feel like a physical pop.
/// - it arrives slightly rotated and straightens, so it lands rather than
///   appears.
/// - a ring expands past it and fades, which is what gives the impression of
///   force even though nothing actually moves outward.
/// - particles fly out on the beat, then fall slightly under gravity.
///
/// Deliberately non-interactive throughout, so it can never swallow a tap or
/// block a swipe mid-flight.
struct LikeBurst: View {
    /// Bumped by the caller on each double-tap. Changing it restarts the whole
    /// animation, so a second tap re-fires instead of being ignored.
    let trigger: Int

    @State private var heartScale: CGFloat = 0.1
    @State private var heartOpacity: Double = 0
    @State private var heartTilt: Double = -18
    @State private var ringScale: CGFloat = 0.3
    @State private var ringOpacity: Double = 0
    @State private var particlesOut: CGFloat = 0
    @State private var particlesOpacity: Double = 0

    private static let particleCount = 8

    var body: some View {
        ZStack {
            // The expanding ring. Behind the heart, so the heart always reads
            // as the subject and the ring as the force around it.
            Circle()
                .stroke(
                    LinearGradient(colors: [Color(hex: "#FF2D55"), Color(hex: "#FF6B8A")],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 6
                )
                .frame(width: 120, height: 120)
                .scaleEffect(ringScale)
                .opacity(ringOpacity)

            ForEach(0..<Self.particleCount, id: \.self) { i in
                let angle = Double(i) / Double(Self.particleCount) * 2 * .pi
                Circle()
                    .fill(Color(hex: i.isMultiple(of: 2) ? "#FF2D55" : "#FFB3C1"))
                    .frame(width: 7, height: 7)
                    .offset(
                        x: cos(angle) * particlesOut,
                        // The +0.18 is gravity: particles drift down as they
                        // travel, so the burst falls apart instead of staying a
                        // perfect circle, which is what stops it looking clip-art.
                        y: sin(angle) * particlesOut + particlesOut * 0.18
                    )
                    .opacity(particlesOpacity)
            }

            Image(systemName: "heart.fill")
                .font(.system(size: 108))
                .foregroundStyle(
                    LinearGradient(colors: [Color(hex: "#FF3B5C"), Color(hex: "#E0114F")],
                                   startPoint: .top, endPoint: .bottom)
                )
                .shadow(color: Color(hex: "#FF2D55").opacity(0.45), radius: 18)
                .rotationEffect(.degrees(heartTilt))
                .scaleEffect(heartScale)
                .opacity(heartOpacity)
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in fire() }
    }

    private func fire() {
        heartScale = 0.1; heartOpacity = 0; heartTilt = -18
        ringScale = 0.3; ringOpacity = 0
        particlesOut = 0; particlesOpacity = 0

        // Pop: a low damping fraction is what produces the overshoot-and-settle
        // that reads as physical rather than animated.
        withAnimation(.spring(response: 0.28, dampingFraction: 0.42)) {
            heartScale = 1.0
            heartOpacity = 1
            heartTilt = 0
        }
        withAnimation(.easeOut(duration: 0.42)) {
            ringScale = 1.9
            ringOpacity = 0.75
        }
        withAnimation(.easeOut(duration: 0.5)) {
            particlesOut = 78
            particlesOpacity = 0.95
        }
        // Fade everything on a slight stagger, so the heart is the last thing
        // to leave rather than the whole composition vanishing at once.
        withAnimation(.easeOut(duration: 0.32).delay(0.34)) {
            ringOpacity = 0
            particlesOpacity = 0
        }
        withAnimation(.easeIn(duration: 0.3).delay(0.5)) {
            heartOpacity = 0
            heartScale = 1.22
        }
    }
}
