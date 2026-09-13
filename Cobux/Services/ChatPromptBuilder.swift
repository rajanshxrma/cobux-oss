import Foundation

/// The scoped→bookScoped / general→base branch `ChatView.sendMessage` used to own directly —
/// extracted so voice mode (`VoiceSessionController`) assembles turns through the exact same
/// logic instead of a parallel reimplementation that could silently drift from what text chat
/// does. A behavior-neutral refactor: `ChatView` switched onto this produces byte-identical
/// prompts to before.
enum ChatPromptBuilder {

    /// Sentinel thread id for the pinned "My Journal" chat thread -- a fixed
    /// UUID (never a real `Book.id`, which are all random v4s minted at seed/
    /// import time) so the existing `selectedBookID`/`ChatMessage.bookID`
    /// thread plumbing carries the journal thread with zero schema change:
    /// its history persists and scopes exactly like a book thread's. Must
    /// never change once shipped -- persisted `ChatMessage.bookID` rows and
    /// the restored-thread key both point at it.
    static let journalThreadID = UUID(uuidString: "4A4F5552-4E41-4C00-8000-000000000001")!

    enum Assembled {
        /// The "My Journal" thread -- grounded in the user's own
        /// `PersonalWritingEntry` rows, not book content, via
        /// `PromptTemplates.journalGrounded` + `SearchService.buildJournalContext`.
        /// Uncached like `.symposium`: the relevant-entries block changes with
        /// every question, so there is no stable prefix worth paying cache
        /// writes for. Carries no `referencedTitles` -- replies cite entries
        /// by date inline, and no `<sources>` declaration is requested.
        case journal(systemPrompt: String)
        /// Symposium mode always uses the full, unsplit library context regardless of any
        /// selected book — "a debate among authors" scoped to one book is degenerate.
        case symposium(systemPrompt: String, referencedTitles: [String])
        /// Carries no `referencedTitles` — not because a book-scoped reply can't cite
        /// anything (it can now draw on a second book; see
        /// `SearchService.buildSplitContextForBook`), but because chips are derived from
        /// the model's own `<sources>` declaration rather than from retrieval, for every
        /// thread type. `ChatView.completeReveal` parses that declaration and suppresses
        /// the chip for this thread's own book, so a chip appears here exactly when a
        /// reply genuinely reached beyond the book the thread is about.
        case bookScoped(stableSystemPrompt: String, dynamicContext: String)
        case general(stableSystemPrompt: String, dynamicContext: String, referencedTitles: [String])
    }

    /// Spoken-style instructions for a voice turn go in the dynamic (uncached) suffix, never
    /// the stable prefix — per Fable's voice architecture ruling, the cached prefix must stay
    /// byte-identical between text and voice so both channels share one Anthropic prompt-cache
    /// entry. `.general`/`.symposium` already have `PromptTemplates.sourcesInstruction` baked
    /// into their (stable) template, so their spoken variant reminds the model to still emit
    /// it. `.bookScoped` now carries that instruction too — it gained it once a book-scoped
    /// reply could genuinely draw on a second book — so its spoken variant appends the same
    /// reminder rather than omitting it as it did while the tag was never requested there.
    private static let spokenStyleCore = "\n\nThis reply will be read aloud by text-to-speech, not displayed as text. Answer in 2-4 short, plain sentences — no markdown, no bullet points, no headers. Spell out numbers as words."
    private static let spokenStyleSourcesReminder = " Still end with the <sources> line exactly as instructed above."

    /// `personalWritingEntries`/`personalWritingContextEnabled` default to
    /// empty/false so every existing call site (voice mode included) is
    /// unaffected unless it opts in explicitly — only `ChatView`'s main
    /// chat flow (general + book-scoped threads) does today. Deliberately
    /// never threaded into the `symposiumModeEnabled` branch below, which
    /// stays on `SearchService.buildContext` — out of scope per this
    /// feature's own design (Symposium/Decision Consultation/Ask Intent all
    /// keep using the older, uncached, one-shot path unchanged).
    static func assemble(
        userMessage: String,
        books: [Book],
        selectedBookID: UUID?,
        symposiumModeEnabled: Bool,
        isVoice: Bool = false,
        personalWritingEntries: [PersonalWritingEntry] = [],
        personalWritingContextEnabled: Bool = false,
        useRealNamesInLifeExamples: Bool = false,
        /// The ongoing situation this thread is about, when it is one.
        situation: SituationThread? = nil,
        /// Cross-conversation memory. Defaults to disabled, so the voice,
        /// symposium, decision-consultation and Ask-Intent paths are untouched
        /// unless they opt in explicitly -- the same scoping contract
        /// `personalWritingEntries` documents above.
        crossChat: SearchService.CrossChatInput = .init()
    ) -> Assembled {
        // Checked before symposium on purpose: symposium is "a debate among
        // the authors in the library," which has no coherent meaning inside
        // the journal thread, so the journal always wins while it's the
        // selected thread. The privacy toggles are NOT consulted here -- they
        // gate journal excerpts leaking into book answers as asides, whereas
        // this branch runs only for the thread whose whole purpose is the
        // journal, gated behind the journal's own Face ID lock in `ChatView`.
        if selectedBookID == journalThreadID {
            var systemPrompt = String(
                format: PromptTemplates.journalGrounded,
                SearchService.buildJournalContext(query: userMessage, entries: personalWritingEntries)
            )
            if isVoice { systemPrompt += spokenStyleCore }
            return .journal(systemPrompt: systemPrompt)
        }

        // Situations take precedence over symposium, for the same reason the
        // journal thread does: "a debate among the authors" is not what a
        // thread about one ongoing situation is for, and silently dropping the
        // situation block would make the thread quietly forget its own subject.
        if symposiumModeEnabled, situation == nil {
            let (contextString, titles) = SearchService.buildContext(query: userMessage, books: books)
            var systemPrompt = String(format: PromptTemplates.symposium, contextString)
            if isVoice { systemPrompt += spokenStyleCore + spokenStyleSourcesReminder }
            return .symposium(systemPrompt: systemPrompt, referencedTitles: titles)
        }

        if let scopedBook = selectedBookID.flatMap({ id in books.first(where: { $0.id == id }) }) {
            let (stableContext, dynamicContext) = SearchService.buildSplitContextForBook(
                query: userMessage,
                book: scopedBook,
                libraryBooks: books,
                personalWritingEntries: personalWritingEntries,
                includePersonalWriting: personalWritingContextEnabled,
                useRealNamesInLifeExamples: useRealNamesInLifeExamples,
                crossChat: crossChat
            )
            let stableSystemPrompt = String(format: PromptTemplates.bookScoped, scopedBook.title, scopedBook.author, scopedBook.title, stableContext)
            let finalDynamicContext = isVoice ? dynamicContext + spokenStyleCore + spokenStyleSourcesReminder : dynamicContext
            return .bookScoped(stableSystemPrompt: stableSystemPrompt, dynamicContext: finalDynamicContext)
        }

        let (stableContext, dynamicContext, titles) = SearchService.buildSplitContext(
            query: userMessage,
            books: books,
            personalWritingEntries: personalWritingEntries,
            includePersonalWriting: personalWritingContextEnabled,
            useRealNamesInLifeExamples: useRealNamesInLifeExamples,
            crossChat: crossChat
        )
        let stableSystemPrompt = String(format: PromptTemplates.base, stableContext)
        // A situation thread routes through the GENERAL path unchanged, and
        // that is deliberate: same stable prefix, byte for byte, so it shares
        // the general thread's Anthropic cache entry outright rather than
        // paying for a second one. Everything it adds rides the dynamic suffix.
        let withAmbient = dynamicContext + situationLine(situation) + ambientLine()
        let finalDynamicContext = isVoice ? withAmbient + spokenStyleCore + spokenStyleSourcesReminder : withAmbient
        return .general(stableSystemPrompt: stableSystemPrompt, dynamicContext: finalDynamicContext, referencedTitles: titles)
    }

    /// The one block a situation thread adds.
    ///
    /// It tells the model the thread's own transcript IS the memory, rather
    /// than handing it a summary the user never saw. That is the whole privacy
    /// posture in one instruction: nothing about the other person is stored or
    /// inferred, so nothing about them can be leaked back except what he
    /// himself wrote, in front of him, in a thread he can delete.
    private static func situationLine(_ situation: SituationThread?) -> String {
        guard let situation, !situation.name.isEmpty else { return "" }
        var block = "\n\n## Ongoing situation: \"\(situation.name)\"\n"
            + "This thread is about one ongoing situation in the user's life. The earlier turns "
            + "of this conversation are your memory of it -- rely on them, and keep track of where "
            + "things stand. Do not infer or assert anything about the other person beyond what the "
            + "user has actually told you here."
        if let note = situation.note?.trimmingCharacters(in: .whitespacesAndNewlines),
           !note.isEmpty {
            block += "\nPinned note from the user: \(note)"
        }
        return block
    }

    /// One line of live situational context, appended to the DYNAMIC suffix.
    ///
    /// The dynamic/stable split exists so per-turn material never busts the
    /// Anthropic prompt cache, which is exactly why this rides here: it changes
    /// between turns and costs nothing.
    ///
    /// The point is not a weather report. Chat's biggest real use is working
    /// through something with another person, and today Cobux answers
    /// identically on 4.9 hours of sleep and 8.7. A reply that quietly accounts
    /// for a short night in a conversation about a conflict is the thing nobody
    /// would think to ask for and everybody would feel.
    ///
    /// Sent LIVE and ephemeral -- never written into an entry, never persisted,
    /// never in a backup. `HealthContextService`'s own ruling is that health
    /// data is never uploaded and never exported; this respects that by sending
    /// a sentence about right now rather than storing a record. Gated behind the
    /// health toggle that already exists, so it adds no new setting.
    private static func ambientLine() -> String {
        var parts: [String] = []
        if HealthContextService.isEnabled, let line = HealthContextService.lastKnownSummary {
            parts.append(line)
        }
        if let ambient = AmbientContext.cached() {
            if let temperature = ambient.temperatureF { parts.append("\(temperature)°F outside") }
            if let condition = ambient.condition { parts.append(condition.lowercased()) }
        }
        guard !parts.isEmpty else { return "" }
        return "\n\nContext about the user right now, if any of it is relevant to what they "
            + "asked -- mention it only if it genuinely bears on your answer, never as small "
            + "talk: " + parts.joined(separator: "; ") + "."
    }

    /// Which of a reply's declared source titles are worth showing as chips.
    ///
    /// Lives here, next to `assemble`, for the same reason `assemble` does:
    /// text chat and voice both finish a turn by resolving citations, and a
    /// rule implemented separately in each is a rule that drifts. Both channels
    /// call this instead of filtering their own copy.
    ///
    /// The rule: in a book-scoped thread, drop the thread's OWN book. Now that
    /// such a thread can genuinely draw on a second book, its replies do
    /// declare sources — but tagging every reply in the "Beyond Order" thread
    /// with a "Beyond Order" chip tells the user something they already chose.
    /// A chip survives here only when the reply actually reached past the book
    /// the thread is about, which is the case worth surfacing. The general
    /// thread is unaffected.
    static func displayableCitations(
        resolvedTitles: [String],
        selectedBookID: UUID?,
        books: [Book]
    ) -> [String] {
        guard let selectedBookID,
              let focusBook = books.first(where: { $0.id == selectedBookID }) else {
            return resolvedTitles
        }
        return resolvedTitles.filter { $0 != focusBook.title }
    }
}
