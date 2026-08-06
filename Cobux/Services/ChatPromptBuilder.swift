import Foundation

/// The scoped→bookScoped / general→base branch `ChatView.sendMessage` used to own directly —
/// extracted so voice mode (`VoiceSessionController`) assembles turns through the exact same
/// logic instead of a parallel reimplementation that could silently drift from what text chat
/// does. A behavior-neutral refactor: `ChatView` switched onto this produces byte-identical
/// prompts to before.
enum ChatPromptBuilder {

    enum Assembled {
        /// Symposium mode always uses the full, unsplit library context regardless of any
        /// selected book — "a debate among authors" scoped to one book is degenerate.
        case symposium(systemPrompt: String, referencedTitles: [String])
        /// A book-scoped thread never needs citation chips — every reply is about this one
        /// book by construction — so there are no `referencedTitles` to carry.
        case bookScoped(stableSystemPrompt: String, dynamicContext: String)
        case general(stableSystemPrompt: String, dynamicContext: String, referencedTitles: [String])
    }

    /// Spoken-style instructions for a voice turn go in the dynamic (uncached) suffix, never
    /// the stable prefix — per Fable's voice architecture ruling, the cached prefix must stay
    /// byte-identical between text and voice so both channels share one Anthropic prompt-cache
    /// entry. `.general`/`.symposium` already have `PromptTemplates.sourcesInstruction` baked
    /// into their (stable) template, so their spoken variant reminds the model to still emit
    /// it; `.bookScoped` never asks for a `<sources>` tag at all, so its spoken variant omits
    /// that reminder rather than reference an instruction that was never given.
    private static let spokenStyleCore = "\n\nThis reply will be read aloud by text-to-speech, not displayed as text. Answer in 2-4 short, plain sentences — no markdown, no bullet points, no headers. Spell out numbers as words."
    private static let spokenStyleSourcesReminder = " Still end with the <sources> line exactly as instructed above."

    static func assemble(userMessage: String, books: [Book], selectedBookID: UUID?, symposiumModeEnabled: Bool, isVoice: Bool = false) -> Assembled {
        if symposiumModeEnabled {
            let (contextString, titles) = SearchService.buildContext(query: userMessage, books: books)
            var systemPrompt = String(format: PromptTemplates.symposium, contextString)
            if isVoice { systemPrompt += spokenStyleCore + spokenStyleSourcesReminder }
            return .symposium(systemPrompt: systemPrompt, referencedTitles: titles)
        }

        if let scopedBook = selectedBookID.flatMap({ id in books.first(where: { $0.id == id }) }) {
            let (stableContext, dynamicContext) = SearchService.buildSplitContextForBook(query: userMessage, book: scopedBook)
            let stableSystemPrompt = String(format: PromptTemplates.bookScoped, scopedBook.title, scopedBook.author, scopedBook.title, stableContext)
            let finalDynamicContext = isVoice ? dynamicContext + spokenStyleCore : dynamicContext
            return .bookScoped(stableSystemPrompt: stableSystemPrompt, dynamicContext: finalDynamicContext)
        }

        let (stableContext, dynamicContext, titles) = SearchService.buildSplitContext(query: userMessage, books: books)
        let stableSystemPrompt = String(format: PromptTemplates.base, stableContext)
        let finalDynamicContext = isVoice ? dynamicContext + spokenStyleCore + spokenStyleSourcesReminder : dynamicContext
        return .general(stableSystemPrompt: stableSystemPrompt, dynamicContext: finalDynamicContext, referencedTitles: titles)
    }
}
