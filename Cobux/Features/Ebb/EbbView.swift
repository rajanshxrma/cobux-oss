import SwiftData
import SwiftUI

/// Ebb — the journal's counterpart to Flow.
///
/// Flow reads the library; Ebb reads his own life. The name is the tide going
/// back out over ground it already covered, and it names the product shape
/// truthfully: an ebb is finite, it recedes, it ends. Full design and vetoes in
/// `docs/ebb.md`.
///
/// Three panel designs live inside one deck rather than as three features —
/// Rajan's ruling was "all three should be made", and each alone was refuted:
/// **Return** is the session contract (finite, day-stable, ends on purpose),
/// **Drift** is the traversal grammar (backwards through era chapters, the
/// month hue washing the atmosphere), **Echo** is the gold card (his passage
/// beside the library line nearest it).
struct EbbView: View {
    let entries: [PersonalWritingEntry]
    /// Today's already-computed pick from the daily card, so the two surfaces
    /// never disagree about what today's passage is.
    var todaysPick: JournalHighlightSelector.Pick?
    /// Opens the composer from the end card. The deck recedes into writing
    /// rather than simply stopping.
    ///
    /// Declared before `onOpenEntry` deliberately: a trailing closure binds to
    /// the LAST parameter, and this file already carries that trap twice.
    var onWrite: (() -> Void)?
    /// Write Back from a card -- declared BEFORE onOpenEntry (this file
    /// documents the trailing-closure trap; the LAST closure parameter is the
    /// only one a trailing closure may bind).
    var onWriteBack: ((UUID) -> Void)? = nil
    var onOpenEntry: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    /// Reduce Motion is a hard gate (`CobuxMotion`). `EbbCardViews` honours it
    /// throughout; this file's one `withAnimation` -- a card leaving the deck
    /// when he silences it -- did not, so the deck still collapsed under him.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var deck: [EbbCard] = []
    @State private var visibleCardID: String?
    @State private var isBuilding = true

    private var atmosphereHue: Color {
        let month = deck.first(where: { $0.id == visibleCardID })?.month
            ?? Calendar.current.component(.month, from: .now)
        return Color.cobuxMonthHue(month, dark: colorScheme == .dark)
    }

    var body: some View {
        // Self-wrapped, NOT relying on sitting inside the journal's gate. A
        // fullScreenCover is presented outside the presenter's subtree, so it
        // inherits nothing -- `JournalLockGate` documents that exact bypass, and
        // detail and compose already wrap themselves for the same reason. This
        // surface quotes journal content in full, so the gate is not optional.
        JournalLocked {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            // `.reading`, NOT Flow's `.card` -- and this is half of the one
            // idea that finally tells the two surfaces apart.
            //
            // Rajan, on build 53: "ebb looks totally similar to flow somwhting
            // shuld be a lil different so that usre eys can subconsicly
            // distinguish". He was right, and the diff was brutal: Ebb was
            // Flow's atmosphere at Flow's strength, Flow's scaffold at Flow's
            // optical centre, Flow's parallax constants, Flow's settle haptic,
            // Flow's quote glyph and Flow's wordmark geometry. The only thing
            // that differed was the colour of four letters.
            //
            // The distinction that already exists in MEANING: Flow is the
            // library speaking -- something new carried toward him, so it
            // arrives as light in the room. Ebb is his own writing coming back
            // after time -- something already his, already written DOWN. So Ebb
            // stops being a lit room and becomes a PAGE in a dim one: the
            // atmosphere drops to `.reading` ("the color is a memory of the
            // room"), and the passage moves onto a real sheet
            // (`EbbLeaf`, EbbCardViews). The tide has gone out; what is left is
            // the paper.
            //
            // Drift loses nothing: the wash is still keyed to the visible
            // card's month and still melts across seasons on the same 0.6s ease
            // (`CobuxAtmosphere`), and the month hue keeps every other place it
            // already had -- the quote glyph, the hue rule, the era spine, the
            // chips and the pill. The page is added ON TOP of that pillar, not
            // taken out of it. The page's own edge is `cobuxEbb` instead, so the
            // room's colour changes with the season while the sheet's edge
            // never does -- which is the whole difference from Flow, where the
            // colour of everything is whatever book is talking.
            CobuxAtmosphere(accent: atmosphereHue, strength: .reading)

            if deck.isEmpty && !isBuilding {
                emptyState
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(deck) { card in
                            EbbCardView(
                                card: card,
                                hue: Color.cobuxMonthHue(card.month
                                    ?? Calendar.current.component(.month, from: .now),
                                    dark: colorScheme == .dark),
                                onWriteBack: onWriteBack.map { handler in
                                    { id in dismiss(); handler(id) }
                                },
                                onOpenEntry: { id in dismiss(); onOpenEntry(id) },
                                onOpenChat: openInChat,
                                onSuppress: suppress,
                                onWrite: { dismiss(); onWrite?() }
                            )
                            .containerRelativeFrame(.vertical)
                            .id(card.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $visibleCardID)
                .scrollIndicators(.hidden)
                // Flow's settle haptic, same weight, same skip of the
                // nil->first transition (opening the surface is not a page
                // turn).
                .sensoryFeedback(.impact(weight: .light, intensity: 0.7),
                                 trigger: visibleCardID) { oldValue, _ in
                    oldValue != nil
                }
            }

            // The wordmark is CENTERED, exactly like Flow's -- and that is
            // the structural fix for the collision Rajan screenshotted: the
            // old top-leading "EBB" shared its corner with every card's
            // kicker, two text layers fighting for the same spot. Centered
            // chrome and a centered kicker below it no longer contest a
            // corner, and Ebb's chrome becomes grammatically identical to
            // its sibling surface.
            // `maxHeight: .infinity` is load-bearing, not decoration: with
            // only `maxWidth` set, the frame is the text's own height, so
            // `alignment: .top` has nothing to align against and the ZStack
            // centres the whole thing -- which put the wordmark straight
            // through the middle of the passage. Rajan screenshotted it the
            // second time: "the little eb is in the middle of the screen this
            // is bug shodlda been on top". Chrome, so it never takes a tap
            // from the card underneath it.
            Text("EBB")
                .font(.caption.weight(.bold))
                .kerning(3)
                .foregroundStyle(Color.cobuxEbb)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close Ebb")
                }
                .padding(.horizontal, 8)
                Spacer()
            }
        }
        .task { await build() }
    }

    private var emptyState: some View {
        // Says so plainly rather than guessing. A deck the pool cannot fund is
        // a deck that would repeat itself.
        // Ebb's own hue, not the app accent: this screen's only other piece of
        // chrome is the wordmark, and it is `cobuxEbb`. An empty state in a
        // different colour would read as a different surface.
        CobuxEmptyStateView(
            icon: "book.closed",
            title: "Not enough yet",
            message: "Ebb walks back through writing that has had a little time to settle. Come back when there is more behind you.",
            tint: Color.cobuxEbb
        )
    }

    // ------------------------------------------------------------- building

    private func build() async {
        guard deck.isEmpty else { return }
        // Snapshot on the main actor: these are SwiftData models, and reading
        // them from another actor is the crash class this app has already paid
        // for twice.
        let snapshots = entries.map {
            EbbDeckBuilder.EntrySnapshot(
                id: $0.id,
                date: $0.modifiedDate ?? $0.dateImported,
                // `modifiedDate` nil means the date is genuinely unknown, so no
                // card built from it may make a calendar claim.
                dateIsCertain: $0.modifiedDate != nil,
                text: $0.text,
                words: JournalHighlightSelector.stripStamp($0.text)
                    .split(whereSeparator: \.isWhitespace).count)
        }
        let suppressed = EbbSuppressionStore.suppressedIDs()
        let recent = JournalHighlightRecentStore.recentIDs()
        // Certainty looked up from the entry the pick actually came from.
        // The opener goes through the same gates as everything else -- it
        // arrives from another surface, and trusting it is what let a quieted
        // entry become Ebb's opening card.
        let openerAllowed = todaysPick.flatMap { pick in
            entries.first { $0.id == pick.entryID }
        }.map { JournalHighlightSelector.maySurface($0.text) } ?? (todaysPick == nil)
        let opener = (openerAllowed ? todaysPick : nil).map { pick -> EbbCard in
            let certain = entries.first { $0.id == pick.entryID }?.modifiedDate != nil
            return Self.openerCard(pick, dateIsCertain: certain)
        }
        let seed = EbbDeckBuilder.seed(for: .now)

        let built = await Task.detached(priority: .utility) { () -> [EbbCard] in
            EbbDeckBuilder.buildDeck(entries: snapshots,
                                     opener: opener,
                                     suppressed: suppressed,
                                     recentlyShown: recent,
                                     daySeed: seed)
        }.value

        withAnimation(.easeOut(duration: 0.3)) {
            deck = built
            isBuilding = false
        }
        visibleCardID = built.first?.id
    }

    /// Today's daily-card pick, as the deck's opening card.
    /// - Parameter dateIsCertain: carried through from the entry rather than
    ///   assumed. It was hardcoded true, which laundered an unknown import date
    ///   into a confident one the moment the daily pick became Ebb's opener --
    ///   defeating the very kicker machinery added to say "imported".
    private static func openerCard(_ pick: JournalHighlightSelector.Pick,
                                   dateIsCertain: Bool) -> EbbCard {
        switch pick {
        case let .onThisDay(id, date, passage):
            return .onThisDay(entryID: id, date: date, text: passage)
        case let .fromArchive(id, date, passage):
            return .passage(entryID: id, date: date, text: passage, dateIsCertain: dateIsCertain)
        case let .resonance(id, date, passage, highlight, bookTitle):
            return .echo(entryID: id, date: date, passage: passage,
                         highlight: highlight, bookTitle: bookTitle)
        // `.reference` ("You wrote N words here") is gone from the selector's
        // `Pick` -- he called the word count "useless information" -- so there
        // is no longer anything to map to Ebb's reference card from here.
        }
    }

    // --------------------------------------------------------------- actions

    private func openInChat(_ passage: String) {
        dismiss()
        openURL(CobuxDeepLink.journalChatURL(prefill: passage))
    }

    private func suppress(_ entryID: UUID) {
        EbbSuppressionStore.suppress(entryID)
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .default) {
            deck.removeAll { $0.entryID == entryID }
        }
    }
}

/// Entries he has permanently silenced.
///
/// This exists because journal entries are never deletable. That guarantee is
/// right, and it means a surfacing he does not want has no fix at the source --
/// so the fix has to live here, and it has to ship WITH the surface rather than
/// after it. No confirmation, no undo prompt, no setting: the same silent
/// dismissal the daily card already uses, made permanent.
enum EbbSuppressionStore {
    private static let key = "cobux.ebb.suppressedEntries"

    static func suppressedIDs() -> Set<UUID> {
        let stored = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(stored.compactMap(UUID.init(uuidString:)))
    }

    /// Main-actor because it moves the signal below; every caller is a view
    /// action anyway.
    @MainActor
    static func suppress(_ id: UUID) {
        var stored = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !stored.contains(id.uuidString) else { return }
        stored.append(id.uuidString)
        UserDefaults.standard.set(stored, forKey: key)
        EbbSuppressionSignal.shared.bump()
    }
}

/// The suppression store's change signal -- `SeedingStatus`'s shape: a
/// `@MainActor @Observable` singleton a view reads directly.
///
/// A surface that has ALREADY decided what to show folds `revision` into its
/// selection task's identity, so a suppression made anywhere re-selects it
/// instead of leaving the banished entry on screen. Ebb's own "Never show
/// this again" reached the store and Ebb's deck, and never the threshold card
/// underneath, which kept showing the entry after Ebb closed. A signal rather
/// than a callback threaded through the list: every surface that can
/// suppress, including one not yet written, reaches every surface that shows.
@MainActor
@Observable
final class EbbSuppressionSignal {
    static let shared = EbbSuppressionSignal()
    private init() {}

    private(set) var revision = 0

    func bump() { revision += 1 }
}
