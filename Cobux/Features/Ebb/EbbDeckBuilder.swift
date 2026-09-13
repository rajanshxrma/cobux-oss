import Foundation

/// Builds the day's Ebb deck. Pure, seeded, and free of side effects.
///
/// Flow's engineering discipline carries over wholesale — a seeded generator so
/// the same day deals the same deck, a pattern rather than a shuffle, soft
/// demotion rather than exclusion, and degrade-to-passage instead of padding.
/// Flow's PRODUCT shape deliberately does not: Flow is infinite because its
/// corpus is external and replenishes with every book imported, while this
/// corpus is his own and, per `JournalListView`'s own note, runs at the
/// confirmed ~100-row scale. An infinite shuffle over a hundred diary entries
/// repeats by Thursday. So Ebb is finite, sized from the eligible pool it
/// actually measures, and it ends on purpose.
enum EbbDeckBuilder {

    /// An entry, flattened off SwiftData so the deal can happen off the main
    /// actor without carrying a model across it.
    struct EntrySnapshot: Sendable {
        let id: UUID
        let date: Date
        /// Whether `date` is genuinely known. An import with no parsable date
        /// collapses onto `dateImported`, and a card that says "on this day"
        /// about a guess is a fabricated claim.
        let dateIsCertain: Bool
        let text: String
        let words: Int
    }

    /// Fresh writing is a wound. Non-negotiable, and the same floor the daily
    /// card uses.
    static let minimumAgeDays = JournalHighlightSelector.minimumAgeDays
    /// Deck bounds. Small enough to end, large enough to be a walk.
    static let minimumDeck = 6
    static let maximumDeck = 16
    /// A chapter needs at least this many eligible entries to be worth opening.
    static let minimumEraEntries = 2

    /// The deck for a given day.
    ///
    /// - Parameters:
    ///   - opener: today's already-computed highlight-card pick, if it has one.
    ///     Handed in, never recomputed — the daily card and Ebb must never
    ///     disagree about what today's passage is, and recomputing would also
    ///     re-run a selector that records what it showed.
    ///   - suppressed: entries he has permanently silenced. Checked first,
    ///     before anything else, because it is the only correction available:
    ///     entries are never deletable, so a bad surfacing cannot be fixed at
    ///     the source.
    ///   - recentlyShown: soft demotion, not exclusion. Over ~100 entries a
    ///     hard 60-day ban starves the pool within a week.
    static func buildDeck(entries: [EntrySnapshot],
                          opener: EbbCard?,
                          suppressed: Set<UUID>,
                          recentlyShown: Set<UUID>,
                          daySeed: UInt64,
                          now: Date = .now) -> [EbbCard] {
        let calendar = Calendar.current
        guard let floor = calendar.date(byAdding: .day, value: -minimumAgeDays, to: now)
        else { return [] }

        let eligible = entries
            .filter { $0.date < floor && !suppressed.contains($0.id)
                      && JournalHighlightSelector.maySurface($0.text) }
        guard eligible.count >= 3 else { return [] }

        var generator = SeededGenerator(seed: daySeed)
        var cards: [EbbCard] = []
        var used = Set<UUID>()

        // The opener is checked against suppression like everything else. It
        // was appended unconditionally, so suppressing today's opener and
        // reopening Ebb dealt the very same card again as card one -- which
        // makes "Never show this again" mean "not for the next few cards".
        if let opener, !(opener.entryID.map(suppressed.contains) ?? false) {
            cards.append(opener)
            if let id = opener.entryID { used.insert(id) }
        }

        // Size the deck from the pool that actually exists rather than a
        // constant. A deck that outruns its material repeats inside itself.
        let target = min(maximumDeck, max(minimumDeck, eligible.count / 8 + minimumDeck))

        // Eras, newest first, so the deck walks backwards.
        let grouped = Dictionary(grouping: eligible) { entry -> EraKey in
            let parts = calendar.dateComponents([.year, .month], from: entry.date)
            return EraKey(year: parts.year ?? 0, month: parts.month ?? 0)
        }
        let eras = grouped
            .filter { $0.value.count >= minimumEraEntries }
            .sorted { ($0.key.year, $0.key.month) > ($1.key.year, $1.key.month) }
        // At most three chapters: enough to feel like a walk, few enough that
        // each one has material to spend.
        let chapters = Array(eras.prefix(3))

        for (key, members) in chapters {
            // Room for the divider AND at least one card under it. A chapter
            // heading followed immediately by the end card is a promise the
            // deck does not keep.
            guard cards.count + 1 < target else { break }
            cards.append(.eraDivider(month: key.month, year: key.year))
            // Least-recently-shown first, then seeded, so the deck neither
            // repeats last week's cards nor deals the same order twice.
            // Shuffled with the day's generator BEFORE the recency sort, so the
            // seed actually reaches the output. Without this the ordering was
            // fully determined by (seen, date) and the deck was identical every
            // single day -- the newest three entries of the newest three
            // qualifying months, forever, which turns a walk into a museum.
            var shuffled = members.filter { !used.contains($0.id) }
            shuffled.shuffle(using: &generator)
            let pool = shuffled.sorted { lhs, rhs in
                let lSeen = recentlyShown.contains(lhs.id) ? 1 : 0
                let rSeen = recentlyShown.contains(rhs.id) ? 1 : 0
                return lSeen < rSeen
            }
            for entry in pool.prefix(3) {
                guard cards.count < target else { break }
                cards.append(card(for: entry, calendar: calendar, now: now))
                used.insert(entry.id)
            }
        }

        // No separate echo argument. It was always passed nil, so this append
        // path could never run. An echo reaches the deck today by being the
        // day's pick, which is the shipped build order: the seam first, at one
        // card a day, before it amplifies into a whole deck.

        // A deck that carries no entry is not a short deck, it is an empty one
        // -- opening straight onto "Today's return ends here" having shown
        // nothing is worse than saying there is not enough yet.
        guard cards.contains(where: { $0.entryID != nil }) else { return [] }

        cards.append(.endCard(totalEntries: entries.count,
                              earliest: entries.map(\.date).min()))
        return cards
    }

    /// One entry becomes the most specific card it honestly supports.
    private static func card(for entry: EntrySnapshot,
                             calendar: Calendar,
                             now: Date) -> EbbCard {
        let passages = JournalHighlightSelector.candidates(in: entry.text)
        let standalone = Set(JournalHighlightSelector.stripStamp(entry.text)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) })

        guard let passage = JournalHighlightSelector.best(from: passages,
                                                          standaloneLines: standalone) else {
            // Nothing cleared the guards, so point rather than quote a worse
            // line. An embarrassing fragment is a bug; a reference never is.
            return .reference(entryID: entry.id, date: entry.date,
                              words: entry.words, dateIsCertain: entry.dateIsCertain)
        }

        // "On this day" only when the date is genuinely known. An imported
        // entry whose date collapsed onto its import date cannot make a
        // calendar claim, so it stays a plain passage.
        let today = calendar.dateComponents([.month, .day], from: now)
        let then = calendar.dateComponents([.month, .day], from: entry.date)
        if entry.dateIsCertain, then.month == today.month, then.day == today.day {
            return .onThisDay(entryID: entry.id, date: entry.date, text: passage)
        }
        // An uncertain date is carried through to the card so the kicker can
        // say "imported" rather than printing an import date as if it were the
        // day he wrote. Gating only the "on this day" claim left the rest of
        // the deck quietly dating entries it cannot date.
        return .passage(entryID: entry.id, date: entry.date,
                        text: passage, dateIsCertain: entry.dateIsCertain)
    }

    private struct EraKey: Hashable {
        let year: Int
        let month: Int
    }

    /// SplitMix64, the same generator Flow's queue builder uses, so a day's
    /// deck is reproducible and testable.
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// The day itself as a seed, so the deck is stable from open to open.
    static func seed(for date: Date) -> UInt64 {
        UInt64(Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0)
    }
}
