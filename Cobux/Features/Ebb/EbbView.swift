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
    /// Only for `modelContext.container`, which the counterpoint probe owns
    /// its own context on. No model is read through this on the main actor.
    @Environment(\.modelContext) private var modelContext
    @State private var deck: [EbbCard] = []
    @State private var visibleCardID: String?
    @State private var isBuilding = true
    /// The "Another tradition" line for each echo card, keyed by card id, so
    /// a card the lazy stack recycles and deals again does not re-run the
    /// probe. Kept beside the deck rather than inside `EbbCard.echo`: that
    /// case is also `JournalHighlightCard`'s vocabulary, and the deck builder
    /// stays pure. Filled after the deck is on screen; a card whose line has
    /// not arrived, or never will, simply has no section.
    @State private var counterpoints: [String: EbbCounterpoint] = [:]

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
                                counterpoint: counterpoints[card.id],
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
        // AFTER the deck is on screen, never before it: the first frame owes
        // nothing to the library. The echo card is dealt with its two voices
        // and the third arrives when it has been found -- or does not.
        await loadCounterpoints(for: built)
    }

    /// Finds the "Another tradition" line for every echo card in the deck.
    ///
    /// At most one today (only the day's pick can be an echo), but written
    /// over the deck so a second echo source needs no second wiring. Each
    /// lookup runs on `EbbCounterpointProbe`'s own executor and returns a
    /// plain value; the only main-actor work is the assignment.
    private func loadCounterpoints(for deck: [EbbCard]) async {
        // Not during a seed merge -- the same guard every reader of the
        // library carries (`JournalHighlightCard.sampleLibrary`,
        // `SemanticVectorCache.scheduleRebuild`). A deck without the section
        // is its ordinary state; a crash in the merge is not.
        guard !SeedingStatus.shared.isSeeding else { return }
        let sources = deck.compactMap { card -> (id: String, source: EbbCounterpointProbe.Source)? in
            guard case let .echo(_, _, _, highlight, bookTitle) = card else { return nil }
            return (card.id, EbbCounterpointProbe.Source(highlightText: highlight, bookTitle: bookTitle))
        }
        guard !sources.isEmpty else { return }
        let probe = EbbCounterpointProbe(modelContainer: modelContext.container)
        for entry in sources {
            guard !Task.isCancelled else { return }
            guard let found = await probe.counterpoint(for: entry.source) else { continue }
            // The section fades in under a card he is already reading. Reduce
            // Motion is the hard gate it is everywhere else in Ebb: a shorter
            // fade, never a move.
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.35)) {
                counterpoints[entry.id] = found
            }
        }
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

/// Finds the "Another tradition" line for an echo card, off the main actor.
///
/// `FlowResonanceProbe`/`SemanticSearchProbe`'s shape exactly: a `@ModelActor`
/// owns a `ModelContext` confined to its own serial executor, every model read
/// happens there, and only a plain `EbbCounterpoint` comes back. Lives in this
/// file rather than its own because the project lists every source file
/// individually in `project.pbxproj`, so a new file would not join the target
/// without a project edit -- the same reason `FlowResonanceProbe` lives in
/// `FlowView.swift`.
///
/// What it reads, and how much:
///   * every `Book`, a handful of attributes each (~150 rows) -- to learn the
///     echo's own shelf, which shelves may answer it, and which books the
///     Sources filter has switched off. `BookSourceFilter.effectiveExcludedIDs`
///     is applied exactly as Flow and the Wisdom Graph apply it, so a book he
///     turned off there is never handed to him here;
///   * the echo's book's embedded highlights, id/text/vector only, to find the
///     echo line's STORED vector -- the pool is stored vectors, so the query
///     must be one too (`JournalPairFinder` documents why mixing fresh and
///     stored vectors silently mismatches);
///   * the pool: `SemanticVectorCache`'s decoded table when the chat path has
///     already built it (free), else one indexed fetch per allowed book of id
///     and vector only -- the shelves the Sources filter keeps, never the
///     reference texts it switches off, so this never pins the whole library's
///     vectors in memory on Ebb's account;
///   * the shortlist's text, per book through the relationship's own index
///     (`SearchService.resolve`'s predicate), to apply the line gates.
///
/// No relationship is faulted on a highlight; no `#Predicate` shape without
/// an in-repo precedent (`R-2026-09-wisdom-tab-trapped-on-a-tag-join-predicate`).
@ModelActor
actor EbbCounterpointProbe {
    /// What an echo card knows about its library line. `EbbCard.echo` carries
    /// text and title, not ids -- the case is shared with the journal's own
    /// window -- so the row is found again here, inside its book.
    struct Source: Sendable {
        let highlightText: String
        let bookTitle: String
    }

    func counterpoint(for source: Source) async -> EbbCounterpoint? {
        var bookDescriptor = FetchDescriptor<Book>()
        bookDescriptor.propertiesToFetch = [\.id, \.title, \.author, \.traditionRaw, \.contentProfileRaw]
        let books = (try? modelContext.fetch(bookDescriptor)) ?? []
        // A book whose shelf is unknown cannot be answered from "another"
        // one, and the section would be a claim the app cannot support.
        guard let sourceBook = books.first(where: { $0.title == source.bookTitle }),
              let sourceTradition = sourceBook.tradition else { return nil }

        let excluded = BookSourceFilter.effectiveExcludedIDs(books: books)
        // The shelves that may answer: a DIFFERENT tradition, one the Ebb
        // ruling allows to meet a private passage at all (`docs/ebb.md` veto
        // 3 -- this line sits on the same page as his writing), and not
        // switched off in Sources.
        var shelf: [UUID: (title: String, author: String, tradition: BookTradition)] = [:]
        for book in books {
            guard let tradition = book.tradition,
                  tradition != sourceTradition,
                  JournalPairFinder.pairableTraditions.contains(tradition),
                  !excluded.contains(book.id) else { continue }
            shelf[book.id] = (book.title, book.author, tradition)
        }
        guard !shelf.isEmpty else { return nil }

        guard let sourceVector = storedVector(ofText: source.highlightText, inBook: sourceBook.id)
        else { return nil }
        let candidates = pool(bookIDs: Set(shelf.keys))
        guard let field = EbbCounterpointFinder.rank(sourceVector: sourceVector,
                                                     candidates: candidates,
                                                     similarity: EmbeddingService.cosineSimilarity)
        else { return nil }

        // The line gates every ambient surface applies: it must read on its
        // own (Flow's rule, the echo's rule) and it must not carry a word he
        // has quieted (`JournalHighlightSelector.maySurface`, THE choke point).
        let texts = resolveTexts(field.shortlist)
        let surviving = Set(texts.filter { _, text in
            FlowQueueBuilder.readsStandalone(text) && JournalHighlightSelector.maySurface(text)
        }.keys)
        guard let cleared = EbbCounterpointFinder.clear(field, surviving: surviving),
              let text = texts[cleared.winner.id],
              let book = shelf[cleared.winner.bookID] else { return nil }

        // Calibration before trust, exactly as the echo logs its pairing:
        // real pairs from his real library, readable by a human, never shown.
        DiagnosticLog.log(String(format: "ebb: another tradition σ=%.2f n=%d | %@ (%@) ⇄ %@ (%@)",
                                 cleared.sigma, field.poolSize,
                                 String(source.highlightText.prefix(60)), sourceTradition.label,
                                 String(text.prefix(60)), book.tradition.label))

        return EbbCounterpoint(text: text,
                               bookTitle: book.title,
                               author: book.author,
                               tradition: book.tradition,
                               sourceTradition: sourceTradition,
                               sigma: cleared.sigma)
    }

    /// The echo line's own stored vector, found inside its book. One indexed
    /// fetch of id/text/vector (`SemanticSearchProbe.buildTable`'s predicate);
    /// the text match is in memory over that one book's rows.
    ///
    /// `nil` when the line carries no vector yet -- the backfill has not
    /// reached it -- rather than a fresh embedding: a query vector from a
    /// different model than the pool's would score every candidate at zero and
    /// the gate would read that as "no spread", which is correct but wasteful.
    private func storedVector(ofText text: String, inBook bookID: UUID) -> [Float]? {
        var descriptor = FetchDescriptor<Highlight>(
            predicate: #Predicate<Highlight> { $0.book?.id == bookID && $0.embeddingData != nil })
        descriptor.propertiesToFetch = [\.id, \.text, \.embeddingData]
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        guard let row = rows.first(where: { $0.text == text }),
              let data = row.embeddingData else { return nil }
        let vector = EmbeddingService.decodeVector(data)
        return vector.isEmpty ? nil : vector
    }

    /// Every embedded highlight on the allowed shelves.
    private func pool(bookIDs: Set<UUID>) -> [EbbCounterpointFinder.Candidate] {
        // A 4 GB phone keeps the table in half floats; widening every row
        // here would be the ~66 MB transient this whole path was built to
        // avoid. No counterpoint on that class of device, by design.
        guard DeviceClass.current == .standard else { return [] }
        if let table = SemanticVectorCache.shared.freshTable(for: modelContainer) {
            return table.entries(inBooks: bookIDs).compactMap { entry in
                guard let bookID = UUID(uuidString: entry.bookKey) else { return nil }
                return EbbCounterpointFinder.Candidate(id: entry.id, bookID: bookID, vector: entry.vector)
            }
        }
        // Cold table: no counterpoint this open. The fallback below decoded
        // every vector on every allowed shelf (~100 MB transient) on each Ebb
        // open the chat had not warmed -- too much for a 4 GB phone. Ask the
        // cache to warm and let the next open find it.
        SemanticVectorCache.shared.warm(using: modelContainer)
        return []
    }

    /// The shortlist's text, fetched per book through the relationship's
    /// index -- `SearchService.resolve`'s predicate, for its reason:
    /// `Highlight.id` carries no index, and a bare id predicate scans every
    /// row's record with its vector inline.
    private func resolveTexts(_ shortlist: [EbbCounterpointFinder.Scored]) -> [UUID: String] {
        var texts: [UUID: String] = [:]
        for (bookID, group) in Dictionary(grouping: shortlist, by: \.bookID) {
            let ids = group.map(\.id)
            var descriptor = FetchDescriptor<Highlight>(
                predicate: #Predicate<Highlight> { $0.book?.id == bookID && ids.contains($0.id) })
            descriptor.propertiesToFetch = [\.id, \.text]
            for highlight in (try? modelContext.fetch(descriptor)) ?? [] {
                texts[highlight.id] = highlight.text
            }
        }
        return texts
    }
}
