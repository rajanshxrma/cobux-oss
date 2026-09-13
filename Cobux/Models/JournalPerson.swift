import Foundation
import SwiftData

/// What kind of row a `JournalPerson` is. Raw values are what the store and
/// the backup carry; the case names are what code reads.
///
/// `isSelf` is spelled that way because `self` cannot be an enum case in Swift
/// without backticks at every use (`JournalPersonKind.self` is the metatype).
/// Its raw value is still `"self"`, as the People spec (§2) names it.
enum JournalPersonKind: String {
    case person
    case isSelf = "self"
    case notPerson
}

/// One person the journal has noticed, and everything HE has decided about
/// them -- and nothing else.
///
/// The split the People spec (`docs/people-in-the-journal.md` §2, "Where the
/// index lives") draws is by *who decided*. This row holds his decisions --
/// the name he confirmed, the forms he folded in, whether it is him, whether
/// it is a person at all, which contact he linked -- and pointers to his own
/// entries. Everything the machine derived on its own (which entry carried
/// which surface form, text hashes) lives in the regenerable scan ledger
/// (`JournalPeopleIndexer`), not here, so the store never becomes a dossier:
/// a row with its ledger deleted is rebuilt in a second from his writing.
///
/// `SituationThread`'s ruling stands: nothing the app inferred about the
/// other person is ever stored as a fact. The one generated text this row
/// can carry (`summary`, build 63) is a rendering of what HE wrote, bound to
/// his words by its prompt, cached by fingerprint, regenerable and deletable
/// -- a Volume, not a finding.
///
/// `entryIDs` is a stored `[UUID]`, not a join table: `JournalKeep.entryID` is
/// the precedent -- a reference by id, never a copy, and it survives a restore
/// because `PersonalWritingEntryDTO.id` round-trips. Newest first.
///
/// No relationships on purpose: the indexer runs while seeding may still be
/// touching the store, and a row with no relationship can never be faulted.
///
/// Additive optional attributes only, ever -- the one schema change SwiftData
/// migrates in place (`PersonalWritingEntry.writingSeconds` carries the
/// ruling). This type is compiled into the widget and Messages targets
/// because they share `Cobux/Models` and must open the store with the same
/// schema; neither may ever *fetch* it (`swiftui-regression-lint.py`,
/// `people-index-in-extension`).
@Model
final class JournalPerson {
    /// Assigned in `init` too, not left to the schema default alone -- see
    /// `PersonalWritingEntry.id` for why a default-valued UUID is evaluated
    /// once per schema, not once per row.
    var id: UUID = UUID()
    /// The display form he confirmed, or the cluster's most frequent form.
    /// Once he renames, the indexer never touches it again.
    var name: String = ""
    /// Other surface forms folded into this person (case-insensitive
    /// matching). The indexer adds forms it finds; only he removes one
    /// (Split).
    var aliases: [String] = []
    /// `JournalPersonKind.rawValue`. A `notPerson` row is the memory of his
    /// "Not a person" tap: its forms are never listed again.
    var kindRaw: String = JournalPersonKind.person.rawValue
    /// `PersonalWritingEntry.id`s that mention this person, newest first.
    var entryIDs: [UUID] = []
    /// Earliest entry stamp (`modifiedDate ?? dateImported`) among `entryIDs`.
    var firstSeen: Date?
    var lastSeen: Date?
    /// `CNContact.identifier` when he linked a contact through the picker.
    /// Never matched by the app on its own (build 62: picker only).
    var contactIdentifier: String?
    var contactLinkedDate: Date?
    /// Build 63. Generated only when he taps, from his own dated excerpts.
    var summary: String?
    /// Build 63. `SHA256(promptVersion + useRealNames + sorted(entryID:textHash))`
    /// of the set the summary was built from -- a changed set shows the
    /// "Newer entries — refresh" chip, never a silent regeneration.
    var summaryFingerprint: String?
    /// Build 63. "N entries, <first> to <last>" -- the kicker's honesty line.
    var summaryBasis: String?
    var summaryGeneratedDate: Date?
    /// When HE acted on this row (Add from the Noticed line, Rename, Merge,
    /// This is me). A confirmed row outranks the shape rules: a name that
    /// happens to equal an author's surname stays listed once he has said it
    /// is a person. Nil for a row the indexer created and he never touched.
    var confirmedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(name: String,
         kind: JournalPersonKind = .person,
         aliases: [String] = [],
         entryIDs: [UUID] = [],
         firstSeen: Date? = nil,
         lastSeen: Date? = nil) {
        self.id = UUID()
        self.name = name
        self.aliases = aliases
        self.kindRaw = kind.rawValue
        self.entryIDs = entryIDs
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.createdAt = .now
        self.updatedAt = .now
    }

    var kind: JournalPersonKind {
        get { JournalPersonKind(rawValue: kindRaw) ?? .person }
        set { kindRaw = newValue.rawValue }
    }

    /// A fact about his archive, stated once, small, as part of a sentence
    /// ("in 47 entries"). Never a numeral, never a sort key, never a score.
    var mentionCount: Int { entryIDs.count }

    /// Every form this row answers to: the name and each alias.
    var allForms: [String] { [name] + aliases }

    /// Case-insensitive: "priya" and "Priya" are one person.
    func matches(form: String) -> Bool {
        let wanted = form.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return false }
        return allForms.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    /// Folds a surface form into the aliases unless it is already the name
    /// or an alias (case-insensitive). Returns whether anything changed.
    @discardableResult
    func addAlias(_ form: String) -> Bool {
        let trimmed = form.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !matches(form: trimmed) else { return false }
        aliases.append(trimmed)
        updatedAt = .now
        return true
    }

    /// Merge into…: the loser's forms become aliases of this row and its
    /// entry ids are unioned in (this row's order first, the loser's extras
    /// after; the next indexer pass restores newest-first). The caller
    /// deletes the loser row. Reversible by `split(alias:)`.
    func merge(_ loser: JournalPerson) {
        for form in loser.allForms { addAlias(form) }
        let known = Set(entryIDs)
        entryIDs.append(contentsOf: loser.entryIDs.filter { !known.contains($0) })
        firstSeen = [firstSeen, loser.firstSeen].compactMap { $0 }.min()
        lastSeen = [lastSeen, loser.lastSeen].compactMap { $0 }.max()
        confirmedAt = .now
        updatedAt = .now
    }

    /// Split: removes one alias so the next pass can recreate its own row.
    /// The entry ids stay until that pass recomputes them -- a page is never
    /// left pointing at nothing in between.
    @discardableResult
    func split(alias: String) -> Bool {
        let before = aliases.count
        aliases.removeAll { $0.caseInsensitiveCompare(alias) == .orderedSame }
        guard aliases.count != before else { return false }
        confirmedAt = .now
        updatedAt = .now
        return true
    }
}
