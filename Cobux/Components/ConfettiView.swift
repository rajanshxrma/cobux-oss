import SwiftUI

/// A one-shot confetti burst for celebration moments (quiz completion,
/// streak milestones). Pure `TimelineView(.animation)` + `Canvas` — no
/// particle framework, capped at 120 particles and ~2.5 seconds so it stays
/// comfortable on the oldest supported hardware (Utkarsh's iPhone 13), then
/// stops rendering entirely so the timeline doesn't tick forever underneath
/// a long-lived results screen. Purely decorative, so it's transparent to
/// hit-testing and hidden from accessibility.
struct ConfettiView: View {
    private struct Particle {
        let x: CGFloat          // horizontal start, 0...1 of width
        let launchVelocity: CGFloat
        let drift: CGFloat      // horizontal drift per second, in widths
        let spin: Double        // radians per second
        let size: CGFloat
        let color: Color
        let delay: Double
    }

    private static let palette: [Color] = [.orange, .pink, .purple, .blue, .teal, .yellow, .green]
    private static let duration: Double = 2.5

    private let particles: [Particle] = (0..<120).map { _ in
        Particle(
            x: .random(in: 0...1),
            launchVelocity: .random(in: 320...620),
            drift: .random(in: -0.18...0.18),
            spin: .random(in: -6...6),
            size: .random(in: 5...9),
            color: palette.randomElement() ?? .orange,
            delay: .random(in: 0...0.35)
        )
    }

    private let startDate = Date()
    @State private var finished = false

    var body: some View {
        Group {
            if !finished {
                TimelineView(.animation) { timeline in
                    Canvas { canvasContext, size in
                        let elapsed = timeline.date.timeIntervalSince(startDate)
                        for particle in particles {
                            let t = elapsed - particle.delay
                            guard t > 0, t < Self.duration else { continue }

                            // Simple ballistic arc from the bottom edge:
                            // launch up, gravity pulls back down through the
                            // bottom of the screen.
                            let gravity: CGFloat = 700
                            let y = size.height - (particle.launchVelocity * t - 0.5 * gravity * t * t)
                            let x = particle.x * size.width + particle.drift * size.width * t
                            guard y < size.height + 20 else { continue }

                            let fade = max(0, 1 - (t / Self.duration))
                            let rect = CGRect(x: -particle.size / 2, y: -particle.size / 2,
                                              width: particle.size, height: particle.size * 0.62)

                            var transform = CGAffineTransform(translationX: x, y: y)
                            transform = transform.rotated(by: particle.spin * t)
                            canvasContext.opacity = fade
                            canvasContext.fill(
                                Path(roundedRect: rect, cornerRadius: 1.5).applying(transform),
                                with: .color(particle.color)
                            )
                            canvasContext.opacity = 1
                        }
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .task {
                    try? await Task.sleep(for: .seconds(Self.duration + 0.5))
                    finished = true
                }
            }
        }
    }
}
