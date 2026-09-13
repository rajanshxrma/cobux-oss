import SwiftUI

/// Full-screen celebration for a crossed streak milestone (7/30/100/365).
/// Presented as a `ContentView` overlay via `StreakCelebrationCenter`; the
/// caller clears the pending milestone on dismiss.
struct MilestoneCelebrationView: View {
    let days: Int
    let onDismiss: () -> Void
    /// Reduce Motion is a hard gate (`CobuxMotion`): the flame does not
    /// bounce and the confetti does not fall. The card, the words and the
    /// caller's haptic still land the moment.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var headline: String {
        switch days {
        case 7: "One full week"
        case 30: "A whole month"
        case 100: "One hundred days"
        case 365: "An entire year"
        default: "\(days) days"
        }
    }

    private var message: String {
        switch days {
        case 7: "Seven straight days of showing up. This is how a habit starts."
        case 30: "Thirty days in a row. What you're building is real now."
        case 100: "A hundred consecutive days of learning. Almost nobody does this."
        case 365: "Every single day, for a year. Extraordinary."
        default: "Another milestone down."
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 18) {
                flame

                Text("\(days)-day streak")
                    .font(.title.bold())

                Text(headline)
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text(message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                if StreakTracker.freezeBank > 0 {
                    Label("\(StreakTracker.freezeBank) streak freeze\(StreakTracker.freezeBank == 1 ? "" : "s") banked", systemImage: "snowflake")
                        .font(.caption)
                        // No CobuxColor equivalent for the ice/freeze pairing this represents;
                        // a single decorative use, not app chrome drifting off the token set.
                        // swiftlint:disable:next no_raw_system_color
                        .foregroundStyle(.cyan)
                }

                Button {
                    onDismiss()
                } label: {
                    Text("Keep Going")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.cobuxWarning)
            }
            .padding(28)
            .cobuxGlassCard()
            .padding(.horizontal, 36)

            // ConfettiView gates itself on Reduce Motion too; the explicit
            // check here keeps the intent legible at the call site.
            if !reduceMotion {
                ConfettiView()
                    .ignoresSafeArea()
            }
        }
    }

    /// The flame bounces on the milestone -- unless Reduce Motion is on, in
    /// which case it simply stands there. `.bounce` with `value:` is the
    /// discrete form; there is no `isActive:` on it, so the gate is a branch.
    @ViewBuilder
    private var flame: some View {
        let glyph = Image(systemName: "flame.fill")
            .font(.system(size: 52))
            .foregroundStyle(Color.cobuxWarning.gradient)
        if reduceMotion {
            glyph
        } else {
            glyph.symbolEffect(.bounce, value: days)
        }
    }
}
