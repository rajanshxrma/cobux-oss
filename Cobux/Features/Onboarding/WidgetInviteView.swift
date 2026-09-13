import SwiftData
import SwiftUI
import UIKit

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
///
/// THE FIRST FRAME IS STATIC (61, his third report of this sheet taking a
/// moment: *"whenever I click on home screen widgets in the more section it
/// takes time for it to load … sometimes it loads right away, sometimes it
/// does not"*). Everything this view draws is a value it was handed -- three
/// strings and a flag -- and its body touches no store, no `@Query`, no
/// `WidgetCenter`, decodes no image (the only images are SF Symbols). What
/// made the open feel uneven was upstream of the sheet, and it is described on
/// `WidgetSampleCache` below: the line for the mock was re-probed on every
/// appearance of More, at exactly the moment the row is tapped, and when it
/// had not answered yet the words snapped in with no animation, which reads
/// as "loading". Now the line comes from a value cache that outlives the tab,
/// and the one case where the sheet is up before the line is -- a cold cache
/// -- draws a neutral placeholder and FADES the words in (`widgetMock`).
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
    /// are withheld, via `.redacted`, in a neutral hue. A sheet that states a
    /// real-looking line from a library it has not opened is the same class
    /// of falsehood as the Journal widget's "N days of writing"
    /// (R-2026-09-journal-widget-claims-days-of-writing), on a smaller surface.
    var isAwaitingSample: Bool
    var onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    /// Resolved once per view value, not once per read: the body used to ask
    /// for `Color(hex:)` six times a frame, each a fresh `Scanner`. Microseconds,
    /// but the sheet's whole contract now is that its first frame does nothing
    /// it does not have to.
    private let accent: Color

    init(quote: String,
         bookTitle: String,
         accentHex: String,
         isAwaitingSample: Bool = false,
         onDismiss: @escaping () -> Void) {
        self.quote = quote
        self.bookTitle = bookTitle
        self.accentHex = accentHex
        self.isAwaitingSample = isAwaitingSample
        self.onDismiss = onDismiss
        self.accent = Color(hex: accentHex)
    }

    /// How long the words take to arrive once the line is known. One beat:
    /// long enough to read as a fill, short enough never to read as a wait.
    private static let fillIn: Animation = .easeOut(duration: 0.3)

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
            // The hue arrives with the line. Value-scoped, so nothing else on
            // the page is ever animated by this.
            .animation(Self.fillIn, value: accentHex)
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

    /// The mock's hue: the book's, once there is a book. Until then a neutral
    /// -- the stand-in's indigo would be presenting a colour as his the same
    /// way redaction stops the words being presented as his.
    private var mockTint: Color { isAwaitingSample ? Color.secondary : accent }

    /// The systemLarge widget, as it actually renders.
    ///
    /// Two layers per line of text, one visible at a time: the words, and a
    /// redacted stand-in of the same shape. `isAwaitingSample` flipping to
    /// false cross-fades them (`fillIn`), so the one case where the sheet is up
    /// before the line is known ends with the words arriving, not appearing.
    /// The frame, the padding, the quote mark, the rule: all drawn on the
    /// first frame either way. Only the words and the hue wait.
    private func widgetMock(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "quote.opening")
                .font(.title3)
                .foregroundStyle(mockTint)
            // This face must stay in step with `CobuxWidgetEntryView.largeBody`
            // -- the mock's whole contract is that it is faithful, not
            // idealised, and for the length of build 55/56 it was neither: the
            // widget's quote had been flattened to plain system type while this
            // mock went on promising the italic serif. Both are the italic serif
            // again. If one changes, change the other in the same commit.
            fading(
                Text(quote)
                    .font(.system(.body, design: .serif))
                    .italic()
                    .lineLimit(8)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            )
            Spacer(minLength: 0)
            Rectangle()
                .fill(mockTint.opacity(0.3))
                .frame(height: 1)
            fading(
                Text(bookTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            )
        }
        .padding(16)
        .frame(height: height)
        .background(
            LinearGradient(colors: [mockTint.opacity(0.16), Color(.systemBackground)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(Self.fillIn, value: isAwaitingSample)
    }

    /// The words, or their redacted stand-in, cross-faded on `isAwaitingSample`.
    /// The stand-in is the same text redacted, so it occupies the same lines
    /// and nothing moves when the real words land.
    private func fading<Line: View>(_ line: Line) -> some View {
        ZStack(alignment: .topLeading) {
            line.opacity(isAwaitingSample ? 0 : 1)
            if isAwaitingSample {
                line
                    .redacted(reason: .placeholder)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - The line, held as a value

/// The widget mock's one line, held as a value across the tab's lifetime, so
/// More's appearance and the sheet's first frame READ it instead of asking the
/// store for it.
///
/// Why a cache and not a faster probe (61, ledger N71, his third report of
/// this sheet taking a moment). Build 57's `WidgetSampleProbe` was already the
/// right shape -- off the main actor, `fetchLimit = 1` draws, plain strings
/// back -- and the sheet's own body had no store work left in it. What was
/// still on the open path, by reading:
///
///   * `MoreView.widgetSample` is `@State`, so it started nil on every fresh
///     More and the `.task` re-ran the probe on EVERY appearance of the tab:
///     up to twelve single-row fetches with a `Book` prefetch, in a fresh
///     background context, in the second or two during which the row is
///     tapped. Each holds the store's coordinator; any main-context work in
///     the same window -- `refreshJournalFacts` (three synchronous fetches,
///     re-fired by every `ModelContext.didSave`, including the People indexer's
///     and the embedding backfill's), `DeltaLedger.snapshot` on appear, the
///     launch chain's export / import / backup / restore passes on the main
///     context after a cold start -- waits for it. That is the "sometimes".
///   * When the probe had not answered by the tap, the sheet's first frame was
///     redacted and the words then SNAPPED in on the next state change. No
///     animation, so it read as a load finishing rather than a line arriving.
///
/// `TabWarmCache`'s pattern exactly (`@MainActor` values, a generation counter,
/// coalesced fills, a `didSave` listener that invalidates and re-warms after a
/// debounce), scoped to one value. The probe now runs at most once per
/// process until a `Highlight` or `Book` row actually changes; every later
/// appearance of More is a synchronous read of three strings, and the sheet's
/// first frame draws them.
///
/// `Resolved.sample == nil` means the probe LOOKED and the library has no
/// attached line -- `MoreView` applies its public-domain stand-in to that. A
/// missing `Resolved` means it has not looked. The two are kept distinct for
/// the reason `MoreView.widgetSample`'s doc comment gives: the sheet must never
/// print a quotation as his before the library has been opened.
@MainActor
final class WidgetSampleCache {
    static let shared = WidgetSampleCache()

    struct Resolved: Sendable {
        /// nil: the probe looked, and there is no attached highlight to show.
        let sample: WidgetSample?
        let at: Date
    }

    /// How long after a Highlight/Book save the line is re-read. The embedding
    /// backfill and a seed merge save in bursts; this folds a burst into one.
    nonisolated static let saveDebounce: Duration = TabWarmCache.saveDebounce
    /// The only two tables the mock's line is read from: the highlight's text,
    /// the book's title and cover colour. Narrower than `TabWarmCache`'s set
    /// on purpose -- a quiz answer changes nothing here.
    nonisolated static let watchedEntities: Set<String> = ["Highlight", "Book"]

    private var resolved: Resolved?
    private var container: ModelContainer?
    /// Bumped on every invalidation; a fill's answer is stored only if the
    /// cache was not invalidated while it ran.
    private(set) var generation = 0
    private var fill: Task<WidgetSample?, Never>?
    private var fillID = 0
    private var warmTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: nil
        ) { note in
            guard Self.touchesWatchedTables(note) else { return }
            Task { @MainActor in
                WidgetSampleCache.shared.invalidate(rebuildAfter: WidgetSampleCache.saveDebounce)
            }
        })
    }

    // MARK: Reading

    /// The line, if this store has been probed since the last relevant save.
    /// Synchronous, no store: this is what a first body reads.
    func sample(for container: ModelContainer) -> Resolved? {
        guard self.container === container else { return nil }
        return resolved
    }

    // MARK: Filling

    /// The line, probing OFF the main actor only if it is not already known.
    /// One probe at a time: a second caller awaits the fill in flight rather
    /// than starting its own (`TabWarmCache.fillQuiz`'s shape).
    func fill(container: ModelContainer) async -> WidgetSample? {
        if let hit = sample(for: container) { return hit.sample }
        if self.container !== container {
            resolved = nil
            fill = nil
            self.container = container
        }
        if let fill { return await fill.value }
        let expected = generation
        fillID += 1
        let id = fillID
        let task = Task<WidgetSample?, Never> {
            await WidgetSampleProbe(modelContainer: container).sample()
        }
        fill = task
        let value = await task.value
        if fillID == id { fill = nil }
        if generation == expected, self.container === container {
            resolved = Resolved(sample: value, at: .now)
        }
        return value
    }

    /// Fills after `delay` if nothing is cached, replacing any pending warm.
    /// Never while a seed merge is writing, never in the background -- the
    /// same conditions `TabWarmCache.scheduleWarm` re-checks at the moment of
    /// use. Called from every invalidation, so the line is back before the
    /// next appearance of More rather than probed on it.
    func scheduleWarm(container: ModelContainer, after delay: Duration = WidgetSampleCache.saveDebounce) {
        if self.container !== container {
            resolved = nil
            fill = nil
        }
        self.container = container
        warmTask?.cancel()
        warmTask = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            while SeedingStatus.shared.isSeeding || !Self.appIsActive {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            guard self.resolved == nil, self.container === container else { return }
            _ = await self.fill(container: container)
        }
    }

    /// Drops the line; re-reads it after `delay` when a store is known.
    func invalidate(rebuildAfter delay: Duration) {
        generation += 1
        resolved = nil
        guard let container else { return }
        scheduleWarm(container: container, after: delay)
    }

    private static var appIsActive: Bool {
        #if canImport(UIKit)
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }

    // MARK: The save listener's reading of the payload

    /// `TabWarmCache.touchesWatchedTables`'s defensive reading, against this
    /// cache's narrower set (that helper's identifier reader is private to it,
    /// hence the eight lines repeated here rather than a wider watch list):
    /// identifiers under the enum key or its raw string, as an array or a set;
    /// a payload with no identifier lists, or one that says everything was
    /// invalidated, counts as touching. A needless re-probe is twelve
    /// single-row reads off-main; a stale line is a wrong quotation on screen.
    nonisolated static func touchesWatchedTables(_ note: Notification) -> Bool {
        guard let info = note.userInfo else { return true }
        if identifiers(in: info, for: .invalidatedAllIdentifiers) != nil { return true }
        var sawAnyKey = false
        for key in [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers] {
            guard let ids = identifiers(in: info, for: key) else { continue }
            sawAnyKey = true
            if ids.contains(where: { watchedEntities.contains($0.entityName) }) { return true }
        }
        return !sawAnyKey
    }

    private nonisolated static func identifiers(in info: [AnyHashable: Any],
                                                for key: ModelContext.NotificationKey) -> [PersistentIdentifier]? {
        let value = info[key] ?? info[key.rawValue]
        if let array = value as? [PersistentIdentifier] { return array }
        if let set = value as? Set<PersistentIdentifier> { return Array(set) }
        return nil
    }
}
