import SwiftUI

/// One shared empty-state shape for the whole app. Before this, Library,
/// Quiz Home, Wisdom, and Chat each built their own: a raw `Color.indigo`
/// custom `VStack`, SwiftUI's stock `ContentUnavailableView`, a third
/// bespoke `emptyState` computed property, and a fourth near-identical one
/// in Chat -- four different mechanisms for the same UI moment. Not a
/// cosmetic preference: this is exactly the class of undetectable drift
/// 2.0.0 exists to close off (see `BookTitleText` for the same fix already
/// applied to book-title rendering).
struct CobuxEmptyStateView<Action: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder var action: () -> Action

    init(icon: String, title: String, message: String, @ViewBuilder action: @escaping () -> Action = { EmptyView() }) {
        self.icon = icon
        self.title = title
        self.message = message
        self.action = action
    }

    var body: some View {
        VStack(spacing: 20) {
            Circle()
                .fill(Color.cobuxAccent.opacity(0.12))
                .frame(width: 76, height: 76)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Color.cobuxAccent.opacity(0.75))
                )

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3)
                    .fontWeight(.medium)
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
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
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
            .background(Color.cobuxAccent)
            .foregroundStyle(.white)
            .clipShape(Capsule())
        }
    }
}
