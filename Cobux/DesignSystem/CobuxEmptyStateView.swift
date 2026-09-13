import SwiftUI

/// One shared empty-state shape for the whole app. Before this, Library,
/// Quiz Home, Wisdom, and Chat each built their own: a raw `Color.indigo`
/// custom `VStack`, SwiftUI's stock `ContentUnavailableView`, a third
/// bespoke `emptyState` computed property, and a fourth near-identical one
/// in Chat -- four different mechanisms for the same UI moment. Not a
/// cosmetic preference: this is exactly the class of undetectable drift
/// 2.0.0 exists to close off (see `BookTitleText` for the same fix already
/// applied to book-title rendering).
///
/// The headline face was `.title3`/`.medium` until Rajan, testing 53, named
/// the Situations empty state as the one to copy everywhere: *"i loev the ui
/// nad colors and how this is beirtifull dipalyed and eplained... similar
/// should be done."* That screen was the app's LAST hand-rolled empty state,
/// and the reason it read better was one thing this component didn't do: the
/// display face at semibold, the same weight the wordmark gets. Fixing it here
/// rather than copying Situations into a thirteenth caller is the whole point
/// of the component -- one edit, every empty state in the app.
struct CobuxEmptyStateView<Action: View>: View {
    let icon: String
    let title: String
    let message: String
    /// The surface's own hue, for screens that have one (Ebb, Situations).
    /// Defaults to the app accent, which is what every caller rendered before
    /// this existed -- so nothing changes unless a screen asks it to.
    let tint: Color
    @ViewBuilder var action: () -> Action

    @Environment(\.colorScheme) private var colorScheme

    init(icon: String, title: String, message: String, tint: Color = .cobuxAccent, @ViewBuilder action: @escaping () -> Action = { EmptyView() }) {
        self.icon = icon
        self.title = title
        self.message = message
        self.tint = tint
        self.action = action
    }

    /// `CobuxTypography.display`'s rule -- serif in light, system in dark --
    /// expressed against a Dynamic Type text style instead of a fixed point
    /// size. Deliberately not a call to `display(_:size:)`: that returns a
    /// FIXED size, correct for a wordmark, wrong for the one line on a screen
    /// that has nothing else on it, where a reader at an accessibility text
    /// size would be left with 22pt and no way to grow it.
    private var titleFont: Font {
        .system(.title3, design: colorScheme == .dark ? .default : .serif, weight: .semibold)
    }

    var body: some View {
        VStack(spacing: 20) {
            Circle()
                .fill(tint.opacity(0.12))
                .frame(width: 76, height: 76)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(tint.opacity(0.75))
                )

            VStack(spacing: 6) {
                Text(title)
                    .font(titleFont)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            action()
        }
        .padding(.top, 60)
        .transition(.opacity.animation(.easeOut(duration: 0.3)))
    }
}

/// A filled, pill-shaped call to action matching this empty state's own
/// accent -- the shared button treatment `CobuxEmptyStateView` callers use
/// instead of each hand-rolling `.background(.indigo)`/`Capsule()` again.
struct CobuxEmptyStateButton: View {
    let title: String
    let systemImage: String?
    /// Matches the empty state's own `tint` when a screen sets one -- passed
    /// rather than read from the environment because the two are separate
    /// views, and a tinted glyph over an accent-coloured button would be the
    /// exact half-applied look this component exists to prevent.
    let tint: Color
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, tint: Color = .cobuxAccent, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .fontWeight(.semibold)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(tint)
            .foregroundStyle(.white)
            .clipShape(Capsule())
        }
    }
}
