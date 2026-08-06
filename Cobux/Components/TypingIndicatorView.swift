import SwiftUI
import Combine

/// A calm, breathing three-dot indicator shown while the AI reply hasn't started streaming yet.
struct TypingIndicatorView: View {
    @State private var phase = 0

    private let dotCount = 3
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<dotCount, id: \.self) { index in
                Circle()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: 7, height: 7)
                    .scaleEffect(phase == index ? 1.0 : 0.6)
                    .opacity(phase == index ? 1.0 : 0.4)
            }
        }
        .padding(.vertical, 4)
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                phase = (phase + 1) % dotCount
            }
        }
    }
}
