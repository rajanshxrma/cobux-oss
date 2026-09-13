import Foundation

/// One card in an Ebb deck.
///
/// The full design and its vetoes are in `docs/ebb.md`. The shape that matters
/// here: **there is deliberately no case for characterizing him.** No mood, no
/// theme, no insight, no "you seemed". A card that tells him what he is like is
/// not discouraged by convention, it is unrepresentable — the same discipline
/// `JournalHighlightSelector.Pick` already holds, extended to a whole deck.
///
/// There is also no case that counts things at him. A `.census` card
/// ("November 2025 · 2 entries") was proposed and cut: setting a full year
/// beside a thin one grades him by choreography, which is the frame he
/// rejected when he saw a checkmark on a widget.
enum EbbCard: Identifiable, Equatable {
    // No `.opener` case. The day's pick is mapped onto the ordinary cases by
    // `EbbView.openerCard`, so a separate one was declared, rendered, given a
    // kicker branch — and never constructed. That is precisely the dead-wiring
    // shape this whole feature exists downstream of; leaving it would have made
    // a fourth instance in one codebase.
    /// Something he wrote, quoted and dated. The connective tissue.
    case passage(entryID: UUID, date: Date, text: String, dateIsCertain: Bool = true)
    /// This calendar date, an earlier year.
    case onThisDay(entryID: UUID, date: Date, text: String)
    /// His passage beside the library line nearest it. The gold card.
    case echo(entryID: UUID, date: Date, passage: String, highlight: String, bookTitle: String)
    /// A passage he chose to keep, returning on its time ladder. The return of
    /// his own words is the question; nothing on the card asks one.
    case kept(keepID: UUID, entryID: UUID, passage: String, sourceDate: Date)
    /// A question he wrote to his future self, handed back dated. The app never
    /// composes one, never checks whether he answered, never marks one done.
    case asked(keepID: UUID, entryID: UUID, question: String, passage: String, sourceDate: Date)
    /// A chapter break in the walk backwards. Dates, never counts.
    case eraDivider(month: Int, year: Int)
    /// No passage cleared the guards, so this points instead of quoting.
    /// An embarrassing fragment is a bug; a reference never is.
    case reference(entryID: UUID, date: Date, words: Int, dateIsCertain: Bool = true)
    /// The deck ends on purpose. An ebb recedes; it does not loop.
    case endCard(totalEntries: Int, earliest: Date?)

    var id: String {
        switch self {
        case let .passage(entryID, date, _, _): "passage-\(entryID)-\(date.timeIntervalSince1970)"
        case let .onThisDay(entryID, _, _): "onthisday-\(entryID)"
        case let .echo(entryID, _, _, _, _): "echo-\(entryID)"
        case let .kept(id, _, _, _): "kept-\(id)"
        case let .asked(id, _, _, _, _): "asked-\(id)"
        case let .eraDivider(month, year): "era-\(year)-\(month)"
        case let .reference(entryID, _, _, _): "reference-\(entryID)"
        case .endCard: "end"
        }
    }

    /// The entry this card is about, for the tap-through and for suppression.
    /// A divider and the end card are about no entry.
    /// The keep this card came from, if any -- so the surface that shows a
    /// keep is also the surface that can let it go.
    var keepID: UUID? {
        switch self {
        case let .kept(id, _, _, _), let .asked(id, _, _, _, _): id
        default: nil
        }
    }

    var entryID: UUID? {
        switch self {
        case let .passage(id, _, _, _), let .onThisDay(id, _, _),
             let .echo(id, _, _, _, _), let .reference(id, _, _, _): id
        case let .kept(_, id, _, _), let .asked(_, id, _, _, _): id
        case .eraDivider, .endCard: nil
        }
    }

    /// Which month's hue colours this card's atmosphere, so a walk backwards
    /// visibly melts through seasons.
    var month: Int? {
        switch self {
        case let .passage(_, date, _, _), let .onThisDay(_, date, _),
             let .echo(_, date, _, _, _), let .reference(_, date, _, _):
            Calendar.current.component(.month, from: date)
        case let .kept(_, _, _, date), let .asked(_, _, _, _, date):
            Calendar.current.component(.month, from: date)
        case let .eraDivider(month, _): month
        case .endCard: nil
        }
    }
}

/// Identity for presenting Ebb, for the same reason `ComposeSession` exists: a
/// Bool latches `true` after a dropped presentation and every later tap becomes
/// a silent no-op, while a fresh identity is always a real state change.
struct EbbSession: Identifiable {
    let id = UUID()
}
