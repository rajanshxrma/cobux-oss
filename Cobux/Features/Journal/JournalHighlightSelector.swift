import Foundation

/// Picks one thing worth showing him from his own journal.
///
/// Built to Fable's design ruling, and the ruling's frame is the point: what
/// makes his own words land is that he always knows WHY he is being shown
/// something, and that the surface **quotes and dates but never characterizes**.
/// The moment it says "you seemed…" it is an invasion; while it only says "you
/// wrote this, here, then," it is a mirror.
///
/// Two selection rules earn their place. A third — "sentences unusual for him",
/// measured as distance from his corpus centroid — was proposed and vetoed:
/// unusual selects for the darkest 2 AM material by construction, and it cannot
/// be explained to him in a kicker. Both invasive failure modes in one feature.
enum JournalHighlightSelector {
    /// What the card shows. Deliberately has no "mood", "insight" or "theme"
    /// case — there is no vocabulary here for characterizing him.
    ///
    /// It also, since build 56, has no `.reference` case. That one carried no
    /// passage — it rendered as *"You wrote N words here."* — and Rajan named it
    /// exactly: *"in the from your archive part where it says how many words I
    /// wrote on a specific day, that's a useless information."* He is right, and
    /// the original argument for it ("an embarrassing fragment is a bug; a
    /// reference never is") answered the wrong question: the alternative to a
    /// bad quote is not a word count, it is **the next entry**. Every selection
    /// path now skips an entry whose passages cannot clear the guards and picks
    /// another, so the window is always his writing and never bookkeeping.
    enum Pick: Equatable {
        /// A passage from this calendar date in an earlier year or month.
        case onThisDay(entryID: UUID, date: Date, passage: String)
        /// A passage from further back, when no date correspondence exists.
        /// Kept a distinct case rather than reusing `onThisDay` with a fudged
        /// kicker: the card must never claim a connection it does not have.
        case fromArchive(entryID: UUID, date: Date, passage: String)
        /// His sentence beside the book highlight it sits closest to.
        case resonance(entryID: UUID, date: Date, passage: String,
                       highlight: String, bookTitle: String)

        var entryID: UUID {
            switch self {
            case let .onThisDay(id, _, _), let .fromArchive(id, _, _): id
            case let .resonance(id, _, _, _, _): id
            }
        }
    }

    /// Fresh writing is a wound, not a highlight. Non-negotiable floor.
    static let minimumAgeDays = 14
    /// How long before the same entry may be surfaced again.
    static let reshowCooldownDays = 60

    private static let minLength = 40
    private static let maxLength = 200
    private static let minWords = 6

    /// Excluded from QUOTING outright. The entry is then simply passed over and
    /// another chosen — the writing is not the problem, putting these words on a
    /// screen unprompted is. (It used to fall through to a `.reference` card
    /// instead; that card no longer exists. Nothing about the exclusion changed,
    /// only what happens after it.)
    private static let excluded = [
        "kill myself", "want to die", "end it all", "suicide", "self harm",
        "hurt myself", "worthless piece", "hate myself",
    ]

    /// Whether an entry may appear on any ambient surface at all.
    ///
    /// THE choke point. The journal card, Ebb, and Flow's echo all funnel here,
    /// so a word he quiets is quiet everywhere at once and nothing added later
    /// has to remember the rule. See `JournalQuietWords` for why the app refuses
    /// to infer this for him.
    static func maySurface(_ text: String) -> Bool {
        !JournalQuietWords.isQuiet(text)
    }

    /// Whether a text is free of the phrases this file refuses to put on a
    /// screen unprompted. `passes` applies this to a passage among its other
    /// guards; this is the same list on its own, for a surface that quotes
    /// something that is not a journal passage -- the threshold's "From your
    /// chat" card, which shows a message he sent rather than a line he wrote.
    /// One list, two callers, so nothing added to it later has to be added
    /// twice.
    static func isSafeToQuote(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return !excluded.contains(where: { lowered.contains($0) })
    }

    /// Every passage in `text` that is safe and good enough to show.
    ///
    /// Splits on sentence enders AND newlines: his aphorisms tend to live as
    /// standalone lines rather than inside paragraphs, and those are the lines
    /// worth surfacing.
    static func candidates(in text: String) -> [String] {
        let body = JournalHighlightSelector.stripStamp(text)
        var pieces: [String] = []
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // A standalone short line is itself a candidate; longer lines get
            // split into sentences.
            if trimmed.count <= maxLength {
                pieces.append(trimmed)
            }
            var current = ""
            for character in trimmed {
                current.append(character)
                if character == "." || character == "!" || character == "?" {
                    pieces.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
            }
            if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                pieces.append(current.trimmingCharacters(in: .whitespaces))
            }
        }
        var seen = Set<String>()
        return pieces.filter { passes($0) && seen.insert($0).inserted }
    }

    /// The quality and safety guards. Everything here exists so a fragment can
    /// never embarrass him.
    static func passes(_ passage: String) -> Bool {
        let trimmed = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minLength, trimmed.count <= maxLength else { return false }
        guard trimmed.split(whereSeparator: \.isWhitespace).count >= minWords else { return false }
        guard let first = trimmed.first, first.isUppercase || first == "I" else { return false }
        // A leading session stamp is machinery, not writing.
        if trimmed.range(of: #"^\d{1,2}:\d{2}"#, options: .regularExpression) != nil { return false }
        let lowered = trimmed.lowercased()
        if excluded.contains(where: { lowered.contains($0) }) { return false }
        return true
    }

    /// Drops the session stamp the app writes at the head of every entry.
    static func stripStamp(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return text }
        let head = first.trimmingCharacters(in: .whitespaces)
        // One shared matcher -- a stamp carrying a weather/place tail
        // must still be stripped here, or a highlight card would quote the
        // machinery instead of his writing.
        let isStamp = JournalSessionStamp.isStampLine(head)
        guard isStamp else { return text }
        return lines.dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ranks candidates so the best line in an entry wins: standalone lines
    /// first (that is where the aphorisms are), then a length sweet spot around
    /// 110 characters — long enough to be a thought, short enough to read at a
    /// glance.
    static func best(from candidates: [String], standaloneLines: Set<String>) -> String? {
        candidates.max { a, b in score(a, standaloneLines) < score(b, standaloneLines) }
    }

    private static func score(_ passage: String, _ standalone: Set<String>) -> Double {
        var value = 0.0
        if standalone.contains(passage) { value += 40 }
        value -= abs(Double(passage.count) - 110) / 10.0
        return value
    }
}
