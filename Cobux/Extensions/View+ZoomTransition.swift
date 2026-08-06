import SwiftUI

/// The "card → hero" zoom Phase 5 asked for, done via iOS 18's purpose-built
/// `.navigationTransition(.zoom)`/`.matchedTransitionSource` pair rather than
/// the older cross-view `matchedGeometryEffect` hack -- `matchedGeometryEffect`
/// doesn't actually animate across a `NavigationStack` push boundary on its
/// own; `.zoom` is Apple's own replacement for exactly this case. Deployment
/// target is iOS 17, so every use is `#available`-gated and falls back to a
/// plain push with no zoom on iOS 17 -- the same behavior the app already
/// had, not a regression.
extension View {
    @ViewBuilder
    func cobuxZoomTransitionSource(id: UUID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// `namespace` is optional so a destination view can be reached from
    /// multiple places (e.g. `BookDetailView` from both the Library grid and
    /// a highlight search result) and only zoom when it was actually reached
    /// from a source that registered one.
    @ViewBuilder
    func cobuxZoomTransitionDestination(id: UUID, in namespace: Namespace.ID?) -> some View {
        if #available(iOS 18.0, *), let namespace {
            self.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}
