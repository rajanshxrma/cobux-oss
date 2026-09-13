import CryptoKit
import Foundation
import NaturalLanguage

// Decisions taken for build 62 while he was away (docs/people-in-the-journal.md
// §7, "Five questions only he can answer"), recorded here because this is the
// file every one of them shapes:
//
//   Q1  Role words ("my mom", "my ex", "nani") are NOT people. A role is not a
//       name, and a page titled "Mom" the app invented is the wrong-page
//       failure the spec puts first. Only forms the tagger marks as a personal
//       name enter the index.
//   Q2  The summary (build 63) is never readable without Face ID. The section
//       stays inside `JournalLocked`; nothing here changes that.
//   Q3  The section sits beside Volumes, one level below the journal list.
//   Q4  "Notice people in my journal" defaults ON. His rule tonight: a feature
//       behind an untold switch does not exist. Recognition is on-device and
//       writes nothing outside the store, so the default costs nothing he has
//       not already accepted by writing in the app.
//   Q5  No Contacts matching in 62. Picker only; the permission string and the
//       promise "never reads your address book" are untouched.
//
// If he answers any of the five differently, the constant or rule it names is
// in exactly one place below.

/// Finds the people in his writing -- the pure half of People, in the
/// `VolumeBinder` shape: values in, values out, no store, no view, so every
/// rule lives in the test harness.
///
/// The engine is `NLTagger(.nameType)` on the device, English, keeping
/// `.personalName` only (`docs/people-in-the-journal.md` §2, measured on his
/// real export: 246 entries in 0.66 s, ~1 ms an entry after that). Nothing
/// here touches the network, a model download, or an entitlement.
///
/// **Clustering is exact.** Forms fold to one person by case-insensitive
/// match and by an alias HE confirmed (`aliasFolds`). No fuzzy matching, no
/// first-letter matching, no embedding similarity between names -- every one
/// of those is how "Priya" and "Priyan" become one person, and that is the
/// wrong-page failure the spec puts before everything else. `.joinNames` keeps
/// "Jordan Peterson" whole; a bare "Peterson" stays a separate form until he
/// merges it.
///
/// **What is not a person** -- in order, each rule cheap and explainable:
///   1. himself: his display name and its first token (`selfNames`);
///   2. authors: any form equal to a `Book.author` or its last token
///      (`authorSurnames`) -- the library is the app's only public-figure
///      list, and the only one worth having;
///   3. shape: three or more letters, capitalised in at least half of its
///      mentions (the 12-in-649 finding turned into a rule -- it drops "tha",
///      "lemme", "ye" and keeps a real name he once typed in lowercase), and
///      never a token from a session stamp line;
///   4. his list: anything he marked *Not a person* (`notPersonForms`), and
///      anything in `JournalQuietWords` (`quietWords`) -- a quiet word is
///      never indexed, and an entry that carries one is dropped from every
///      person's ids, the same whole-entry rule every ambient surface applies.
/// A form he has confirmed (`confirmedPersonForms`) outranks rules 1 and 2:
/// once he has said a name is a person, an author's surname does not unsay it.
///
/// **Tiers are measured, not guessed**: Listed in three or more entries,
/// Noticed in two, one entry never shown. Tunable in one place below.
///
/// **Incremental**: a `ScanRecord` per entry, keyed by `textHash`; an
/// unchanged entry is never re-tagged. The ledger is machine-derived and
/// regenerable, so the indexer keeps it in a file, never in the model.
///
/// Nothing here ranks. Counts exist only to reach a tier and to order forms
/// within one person; no count leaves this type as a score.
enum JournalPeopleRecognizer {
    // MARK: - Values

    struct EntrySnapshot: Sendable, Equatable {
        let id: UUID
        /// `modifiedDate ?? dateImported` -- the stamp the feed sorts by.
        let stamp: Date
        let text: String
        /// `JournalPeopleRecognizer.textHash(text)`, carried rather than
        /// recomputed so the indexer hashes each entry exactly once.
        let textHash: String

        init(id: UUID, stamp: Date, text: String, textHash: String) {
            self.id = id
            self.stamp = stamp
            self.text = text
            self.textHash = textHash
        }
    }

    /// Everything that keeps a form off the list. Every set is matched
    /// case-insensitively; callers may pass forms in any case.
    struct Exclusions: Sendable, Equatable {
        /// `Book.author` values and their last tokens.
        var authorSurnames: Set<String>
        /// His display name and its first token, plus every form of a row he
        /// marked "This is me".
        var selfNames: Set<String>
        /// `JournalQuietWords.all()`.
        var quietWords: Set<String>
        /// `EbbSuppressionStore.suppressedIDs()` -- "never show this again"
        /// has to mean never, on every surface.
        var suppressedEntryIDs: Set<UUID>
        /// Every form of a row he marked "Not a person".
        var notPersonForms: Set<String>
        /// Every form of a row he confirmed (Add, Rename, Merge). Outranks
        /// the self and author rules, never the quiet or not-a-person ones.
        var confirmedPersonForms: Set<String>

        init(authorSurnames: Set<String> = [],
             selfNames: Set<String> = [],
             quietWords: Set<String> = [],
             suppressedEntryIDs: Set<UUID> = [],
             notPersonForms: Set<String> = [],
             confirmedPersonForms: Set<String> = []) {
            self.authorSurnames = authorSurnames
            self.selfNames = selfNames
            self.quietWords = quietWords
            self.suppressedEntryIDs = suppressedEntryIDs
            self.notPersonForms = notPersonForms
            self.confirmedPersonForms = confirmedPersonForms
        }
    }

    enum Tier: String, Sendable, Codable {
        case listed
        case noticed
    }

    struct PersonCluster: Sendable, Equatable {
        /// Surface forms, most frequent first. `forms[0]` is the display
        /// name for a row the indexer creates.
        let forms: [String]
        /// Newest first.
        let entryIDs: [UUID]
        let tier: Tier
        let firstSeen: Date
        let lastSeen: Date

        /// The case-folded key every form of this cluster resolves to.
        let key: String

        init(forms: [String], entryIDs: [UUID], tier: Tier, firstSeen: Date, lastSeen: Date, key: String? = nil) {
            self.forms = forms
            self.entryIDs = entryIDs
            self.tier = tier
            self.firstSeen = firstSeen
            self.lastSeen = lastSeen
            self.key = key ?? JournalPeopleRecognizer.fold(forms.first ?? "")
        }
    }

    /// What one entry's tagging produced. Machine-derived and regenerable --
    /// this is the ledger row, never a model row.
    struct ScanRecord: Sendable, Codable, Equatable {
        let textHash: String
        /// Surface forms exactly as tagged, duplicates kept: the
        /// capitalisation rule needs every mention, not the distinct set.
        let forms: [String]
    }

    struct ScanResult: Sendable {
        let clusters: [PersonCluster]
        /// The ledger after this scan: one record per entry that was in the
        /// input and has been tagged. Entries absent from the input are
        /// dropped; entries beyond the budget are left out so the next pass
        /// tags them.
        let ledger: [UUID: ScanRecord]
        /// Entries the tagger ran on this scan.
        let taggedEntries: Int
        /// Entries that still need tagging (budget exhausted). Zero means the
        /// clusters cover the whole input.
        let pendingEntries: Int
    }

    // MARK: - Thresholds (the tunable constants, in one place)

    /// In this many entries or more, a person gets a page.
    static let listedThreshold = 3
    /// In this many entries, a name is shown only on the "Also noticed" line.
    static let noticedThreshold = 2
    /// A form shorter than this is never a name ("dk", "ye").
    static let minimumLetters = 3

    // MARK: - Hashing and folding

    /// Stable across launches and processes (unlike `Hasher`): SHA-256 hex.
    static func textHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The clustering key: trimmed, lowercased, inner whitespace collapsed.
    /// Nothing else -- no diacritic stripping, no stemming: exactness is the
    /// rule.
    static func fold(_ form: String) -> String {
        form.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    // MARK: - Tagging

    /// Every `.personalName` in `text`, in order, as surface forms.
    ///
    /// Stamp lines are dropped before tagging: a stamp's place tail
    /// ("· Berlin") is a name-shaped token the tagger may take for a person,
    /// and a stamp is the app's writing, not his. Possessives are trimmed
    /// ("Priya's" → "Priya") so one person is not two forms. English is set
    /// explicitly: on a short entry language detection can fail and the
    /// tagger then returns nothing at all.
    static func tag(_ text: String) -> [String] {
        let body = text.components(separatedBy: .newlines)
            .filter { !JournalSessionStamp.isStampLine($0) }
            .joined(separator: "\n")
        guard body.contains(where: { $0.isLetter }) else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = body
        let whole = body.startIndex..<body.endIndex
        tagger.setLanguage(.english, range: whole)
        var forms: [String] = []
        tagger.enumerateTags(in: whole, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName, let form = cleanedForm(String(body[range])) {
                forms.append(form)
            }
            return true
        }
        return forms
    }

    /// Trims a tagged span to the name itself: outer non-letters, a trailing
    /// possessive, inner whitespace collapsed. Nil when nothing is left.
    static func cleanedForm(_ raw: String) -> String? {
        var form = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The possessive first, so a bare "’s" leaves nothing rather than "s".
        for suffix in ["'s", "’s", "'S", "’S"] where form.hasSuffix(suffix) {
            form = String(form.dropLast(suffix.count))
        }
        form = form.trimmingCharacters(in: CharacterSet.letters.inverted)
        form = form.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return form.isEmpty ? nil : form
    }

    // MARK: - Recognition

    /// The convenience the list and the harness use: a full scan, no ledger,
    /// no budget, the real tagger.
    static func recognize(entries: [EntrySnapshot], exclusions: Exclusions) -> [PersonCluster] {
        scan(entries: entries, exclusions: exclusions).clusters
    }

    /// One pass over the entries.
    ///
    /// - Parameters:
    ///   - ledger: the previous scan's records; an entry whose `textHash`
    ///     matches its record is not re-tagged (`tagger` is not called).
    ///   - aliasFolds: folded form → folded canonical key, from the aliases
    ///     HE confirmed on existing rows. The only way two different folds
    ///     become one person.
    ///   - budget: at most this many entries are tagged this pass; the rest
    ///     are reported as pending and left out of the clusters (a cold index
    ///     of 3,000 entries must never sit in front of the tab). Nil = all.
    ///   - tagger: injectable so the harness can prove the incremental rule
    ///     and keep the clustering tests independent of the on-device model.
    static func scan(entries: [EntrySnapshot],
                     exclusions: Exclusions,
                     ledger previous: [UUID: ScanRecord] = [:],
                     aliasFolds: [String: String] = [:],
                     budget: Int? = nil,
                     tagger: (String) -> [String] = JournalPeopleRecognizer.tag) -> ScanResult {
        // 1. The ledger: reuse, tag within budget, or defer.
        var ledger: [UUID: ScanRecord] = [:]
        var tagged = 0
        var pending = 0
        var covered: [EntrySnapshot] = []
        for entry in entries {
            if let record = previous[entry.id], record.textHash == entry.textHash {
                ledger[entry.id] = record
                covered.append(entry)
                continue
            }
            if let budget, tagged >= budget {
                pending += 1
                continue
            }
            let record = ScanRecord(textHash: entry.textHash, forms: tagger(entry.text))
            ledger[entry.id] = record
            covered.append(entry)
            tagged += 1
        }

        // 2. Entry-level gates: a suppressed entry, or one carrying a quiet
        //    word anywhere, contributes nothing to anyone.
        let quiet = exclusions.quietWords.map { $0.lowercased() }.filter { !$0.isEmpty }
        let eligible = covered.filter { entry in
            guard !exclusions.suppressedEntryIDs.contains(entry.id) else { return false }
            guard !quiet.isEmpty else { return true }
            let lowered = entry.text.lowercased()
            return !quiet.contains { lowered.contains($0) }
        }

        // 3. Fold every mention onto its key.
        struct Tally {
            var surfaceCounts: [String: Int] = [:]
            var mentions = 0
            var capitalised = 0
            var entryIDs: Set<UUID> = []
            var stamps: [Date] = []
        }
        var tallies: [String: Tally] = [:]
        let quietSet = Set(quiet)
        for entry in eligible {
            guard let record = ledger[entry.id] else { continue }
            var seenHere: Set<String> = []
            for form in record.forms {
                let folded = fold(form)
                guard !folded.isEmpty else { continue }
                // A form that is itself a quiet word is never indexed at all.
                guard !quietSet.contains(folded) else { continue }
                let key = aliasFolds[folded] ?? folded
                var tally = tallies[key] ?? Tally()
                tally.surfaceCounts[form, default: 0] += 1
                tally.mentions += 1
                if form.first?.isUppercase == true { tally.capitalised += 1 }
                if seenHere.insert(key).inserted {
                    tally.entryIDs.insert(entry.id)
                    tally.stamps.append(entry.stamp)
                }
                tallies[key] = tally
            }
        }

        // 4. The rules, then the tiers.
        let stampsByID = Dictionary(entries.map { ($0.id, $0.stamp) }, uniquingKeysWith: { first, _ in first })
        let authors = Set(exclusions.authorSurnames.map(fold))
        let selves = Set(exclusions.selfNames.map(fold))
        let notPeople = Set(exclusions.notPersonForms.map(fold))
        let confirmed = Set(exclusions.confirmedPersonForms.map(fold))

        var clusters: [PersonCluster] = []
        for (key, tally) in tallies {
            let forms = tally.surfaceCounts.keys.sorted { lhs, rhs in
                let lc = tally.surfaceCounts[lhs] ?? 0, rc = tally.surfaceCounts[rhs] ?? 0
                if lc != rc { return lc > rc }
                let lu = lhs.first?.isUppercase == true, ru = rhs.first?.isUppercase == true
                if lu != ru { return lu }
                return lhs < rhs
            }
            let folds = Set(forms.map(fold)).union([key])
            // 4 first: his list is absolute, confirmed or not.
            if !folds.isDisjoint(with: notPeople) { continue }
            let isConfirmed = !folds.isDisjoint(with: confirmed)
            if !isConfirmed {
                // 1. himself
                if !folds.isDisjoint(with: selves) { continue }
                // 2. authors
                if !folds.isDisjoint(with: authors) { continue }
            }
            // 3. shape -- always, even when confirmed: a confirmed row was
            //    created from a form that already passed it.
            guard key.filter({ $0.isLetter }).count >= minimumLetters else { continue }
            guard tally.capitalised * 2 >= tally.mentions else { continue }

            let count = tally.entryIDs.count
            let tier: Tier
            // A form HE confirmed stays listed while one entry still names
            // it; below the threshold it would otherwise vanish from the
            // recogniser while its confirmed row stayed listed with zero
            // entries -- a page reading "Mentioned in 0 entries".
            if count >= listedThreshold || (confirmed.contains(key) && count >= 1) { tier = .listed }
            else if count >= noticedThreshold { tier = .noticed }
            else { continue }

            let ids = tally.entryIDs.sorted { lhs, rhs in
                let ls = stampsByID[lhs] ?? .distantPast, rs = stampsByID[rhs] ?? .distantPast
                if ls != rs { return ls > rs }
                return lhs.uuidString < rhs.uuidString
            }
            clusters.append(PersonCluster(forms: forms,
                                          entryIDs: ids,
                                          tier: tier,
                                          firstSeen: tally.stamps.min() ?? .distantPast,
                                          lastSeen: tally.stamps.max() ?? .distantPast,
                                          key: key))
        }

        // The order his writing put them in, never a rank.
        clusters.sort { lhs, rhs in
            if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
            return lhs.key < rhs.key
        }
        return ScanResult(clusters: clusters, ledger: ledger, taggedEntries: tagged, pendingEntries: pending)
    }

    // MARK: - Exclusion builders

    /// `Book.author` values and their last tokens, folded. "Jordan B.
    /// Peterson" excludes "jordan b. peterson" and "peterson".
    static func authorSurnames(fromAuthors authors: [String]) -> Set<String> {
        var out: Set<String> = []
        for author in authors {
            let folded = fold(author)
            guard !folded.isEmpty else { continue }
            out.insert(folded)
            if let last = folded.split(separator: " ").last { out.insert(String(last)) }
        }
        return out
    }

    /// His display name and its first token, folded. Empty when unset --
    /// the first open of People then asks "Which of these is you?".
    static func selfNames(fromDisplayName name: String) -> Set<String> {
        let folded = fold(name)
        guard !folded.isEmpty else { return [] }
        var out: Set<String> = [folded]
        if let first = folded.split(separator: " ").first { out.insert(String(first)) }
        return out
    }

    // MARK: - Row edits, as pure values (the model's methods mirror these)

    /// Merge into…: the loser's forms join the winner's, ids are unioned
    /// (winner's order first), the span widens. Reversible by `split`.
    static func merged(winner: PersonCluster, loser: PersonCluster) -> PersonCluster {
        var forms = winner.forms
        let known = Set(forms.map(fold))
        forms.append(contentsOf: loser.forms.filter { !known.contains(fold($0)) })
        let ids = winner.entryIDs + loser.entryIDs.filter { !Set(winner.entryIDs).contains($0) }
        let tier: Tier = ids.count >= listedThreshold ? .listed : .noticed
        return PersonCluster(forms: forms, entryIDs: ids, tier: tier,
                             firstSeen: min(winner.firstSeen, loser.firstSeen),
                             lastSeen: max(winner.lastSeen, loser.lastSeen),
                             key: winner.key)
    }

    /// Split: removes one form (never the display form) so the next scan
    /// recreates its own cluster; ids stay until that scan recomputes them.
    static func split(form: String, from cluster: PersonCluster) -> PersonCluster {
        let target = fold(form)
        guard cluster.forms.count > 1, fold(cluster.forms[0]) != target else { return cluster }
        let forms = cluster.forms.filter { fold($0) != target }
        return PersonCluster(forms: forms, entryIDs: cluster.entryIDs, tier: cluster.tier,
                             firstSeen: cluster.firstSeen, lastSeen: cluster.lastSeen, key: cluster.key)
    }
}
