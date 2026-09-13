import SwiftUI

/// Shown once, ever, after the first Flow session ends.
///
/// iOS gives no API to add a widget on someone's behalf — the widget gallery is
/// the only route, and it is several non-obvious steps. So the only honest
/// tactic is desire plus a clear how, offered at the one moment desire actually
/// exists: he has just finished swiping through the app's best surface.
///
/// Rajan asked for exactly this ("there should be a feature wehre the user in
/// the beggining is tempted to add the ios big widget at least minimum some
/// tactic") in the same breath as rejecting a checkmark, so the shape matters:
/// shown once, dismissed forever by ANY route, never repeated, never badged,
/// never mentioned in a notification. A second ask would be a nag.
///
/// There is ONE button, and it is the one that says yes. The "Maybe later"
/// beside it is gone on his instruction -- *"just remove the maybe later.
/// That's not something that I want users to do. I want users to actually set
/// that thing up."* Deferral is still available, it is just no longer
/// ADVERTISED: both presentations are ordinary `.sheet`s with no
/// `.interactiveDismissDisabled`, so a swipe down still closes this and still
/// dismisses it forever -- ContentView's `onDismiss` sets `hasSeenWidgetInvite`
/// on every route, and More's binding clears itself. Nothing traps the user;
/// nothing invites them to put it off either.
///
/// Scrolls, and the mock shrinks. This was a fixed `VStack` around a 300pt
/// mock with no `ScrollView` -- the exact clipping class already fixed twice
/// (onboarding, the volume reader): on a short screen or a large Dynamic
/// Type size the buttons at the bottom were pushed off the sheet. Same
/// `OnboardingPageScroll` wrapper as onboarding's pages.
struct WidgetInviteView: View {
    /// The quote shown in the mock — a real one he just saw, when there is one.
    var quote: String
    var bookTitle: String
    var accentHex: String
    /// True while the caller has not finished reading the library yet, so the
    /// mock must not assert a quote as being from it. Defaults to false, which
    /// is the honest answer for a caller that resolves its sample BEFORE
    /// presenting (ContentView, which only presents once it has one).
    ///
    /// The mock still draws at full size and keeps its shape -- only the words
    /// are withheld, via `.redacted`. A sheet that states a real-looking line
    /// from a library it has not opened is the same class of falsehood as the
    /// Journal widget's "N days of writing"
    /// (R-2026-09-journal-widget-claims-days-of-writing), on a smaller surface.
    var isAwaitingSample: Bool = false
    var onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { Color(hex: accentHex) }

    var body: some View {
        OnboardingPageScroll { size in
            VStack(spacing: 22) {
                Spacer(minLength: 0)

                // A faithful mock, deliberately not an idealised one. An enhanced
                // preview is a small lie the Home Screen exposes within the hour.
                // At most 300pt tall, and never more than a third of the page, so
                // the steps and both buttons always fit beneath it.
                widgetMock(height: min(300, max(180, size.height * 0.34)))
                    .frame(maxWidth: 300)
                    .shadow(color: .black.opacity(0.12), radius: 18, y: 8)

                VStack(spacing: 8) {
                    Text("Keep a line on your Home Screen")
                        .font(CobuxTypography.display(colorScheme, size: 24, weight: .semibold))
                        .multilineTextAlignment(.center)
                    Text("The big Cobux widget shows one — tap it for the next.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 10) {
                    step(1, "Touch and hold your Home Screen.")
                    step(2, "Tap **Edit**, then **Add Widget**.")
                    step(3, "Search **Cobux**, swipe to the **large** size, then tap **Add Widget**.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(CobuxSpacing.cardPadding)
                .background(Color.cobuxSurface,
                            in: RoundedRectangle(cornerRadius: CobuxRadius.card, style: .continuous))

                // The other two widgets, named once. This screen is the app's
                // only widget-education surface and it is also re-openable
                // forever from More, yet it described exactly one of the three
                // -- so Quick Check, which answers a due card from the Home
                // Screen without launching anything, was reachable only by
                // scrolling the iOS gallery and noticing it. One quiet line,
                // deliberately below the steps and above nothing: the single
                // call to action stays the large widget, which is the one the
                // mock above is showing.
                Text("Two more sit beside it in the gallery: **Quick Check**, to answer a card that's due without opening Cobux, and **Journal**, one tap from a blank page.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                Spacer(minLength: 0)

                // ONE button, and it is the one that says yes. See the type's
                // doc comment: "Maybe later" was removed on his instruction,
                // and a swipe down is what deferral looks like now -- available,
                // never advertised.
                Button(action: onDismiss) {
                    // On the book's own cover colour -- so the type is
                    // whichever of white / the dark ink reads on it, not
                    // white on, say, `#A3B29F` (2.2:1).
                    Text("I'll set it up")
                        .frame(maxWidth: .infinity)
                        .cobuxPrimaryPill(tint: accent)
                }
                .buttonStyle(.plain)
            }
            .padding(CobuxSpacing.screenMargin)
        }
        .background(Color.cobuxBackground.ignoresSafeArea())
        // The app's standard full-bleed-sheet close control (`EbbView` sets the
        // pattern), and it is here BECAUSE "Maybe later" is not.
        //
        // With that button gone a swipe down became the only way out, and this
        // sheet is one that scrolls -- it was made to, so a short screen or a
        // large text size cannot clip it (R-2026-09-widget-invite-clips) -- and
        // a sheet's swipe-to-dismiss is only recognised from the TOP of its
        // scroll. That is precisely the case where the exit could be missed.
        //
        // An X is not a second ask and not the thing he removed: it says
        // nothing, promises no reminder, offers no deferral, and does exactly
        // what the swipe already does. What he objected to was a button
        // INVITING the user to put it off, and there is now none.
        //
        // Sits in a reserved top inset rather than an `.overlay`: an overlay
        // takes part in no layout, so the first scrolled card could slide
        // under the X at a large text size and the tap would be ambiguous.
        // `safeAreaInset` gives the X its own band above the scroll, still
        // fixed in place however far the page has been scrolled.
        .safeAreaInset(edge: .top, alignment: .trailing, spacing: 0) {
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(accent)
                .frame(width: 18)
            Text(.init(text))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The systemLarge widget, as it actually renders.
    private func widgetMock(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "quote.opening")
                .font(.title3)
                .foregroundStyle(accent)
            // This face must stay in step with `CobuxWidgetEntryView.largeBody`
            // -- the mock's whole contract is that it is faithful, not
            // idealised, and for the length of build 55/56 it was neither: the
            // widget's quote had been flattened to plain system type while this
            // mock went on promising the italic serif. Both are the italic serif
            // again. If one changes, change the other in the same commit.
            Text(quote)
                .font(.system(.body, design: .serif))
                .italic()
                .lineLimit(8)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .redacted(reason: isAwaitingSample ? .placeholder : [])
            Spacer(minLength: 0)
            Rectangle()
                .fill(accent.opacity(0.3))
                .frame(height: 1)
            Text(bookTitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .redacted(reason: isAwaitingSample ? .placeholder : [])
        }
        .padding(16)
        .frame(height: height)
        .background(
            LinearGradient(colors: [accent.opacity(0.16), Color(.systemBackground)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
