import SwiftUI

struct TagBadge: View {
    let tag: String

    var body: some View {
        Text(tag)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.cobuxAccent.opacity(0.2))
            .foregroundStyle(Color.cobuxAccent)
            .clipShape(Capsule())
    }
}
