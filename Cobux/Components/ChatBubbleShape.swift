import SwiftUI

/// An iMessage-style bubble outline: a rounded rectangle with a small curved
/// tail at the bottom corner — trailing corner for outgoing messages,
/// leading corner for incoming ones.
struct ChatBubbleShape: Shape {
    enum Direction {
        case left
        case right
    }

    let direction: Direction

    func path(in rect: CGRect) -> Path {
        direction == .left ? leadingTailPath(in: rect) : trailingTailPath(in: rect)
    }

    private func trailingTailPath(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        var path = Path()

        path.move(to: CGPoint(x: 25, y: height))
        path.addLine(to: CGPoint(x: 20, y: height))
        path.addCurve(to: CGPoint(x: 0, y: height - 20),
                       control1: CGPoint(x: 8, y: height),
                       control2: CGPoint(x: 0, y: height - 8))
        path.addLine(to: CGPoint(x: 0, y: 20))
        path.addCurve(to: CGPoint(x: 20, y: 0),
                       control1: CGPoint(x: 0, y: 8),
                       control2: CGPoint(x: 8, y: 0))
        path.addLine(to: CGPoint(x: width - 20, y: 0))
        path.addCurve(to: CGPoint(x: width, y: 20),
                       control1: CGPoint(x: width - 8, y: 0),
                       control2: CGPoint(x: width, y: 8))
        path.addLine(to: CGPoint(x: width, y: height - 11))
        path.addCurve(to: CGPoint(x: width + 10, y: height),
                       control1: CGPoint(x: width, y: height - 1),
                       control2: CGPoint(x: width + 2, y: height))
        path.addLine(to: CGPoint(x: width + 0.05, y: height))
        path.addCurve(to: CGPoint(x: width - 12, y: height - 4),
                       control1: CGPoint(x: width - 4.5, y: height + 0.5),
                       control2: CGPoint(x: width - 9, y: height - 1))
        path.addCurve(to: CGPoint(x: width - 25, y: height),
                       control1: CGPoint(x: width - 16, y: height),
                       control2: CGPoint(x: width - 20, y: height))
        path.closeSubpath()
        return path
    }

    private func leadingTailPath(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        var path = Path()

        path.move(to: CGPoint(x: width - 25, y: height))
        path.addLine(to: CGPoint(x: width - 20, y: height))
        path.addCurve(to: CGPoint(x: width, y: height - 20),
                       control1: CGPoint(x: width - 8, y: height),
                       control2: CGPoint(x: width, y: height - 8))
        path.addLine(to: CGPoint(x: width, y: 20))
        path.addCurve(to: CGPoint(x: width - 20, y: 0),
                       control1: CGPoint(x: width, y: 8),
                       control2: CGPoint(x: width - 8, y: 0))
        path.addLine(to: CGPoint(x: 20, y: 0))
        path.addCurve(to: CGPoint(x: 0, y: 20),
                       control1: CGPoint(x: 8, y: 0),
                       control2: CGPoint(x: 0, y: 8))
        path.addLine(to: CGPoint(x: 0, y: height - 11))
        path.addCurve(to: CGPoint(x: -10, y: height),
                       control1: CGPoint(x: 0, y: height - 1),
                       control2: CGPoint(x: -2, y: height))
        path.addLine(to: CGPoint(x: -0.05, y: height))
        path.addCurve(to: CGPoint(x: 12, y: height - 4),
                       control1: CGPoint(x: 4.5, y: height + 0.5),
                       control2: CGPoint(x: 9, y: height - 1))
        path.addCurve(to: CGPoint(x: 25, y: height),
                       control1: CGPoint(x: 16, y: height),
                       control2: CGPoint(x: 20, y: height))
        path.closeSubpath()
        return path
    }
}
