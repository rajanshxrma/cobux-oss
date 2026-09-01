import SwiftUI
import SwiftData

/// Everything liked from Flow, in one place.
///
/// Rajan's ask: *"there should be a like option on flow and the likes should
/// saved in a section in more."* Flow is a fast, scrolling feed — the only
/// interaction light enough to survive mid-scroll is a single tap, and without
/// somewhere for those taps to land, liking would be a gesture that quietly
/// went nowhere. This is the somewhere.
///
/// Deliberately distinct from the existing surfaces it might look like:
/// `personalNote` requires stopping to write something, and `isReminder` is a
/// legacy notification flag. Liking claims nothing except "I want to find this
/// again," which is exactly why it's cheap enough to actually use.
struct LikedHighlightsView: View {
    @Environment(\.modelContext) private var modelContext
    // Sorted newest-first by when the highlight was saved. `isLiked` has no
    // timestamp of its own on purpose — one Bool is the whole feature, and a
    // separate `likedAt` would be a schema change earning very little.
    @Query(filter: #Predicate<Highlight> { $0.isLiked == true },
           sort: \Highlight.dateAdded, order: .reverse)
    private var liked: [Highlight]

    var body: some View {
        Group {
            if liked.isEmpty {
                CobuxEmptyStateView(
                    icon: "heart",
                    title: "Nothing liked yet",
                    message: "Tap Like on any highlight in Flow and it'll collect here."
                )
            } else {
                List {
                    ForEach(liked) { highlight in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(highlight.text)
                                .font(.body)
                            if let title = highlight.book?.title {
                                Text(title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        // Swipe to unlike rather than a destructive delete —
                        // this list is a view onto highlights that still exist
                        // in the library; removing one here must never delete
                        // the highlight itself.
                        .swipeActions {
                            Button("Unlike") {
                                highlight.isLiked = false
                            }
                            .tint(.gray)
                        }
                    }
                }
            }
        }
        .navigationTitle("Liked")
        .navigationBarTitleDisplayMode(.inline)
    }
}
