import CryptoKit
import Foundation

/// The small deck that sits under the journal calendar.
///
/// Rajan asked for "much more than just a user's writing showing up" there — a
/// window that shows something smart and turns over when tapped. Fable's ruling
/// was that this is not a third pillar but **Ebb's threshold**: the same card
/// grammar, the same stores, the same vetoes, rendered inline and finite, whose
/// last card is a door into Ebb itself. The window looks into the tide.
///
/// Pure and day-seeded, like `EbbDeckBuilder`. The important property is that
/// turning the window over CYCLES a dealt deck rather than re-selecting:
/// `JournalHighlightCard` already documents how re-selection emptied a
/// ~100-entry pool through the 60-day cooldown, and an unbounded refresh would
/// rebuild that bug as a feature.
///
/// **Rounds** (build 56). Rajan asked for the window to move on its own and to
/// feel endless: *"it should be an automatic carousel... maybe make it an
/// infinite carousel and automatically moving... I want this to be smart like
/// Flow, with the amount and quality of content that is shown in it."* A deck
/// that wraps onto its own first card is not endless, it is a loop of three.
///
/// So a ROUND is dealt, and when the window wraps past its last slot the caller
/// deals the next round with `alreadyDealt` carrying everything the earlier
/// rounds spent. That is not the re-selection this file warns about, and the
/// difference is exact: **this builder spends nothing.** It records no
/// surfacing, moves no cooldown, and reads `recentlyShown` only as a soft
/// demotion. Only `JournalHighlightCard`'s once-a-day pick calls
/// `JournalHighlightRecentStore.remember`, and rounds never touch it. Round 0 is
/// still decided by the day's seed alone, so leaving the screen and coming back
/// deals the same cards in the same order all day, exactly as
/// `R-2026-09-threshold-refresh-must-not-reselect` requires.
enum ThresholdDeckBuilder {

    /// What sits in the window. Deliberately shares `EbbCard` rather than
    /// inventing a parallel vocabulary — a card that cannot characterize him in
    /// Ebb must not become able to here.
    enum Slot: Identifiable, Equatable {
        case card(EbbCard)
        /// Something he told Cobux in chat about his own life, handed back
        /// with an invitation to write about it here. Deliberately NOT an
        /// `EbbCard` and NOT a `JournalHighlightSelector.Pick`: both of those
        /// vocabularies are "his journal, quoted and dated", every case
        /// carries an `entryID`, and Ebb's opener switch maps a `Pick` onto
        /// them exhaustively. A chat message is about no entry -- it is the
        /// thing an entry has not been written about yet -- so it gets its
        /// own slot rather than a fudged `entryID`. See `ChatReflection`.
        case chatReflection(ChatReflection)
        /// The last slot, always. An invitation, never a nag.
        case door

        var id: String {
            switch self {
            case let .card(card): card.id
            case let .chatReflection(reflection): "chat-\(reflection.id)"
            case .door: "threshold-door"
            }
        }
    }

    /// A user chat message, flattened off SwiftData for the same reason
    /// entries and keeps are. `ChatMessage` has no `id` of its own, so the
    /// identity used for suppression and dealt-tracking is derived -- see
    /// `stableChatID`.
    struct ChatSnapshot: Sendable {
        let date: Date
        let text: String
    }

    /// One "From your chat" card.
    ///
    /// The second half of ledger M3 (CC reminder 27A202D3, 4 Sep 2026): *"the
    /// journal highlight section under the calendar can also include prompts
    /// to reflect about what they chatted about, in short."* The FIRST half --
    /// auto-saving situation-shaped chat prompts as journal entries tagged
    /// "thru chat" -- is deliberately not built: a Cobux-native entry has no
    /// delete path, ever, so a misclassified prompt would become a permanent
    /// entry. This card is the deletion-safe shape of the same idea: it shows
    /// him his own words and offers a blank page. Nothing is written unless he
    /// writes it. Pull, never push -- he has said what nagging reflect-prompts
    /// feel like ("it used to be very pissing"), so the card sits in the deck
    /// like any other and asks nothing.
    struct ChatReflection: Equatable, Sendable {
        /// Derived from the message's timestamp and text, so the same message
        /// always yields the same id across builds and launches. Lives in the
        /// same `EbbSuppressionStore` set as entry ids: "Never show this
        /// again" on this card is permanent in exactly the way it is for a
        /// passage, and a chat id in an entry-id set can never match an entry.
        let id: UUID
        let date: Date
        /// The message text with its whitespace collapsed to single spaces.
        /// Full length (at most `chatReflectionLength.upperBound`); the card
        /// truncates visually and the compose lead trims on a word boundary.
        let excerpt: String
    }

    /// How many cards a round holds before the door.
    ///
    /// Was 3, "small on purpose: this is a threshold, and a long deck here would
    /// make Ebb redundant". Three was right for a deck he turned over by hand;
    /// it is wrong for one that turns over by itself, where three cards plus the
    /// door is a twenty-second loop back to the card he just read. Eight is
    /// still a threshold — Ebb deals up to sixteen, walks backwards through
    /// dated chapters, and ends — and the rounds above are what actually make
    /// this endless, not the length of any one of them.
    static let maximumCards = 8

    /// - Parameters:
    ///   - todaysPick: the existing daily selection, handed in rather than
    ///     recomputed, so card one is exactly the card that was already there
    ///     and nothing regresses.
    ///   - entries: everything, already snapshotted off SwiftData.
    ///   - alreadyDealt: entries earlier rounds have already shown this
    ///     sitting. A soft exclusion: when honouring it would leave nothing to
    ///     deal, it is dropped and the archive comes round again, because a
    ///     window that runs out is the thing this is fixing.
    /// A Keep, flattened off SwiftData for the same reason entries are.
    struct KeepSnapshot: Sendable {
        let id: UUID
        let entryID: UUID
        let passage: String
        let question: String?
        let sourceDate: Date
        let isDue: Bool
    }

    ///   - chatMessages: his own recent chat messages, already bounded and
    ///     snapshotted by the caller (`fetchLimit = 40`, last 14 days, not the
    ///     journal thread). The builder applies every gate itself -- shape,
    ///     quiet words, the quoting exclusions, suppression, dealt-tracking --
    ///     so this stays the single choke point for what the window shows.
    ///   - previousRoundDealtChatReflection: whether the round before this one
    ///     carried a chat card. Never two in a row: a second consecutive
    ///     round without one keeps the window his writing first and the chat
    ///     card an occasional guest.
    static func build(todaysPick: EbbCard?,
                      entries: [EbbDeckBuilder.EntrySnapshot],
                      keeps: [KeepSnapshot] = [],
                      suppressed: Set<UUID>,
                      recentlyShown: Set<UUID>,
                      alreadyDealt: Set<UUID> = [],
                      chatMessages: [ChatSnapshot] = [],
                      previousRoundDealtChatReflection: Bool = false,
                      daySeed: UInt64,
                      now: Date = .now) -> [Slot] {
        var slots: [Slot] = []
        var used = Set<UUID>()

        // At most one chat card per round, chosen up front so every exit
        // below -- including the early returns for an archive too young or
        // too quiet to deal from -- seats it the same way. Its own generator,
        // seeded apart from the walk's, so adding this card moved nothing in
        // the order of his entries: round 0 today deals the same writing in
        // the same places it did yesterday.
        let chat: ChatReflection? = previousRoundDealtChatReflection ? nil
            : chatReflection(from: chatMessages, suppressed: suppressed,
                             alreadyDealt: alreadyDealt, now: now,
                             seed: daySeed ^ chatSeedSalt)
        // Seats the chat card third at the latest -- after the day's pick and
        // whatever rides second -- so the window still opens on his writing,
        // then closes on the door. When the deck is shorter than that it
        // simply goes last before the door.
        func close(_ slots: [Slot]) -> [Slot] {
            var closed = slots
            if let chat { closed.insert(.chatReflection(chat), at: min(2, closed.count)) }
            return closed + [.door]
        }
        // The chat card takes one of the round's seats rather than adding a
        // ninth: the deck's length was chosen for the carousel's rhythm, and
        // that rhythm does not change because of what fills it.
        let walkCapacity = maximumCards - (chat == nil ? 0 : 1)

        // Even the handed-in pick is checked. A caller passing something the
        // gates would reject is exactly how the quiet list got bypassed once,
        // and "the choke point is single" has to be true of every path into
        // this builder, not only the ones that look like selection.
        // A pick whose entry cannot be found in the passed-in set fails
        // CLOSED, not open. `entries` is a caller-supplied snapshot, and a
        // caller that hands in a partial set must never be read as "nothing
        // to check" -- that reading is exactly how the quiet list got
        // bypassed before (R-2026-09-quiet-words-bypassed-on-settled-path).
        //
        // `carriesAPassage` is the last of the four gates and the newest: a
        // card that quotes nothing is the "You wrote N words here." card he
        // called useless. Applied to the handed-in pick too, for the same
        // reason the other three are -- a caller must not be able to post one
        // in through the side door.
        if let todaysPick, carriesAPassage(todaysPick),
           !(todaysPick.entryID.map { suppressed.contains($0) } ?? false),
           entries.first(where: { $0.id == todaysPick.entryID })
               .map({ JournalHighlightSelector.maySurface($0.text) }) ?? false {
            slots.append(.card(todaysPick))
            if let id = todaysPick.entryID { used.insert(id) }
        }

        // A due Keep rides second -- rare, and the only card here he asked to
        // see again. One at a time: several at once would turn a thing he chose
        // to hold into a queue he has to get through.
        // The quiet check covers the WHOLE source entry, not just the stored
        // passage. A keep holds one excerpt, but the name he quieted may sit in
        // the surrounding paragraph -- and the card opens straight into that
        // entry. Checking only the passage would have let a keep be the one
        // surface that walked him back into it.
        // Same fail-closed rule as the pick above: a keep whose source entry
        // is not in the passed-in set is not surfaced.
        //
        // Two orderings sit on top of "the first due one", and both are pure
        // ranking -- nothing new is admitted that was not admitted before.
        // A keep he wrote a QUESTION against outranks a bare one: "You asked
        // yourself" is his own voice addressed to himself, which is the highest
        // kind of card this window can deal. And a keep an earlier round already
        // dealt goes last, so a second round rotates to a different one instead
        // of handing him the same keep every eighty seconds.
        let dueKeeps = keeps.filter { keep in
            keep.isDue && !suppressed.contains(keep.entryID)
                && JournalHighlightSelector.maySurface(keep.passage)
                && (entries.first { $0.id == keep.entryID }
                        .map { JournalHighlightSelector.maySurface($0.text) } ?? false)
        }
        if let due = dueKeeps.enumerated().min(by: { lhs, rhs in
            (alreadyDealt.contains(lhs.element.entryID) ? 1 : 0,
             lhs.element.question == nil ? 1 : 0, lhs.offset)
                < (alreadyDealt.contains(rhs.element.entryID) ? 1 : 0,
                   rhs.element.question == nil ? 1 : 0, rhs.offset)
        })?.element {
            slots.append(.card(due.question.map {
                .asked(keepID: due.id, entryID: due.entryID, question: $0,
                       passage: due.passage, sourceDate: due.sourceDate)
            } ?? .kept(keepID: due.id, entryID: due.entryID,
                       passage: due.passage, sourceDate: due.sourceDate)))
            used.insert(due.entryID)
        }

        let calendar = Calendar.current
        guard let floor = calendar.date(byAdding: .day,
                                        value: -EbbDeckBuilder.minimumAgeDays, to: now)
        else { return close(slots) }

        // Same eligibility as everywhere else, including the quiet-words choke
        // point -- a surface that amplifies must never be the one that forgets.
        let eligible = entries.filter {
            $0.date < floor && !suppressed.contains($0.id) && !used.contains($0.id)
                && JournalHighlightSelector.maySurface($0.text)
        }
        guard !eligible.isEmpty else { return close(slots) }

        // A round of walk cards, ranked rather than filtered.
        //
        // The old code HARD-filtered the pool to a different month than the
        // pick ("the window shows two distances rather than two neighbours")
        // and fell back to the whole archive only when that emptied it. At
        // three cards that was harmless; at eight it starves, and worse, it
        // threw away the best card in the deck: an entry from THIS calendar day
        // in an earlier year is by definition in the pick's month whenever the
        // pick is itself an "on this day", so the one card that carries a real
        // date correspondence was the one guaranteed to be excluded.
        //
        // Four keys, in order, and every one of them is already an idea this
        // file holds -- none of them is a new claim about him:
        //   1. ON THIS DAY first. `card(for:)` has always upgraded a same-date
        //      entry to `.onThisDay`; nothing was making sure one ever reached
        //      the deck to be upgraded. This is the whole of "smarter": deal
        //      more of the cards that already carry meaning.
        //   2. Not this sitting's earlier rounds, so a second round is new
        //      writing rather than a reshuffle of the first.
        //   3. A different month from the pick -- the old filter, demoted to a
        //      preference, which is all it was ever able to promise anyway.
        //   4. Soft recency demotion, never exclusion. A hard cooldown over
        //      ~100 entries starves the pool in a week -- Ebb's own lesson.
        // The seeded shuffle is the fifth key by way of `offset`, so the order
        // is fully determined rather than resting on `sort` being stable, which
        // Swift does not promise.
        let pickMonth = todaysPick.flatMap(\.month)
        let today = calendar.dateComponents([.month, .day], from: now)
        var generator = EbbDeckBuilder.SeededGenerator(seed: daySeed)
        var pool = eligible
        pool.shuffle(using: &generator)
        var ranked: [(rank: Rank, entry: EbbDeckBuilder.EntrySnapshot)] = []
        ranked.reserveCapacity(pool.count)
        for (offset, entry) in pool.enumerated() {
            let then = calendar.dateComponents([.month, .day], from: entry.date)
            let isOnThisDay = entry.dateIsCertain
                && then.month == today.month && then.day == today.day
            let sharesPickMonth = pickMonth != nil
                && calendar.component(.month, from: entry.date) == pickMonth
            ranked.append((Rank(onThisDay: isOnThisDay ? 0 : 1,
                                dealtThisSitting: alreadyDealt.contains(entry.id) ? 1 : 0,
                                pickMonth: sharesPickMonth ? 1 : 0,
                                recentlyShown: recentlyShown.contains(entry.id) ? 1 : 0,
                                shuffled: offset),
                           entry))
        }
        ranked.sort { $0.rank < $1.rank }

        // Fill by WALKING the ranked pool rather than taking a prefix: an entry
        // whose passages cannot clear the quality guards no longer becomes a
        // "You wrote N words here." card, it is simply passed over and the next
        // entry takes the slot. That is the whole removal -- the deck deals a
        // worse-ranked entry rather than a worse card, and never runs a slot
        // short because of it.
        for candidate in ranked {
            guard slots.count < walkCapacity else { break }
            guard let card = card(for: candidate.entry, calendar: calendar, now: now)
            else { continue }
            slots.append(.card(card))
            used.insert(candidate.entry.id)
        }
        return close(slots)
    }

    // ------------------------------------------------------- chat reflection

    /// How far back the chat card looks. Fourteen days: recent enough that
    /// "what he chatted about" is still a live thing to write about, and the
    /// same distance the journal uses for the opposite rule (fresh WRITING is
    /// a wound, not a highlight) -- a message is not writing, it is the thing
    /// before writing, so here recency is the point rather than the hazard.
    static let chatReflectionWindowDays = 14

    /// A message shorter than this is a question or a nudge, not a situation;
    /// longer than this is a pasted document, and the card would quote a wall.
    static let chatReflectionLength = 60...600

    /// The compose lead quotes at most this much of the message, cut on a
    /// word. The full text is one tap away in chat; the lead is a doorstep.
    static let reflectionLeadQuoteLength = 160

    /// XOR-ed into the day seed for the chat pick's own generator, so the
    /// walk's shuffle is untouched by this card existing.
    private static let chatSeedSalt: UInt64 = 0x9E37_79B9_7F4A_7C15

    /// Messages beginning like these are asking about a BOOK, whatever
    /// pronoun follows ("what does my author mean by...", "tell me about the
    /// author..."). The "me" in a request opener is a marker by the letter of
    /// the first-person rule and not by its spirit, which is why the request
    /// shapes are listed here rather than trusted to the marker test.
    /// Lowercased, compared against the lowercased message head.
    private static let bookQuestionOpeners = [
        "what does", "what is", "what are", "who is", "who was",
        "explain", "summarize", "summarise", "define",
        "tell me", "give me", "show me", "recommend", "which book", "what book",
    ]

    /// A first-person marker, as a whole word: "I", "I'm"/"I've"/"I'd"/"I'll"
    /// with either apostrophe, "my", "me", "myself". Word-bounded on letters
    /// only, so "Igor" and "ME" as an abbreviation are not markers but "I."
    /// at a sentence end is.
    private static let firstPersonPattern =
        #"(^|[^A-Za-z])(I|I['’](m|ve|d|ll)|[Mm]y|[Mm]e|[Mm]yself)([^A-Za-z]|$)"#

    /// Whether a chat message reads as him describing his own situation.
    ///
    /// Pure, no model call, and small enough to hold in one hand: length in
    /// range, not opened like a book question, not mostly a quotation, and
    /// carrying at least one first-person marker. It is a filter for the CARD,
    /// not a classifier that writes anything down -- which is exactly why a
    /// heuristic this plain is acceptable here and was not acceptable for the
    /// auto-journal half of the same instruction. A wrong answer here costs one
    /// dull card that turns over in nine seconds.
    static func isSituationShaped(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard chatReflectionLength.contains(trimmed.count) else { return false }
        let lowered = trimmed.lowercased()
        if bookQuestionOpeners.contains(where: { lowered.hasPrefix($0) }) { return false }
        guard quotedShare(of: trimmed) < 0.5 else { return false }
        return trimmed.range(of: firstPersonPattern, options: .regularExpression) != nil
    }

    /// The fraction of characters sitting inside straight or curly double
    /// quotes. The chat prefill path wraps a passage in quotes and puts it
    /// first (`ChatView.applyPendingDeepLinkPrefill`), so a message that is
    /// mostly quotation is a highlight he asked about, not a situation.
    static func quotedShare(of text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        var inside = false
        var quoted = 0
        for character in text {
            switch character {
            case "\"": inside.toggle()
            case "“": inside = true
            case "”": inside = false
            default: if inside { quoted += 1 }
            }
        }
        return Double(quoted) / Double(text.count)
    }

    /// A stable identity for a message that has none of its own. Version-5
    /// shaped over a fixed namespace, the same construction
    /// `JournalEntryComposeView.writeBackDraftKey` uses, so it cannot collide
    /// with a real row's random UUID in practice.
    static func stableChatID(date: Date, text: String) -> UUID {
        let seed = "cobux.journal.chat-reflection:\(date.timeIntervalSince1970):\(text)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// One message becomes a card, or none. Every gate the window applies to
    /// his writing applies here too, plus the shape test: the quiet-words
    /// choke point (a name he quieted is quiet in chat as well), the quoting
    /// exclusions (the same phrases the selector refuses to put on a screen
    /// unprompted), permanent suppression, and this sitting's dealt set --
    /// which for this card is a HARD exclusion, not the soft one entries get:
    /// better no chat card than the same one twice in an afternoon.
    static func chatReflection(from messages: [ChatSnapshot],
                               suppressed: Set<UUID>,
                               alreadyDealt: Set<UUID>,
                               now: Date,
                               seed: UInt64) -> ChatReflection? {
        guard !messages.isEmpty,
              let floor = Calendar.current.date(byAdding: .day,
                                                value: -chatReflectionWindowDays, to: now)
        else { return nil }
        let eligible: [ChatReflection] = messages.compactMap { message in
            guard message.date >= floor, message.date <= now,
                  isSituationShaped(message.text),
                  JournalHighlightSelector.maySurface(message.text),
                  JournalHighlightSelector.isSafeToQuote(message.text)
            else { return nil }
            let id = stableChatID(date: message.date, text: message.text)
            guard !suppressed.contains(id), !alreadyDealt.contains(id) else { return nil }
            let excerpt = message.text
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            return ChatReflection(id: id, date: message.date, excerpt: excerpt)
        }
        guard !eligible.isEmpty else { return nil }
        // Stable for the day within a round, different across rounds -- the
        // same contract the walk keeps, by the same means.
        var generator = EbbDeckBuilder.SeededGenerator(seed: seed)
        return eligible[Int(generator.next() % UInt64(eligible.count))]
    }

    /// The one line compose opens with when he chooses to reflect. His own
    /// words, attributed to the conversation they came from, and nothing
    /// else: no question, no prompt, no "consider". The page under it is
    /// his.
    static func reflectionLead(for reflection: ChatReflection) -> String {
        var quote = reflection.excerpt
        if quote.count > reflectionLeadQuoteLength {
            let head = String(quote.prefix(reflectionLeadQuoteLength))
            // Back up to the last whole word, then drop any trailing
            // punctuation the cut left behind, so the ellipsis follows a word.
            let cut = head.lastIndex(where: \.isWhitespace).map { String(head[..<$0]) } ?? head
            quote = cut.trimmingCharacters(in: CharacterSet.punctuationCharacters
                                              .union(.whitespaces)) + "…"
        }
        return "Earlier I told Cobux: “\(quote)”"
    }

    /// A walk card's place in the round, lowest first.
    ///
    /// Spelled out as a `Comparable` struct rather than left as a tuple so the
    /// five keys have names at the comparison site as well as at the point they
    /// are computed -- `$0.rank < $1.rank` on a bare 5-tuple is exactly the kind
    /// of line that gets a key transposed during a later edit and produces a
    /// deck nobody can explain.
    private struct Rank: Comparable {
        /// 0 when this entry is from today's calendar date in an earlier year.
        let onThisDay: Int
        /// 1 when an earlier round this sitting already dealt it.
        let dealtThisSitting: Int
        /// 1 when it shares a month with today's pick -- two neighbours rather
        /// than two distances.
        let pickMonth: Int
        /// 1 when it has surfaced inside the cooldown window. Demotion only.
        let recentlyShown: Int
        /// The day-seeded shuffle's own order, which makes the total order
        /// deterministic without relying on `sort` being stable.
        let shuffled: Int

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            (lhs.onThisDay, lhs.dealtThisSitting, lhs.pickMonth,
             lhs.recentlyShown, lhs.shuffled)
                < (rhs.onThisDay, rhs.dealtThisSitting, rhs.pickMonth,
                   rhs.recentlyShown, rhs.shuffled)
        }
    }

    /// Whether a card actually quotes him.
    ///
    /// The one thing every slot in this window must be true of. `.eraDivider`
    /// and `.endCard` are Ebb's own furniture and never dealt here; `.reference`
    /// is the card he called useless and is no longer built by anything in the
    /// journal -- this is what makes that true of a card handed IN as well as
    /// one dealt out.
    private static func carriesAPassage(_ card: EbbCard) -> Bool {
        switch card {
        case .passage, .onThisDay, .echo, .kept, .asked: true
        case .reference, .eraDivider, .endCard: false
        }
    }

    /// One entry becomes the most specific card it honestly supports, or none.
    /// Mirrors `EbbDeckBuilder`'s rule, including refusing a calendar claim on a
    /// date the app does not actually know.
    ///
    /// `nil` where this used to return `.reference`. The old fallback answered
    /// the wrong question: when no passage clears the guards, the alternative to
    /// a bad quote is the NEXT ENTRY, not a word count. See `Pick` in
    /// `JournalHighlightSelector` for his report.
    private static func card(for entry: EbbDeckBuilder.EntrySnapshot,
                             calendar: Calendar, now: Date) -> EbbCard? {
        let standalone = Set(JournalHighlightSelector.stripStamp(entry.text)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) })
        guard let passage = JournalHighlightSelector.best(
            from: JournalHighlightSelector.candidates(in: entry.text),
            standaloneLines: standalone) else { return nil }
        let today = calendar.dateComponents([.month, .day], from: now)
        let then = calendar.dateComponents([.month, .day], from: entry.date)
        if entry.dateIsCertain, then.month == today.month, then.day == today.day {
            return .onThisDay(entryID: entry.id, date: entry.date, text: passage)
        }
        return .passage(entryID: entry.id, date: entry.date,
                        text: passage, dateIsCertain: entry.dateIsCertain)
    }
}
