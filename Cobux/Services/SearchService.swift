import Foundation
import SwiftData
import CobuxCore
#if canImport(UIKit)
import UIKit
#endif

struct SearchService {
    /// Whether a book is small enough to inject in full (`propositional`,
    /// `doctrine`, `narrative`, `densePhilosophy` profiles) or must be
    /// retrieval-gated to its highest-relevance highlights for THIS question
    /// (`academicReference` — full-dumping a medical textbook's hundreds of
    /// highlights every message would blow up prompt size/cost/latency and
    /// bury the answer in noise). Replaced a highlight-count proxy that
    /// broke once every book, not just the two medical textbooks, grew past
    /// 60 highlights under deeper authoring — see `BookContentProfile`.
    static func requiresRetrievalGating(_ book: Book) -> Bool {
        book.contentProfile.requiresRetrievalGating
    }

    /// How many individual highlights, ranked across all "large" books
    /// combined, get injected per chat turn. Tuned for citation quality
    /// against context size/latency/cost — raise if answers feel starved of
    /// detail, lower if replies feel unfocused.
    static let chunkTopK = 24

    /// Tokens too short or too common to be evidence that a query is talking
    /// about a particular book. Middle initials ("B."), honorifics, and
    /// articles all land here — they're exactly the parts of a stored
    /// title/author string that a person never types.
    private static let matchStopwords: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "you", "your",
        "his", "her", "its", "was", "are", "how", "what", "why", "who", "does",
        "did", "can", "would", "should", "could", "about", "into", "out",
        "dr", "mr", "mrs", "ms", "jr", "sr", "phd", "md", "book", "books", "say", "says"
    ]

    /// Lowercased, punctuation-stripped, stopword-filtered word set. Tokens
    /// under 3 characters are dropped, which is what makes a stored middle
    /// initial ("Jordan B. Peterson" → {jordan, peterson}) stop being a
    /// requirement the user has to type.
    static func significantTokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 && !matchStopwords.contains($0) }
        )
    }

    /// Whether `queryTokens` names `candidate` (a book title or author).
    ///
    /// Replaces `queryLower.contains(candidate.lowercased())`, a literal
    /// substring test that silently failed for any stored name carrying a
    /// middle initial, suffix, or punctuation the user doesn't type. Both
    /// seeded Jordan Peterson books store `"Jordan B. Peterson"`, so the
    /// natural phrasing "what would Jordan Peterson say" did NOT contain
    /// `"jordan b. peterson"` and matched nothing — the confirmed cause of
    /// chat claiming it only had chapter titles for those books. Matching on
    /// significant tokens instead is resilient to capitalization, punctuation,
    /// possessives ("Peterson's" → {peterson}), and word order.
    ///
    /// Every significant token must be present, so "Jordan Peterson" doesn't
    /// pull in an unrelated book by a different Jordan. A candidate with no
    /// significant tokens at all (a two-letter title like "It") returns false
    /// rather than matching everything — the old substring test would have
    /// matched nearly every query for such a title.
    static func queryMentions(_ candidate: String, queryTokens: Set<String>) -> Bool {
        let tokens = significantTokens(candidate)
        guard !tokens.isEmpty else { return false }
        return tokens.isSubset(of: queryTokens)
    }

    /// Whether a highlight carries direct textual evidence for this query.
    ///
    /// Same class of fix as `queryMentions`: the old test asked whether a
    /// highlight contained the ENTIRE query as a substring, which a
    /// natural-language question essentially never satisfies — so the
    /// "safety net" that was supposed to catch books with missing embeddings
    /// almost never fired. Now a highlight qualifies when it shares a
    /// reasonably distinctive word (4+ characters) with the query.
    static func highlightMatches(_ highlight: Highlight, queryTokens: Set<String>) -> Bool {
        let distinctive = queryTokens.filter { $0.count >= 4 }
        guard !distinctive.isEmpty else { return false }
        let haystack = significantTokens(highlight.text).union(
            highlight.tags.flatMap { significantTokens($0) }
        )
        return !haystack.isDisjoint(with: distinctive)
    }

    /// Builds the library context for the system prompt and reports which
    /// books were included, so replies can cite their sources.
    static func buildContext(query: String, books: [Book]) -> (context: String, bookTitles: [String]) {
        guard !books.isEmpty else {
            return ("No books in library yet.", [])
        }

        // Retrieval-only expansion. Never shown to the model or the user --
        // it exists so "left me on read" can find prose written in 1748.
        let retrievalQuery = expandedRetrievalQuery(query)
        let queryTokens = significantTokens(retrievalQuery)

        let matchedBooks = books.filter { book in
            queryMentions(book.title, queryTokens: queryTokens) ||
            queryMentions(book.author, queryTokens: queryTokens)
        }

        // Fold in books surfaced purely by semantic content match (not just
        // literal title/author mentions), so a question can find relevant
        // highlights even when it doesn't quote the book by name.
        let semanticHits = semanticSearch(query: query, books: books, topK: 12)
        let semanticBooks = semanticHits.compactMap(\.book)
        var unionBooks = matchedBooks
        for book in semanticBooks where !unionBooks.contains(where: { $0.id == book.id }) {
            unionBooks.append(book)
        }

        // `semanticSearch`'s ranked path only considers highlights that already
        // have an embedding (see its doc comment) — a book whose highlights
        // haven't been embedded yet would otherwise never surface here even
        // though it's fully present in the library. Whenever the ranked path
        // didn't cover every book in the library, also run the keyword fallback
        // so no book gets silently demoted to the bare "Other books" listing
        // just because it lacks embeddings. IMPORTANT: this now runs for ALL
        // books, not just small ones — a large reference book with no fallback
        // at all would go completely invisible to chat the moment semantic
        // matching fails for it (missing embeddings during the background
        // backfill window, or the on-device model simply not scoring dense
        // clinical terminology well against a plain-English question — a real,
        // confirmed bug: the two medical textbooks disappeared from chat
        // entirely while the small self-help books, which had this fallback,
        // kept working). A keyword hit here only earns a large book a seat in
        // `relevantBooks` — it still goes through the SAME ranked top-K
        // chunking below, never a full dump, so the original "don't let a
        // bare substring hit on a common word like 'necrosis' pull in an
        // entire textbook" concern still holds.
        if Set(semanticBooks.map(\.id)).count < books.count {
            for book in books where !unionBooks.contains(where: { $0.id == book.id }) {
                let hasKeywordHit = book.highlights.contains { highlight in
                    highlightMatches(highlight, queryTokens: queryTokens)
                }
                if hasKeywordHit {
                    unionBooks.append(book)
                }
            }
        }

        let relevantBooks = unionBooks.isEmpty ? books : unionBooks

        // For large reference books among the relevant set, rank their
        // highlights against THIS question and keep only the top-K — small
        // books are unaffected and keep shipping in full, exactly as before.
        let largeRelevantBooks = relevantBooks.filter { requiresRetrievalGating($0) }
        var chunkedHighlightIDs: Set<UUID> = []
        if !largeRelevantBooks.isEmpty {
            let rankedChunks = semanticSearch(query: retrievalQuery, books: largeRelevantBooks, topK: chunkTopK)
            chunkedHighlightIDs = Set(rankedChunks.map(\.id))

            // Safety net: a large book can land in `largeRelevantBooks` (via
            // the keyword fallback just above) yet still contribute ZERO
            // highlights here if semantic ranking comes up empty for it too
            // (same root cause — missing embeddings or a threshold mismatch)
            // — without this, the book would show as "relevant" with nothing
            // to show, which is just as broken as being invisible outright.
            // Fall back to its own keyword-matched highlights, capped at the
            // same top-K budget so this never balloons into a full dump.
            for book in largeRelevantBooks {
                let hasChunk = book.highlights.contains { chunkedHighlightIDs.contains($0.id) }
                guard !hasChunk else { continue }
                let keywordMatches = book.highlights.filter { highlight in
                    highlightMatches(highlight, queryTokens: queryTokens)
                }
                for highlight in keywordMatches.prefix(chunkTopK) {
                    chunkedHighlightIDs.insert(highlight.id)
                }
            }
        }

        var context = "## User's Book Library Context\n\n"
        var referencedBookIDs = Set<UUID>()

        for book in relevantBooks {
            let isLargeBook = requiresRetrievalGating(book)
            let highlightsToShow = isLargeBook
                ? book.highlights.filter { chunkedHighlightIDs.contains($0.id) }
                : book.highlights

            context += "## Book: \"\(book.title)\" by \(book.author)\(traditionSuffix(for: book))\n\n"

            if !highlightsToShow.isEmpty {
                context += "### Highlights:\n"
                for highlight in highlightsToShow {
                    var locationParts: [String] = []
                    if let chapter = highlight.chapter {
                        locationParts.append("Chapter: \(chapter)")
                    }
                    if let page = highlight.page {
                        locationParts.append("Page: \(page)")
                    }
                    let locationString = locationParts.isEmpty ? "" : " (\(locationParts.joined(separator: ", ")))"

                    context += "- \"\(highlight.text)\"\(locationString)\n"

                    if let note = highlight.personalNote, !note.isEmpty {
                        context += "  Personal note: \(note)\n"
                    }

                    if !highlight.tags.isEmpty {
                        context += "  Tags: \(highlight.tags.joined(separator: ", "))\n"
                    }
                }
                context += "\n"

                // A large book is only cited when it actually contributed a
                // ranked highlight to this turn. Small books keep the old
                // "cited whenever present" behavior below.
                if isLargeBook {
                    referencedBookIDs.insert(book.id)
                }
            }

            if !book.chapters.isEmpty {
                context += "### Chapter Summaries:\n"
                let sortedChapters = book.chapters.sorted { ($0.chapterNumber ?? 0) < ($1.chapterNumber ?? 0) }
                for chapter in sortedChapters {
                    var chapterLine = "- \(chapter.title): \(chapter.summary)"
                    if !chapter.keyLessons.isEmpty {
                        chapterLine += " | Key lessons: \(chapter.keyLessons.joined(separator: ", "))"
                    }
                    context += chapterLine + "\n"
                }
                context += "\n"
            }

            if highlightsToShow.isEmpty && book.chapters.isEmpty {
                context += "(No highlights or chapter summaries added yet)\n\n"
            }

            if !isLargeBook {
                referencedBookIDs.insert(book.id)
            }
        }

        if !relevantBooks.isEmpty && relevantBooks.count < books.count {
            let otherBooks = books.filter { book in
                !relevantBooks.contains(where: { $0.id == book.id })
            }
            if !otherBooks.isEmpty {
                context += "### Other books in library:\n"
                for book in otherBooks {
                    context += "- \"\(book.title)\" by \(book.author)\(traditionSuffix(for: book)) (\(book.highlightCount) highlights, \(book.chapterCount) chapters)\n"
                }
                context += "\n"
            }
        }

        // Report only genuinely-referenced books for citation purposes —
        // falling back to the full library for `relevantBooks` gives the model
        // context to work with on a vague query like "hi", but citing a book as
        // "referenced" when nothing it contributed actually made this turn's
        // context would be misleading in the UI. `unionBooks` (not
        // `relevantBooks`) also means citations stay empty for a vague query
        // that fell back to the whole library, same as before.
        let citedTitles = unionBooks.filter { referencedBookIDs.contains($0.id) }.map(\.title)

        // `dynamicContextCharBudget` (declared just below) was introduced
        // specifically because the `relevantBooks = books` fallback above can
        // full-dump every small book's highlights on a vague/unmatched query --
        // but it was only ever wired into `buildSplitContext`/
        // `buildSplitContextForBook`. This function feeds three real,
        // uncapped call sites (Symposium mode, Decision Consultation,
        // `AskCobuxIntent`/Siri), where the SAME fallback was measured at up
        // to ~850k characters on a real library -- a single Siri "Ask Cobux"
        // on a vague question could cost $1.70-2.50 in one call at Sonnet
        // rates, with no ceiling at all. Same truncation pattern already used
        // in `buildSplitContextForBook` below.
        let truncatedContext = context.count > dynamicContextCharBudget
            ? String(context.prefix(dynamicContextCharBudget)) + "\n\n(Additional library content omitted — ask about a specific book for more detail.)"
            : context

        return (truncatedContext, citedTitles)
    }

    /// Hard ceiling, in characters, on the DYNAMIC (uncached) section of a
    /// chat turn's context. Exists specifically because the empty-`unionBooks`
    /// fallback below (a vague or unmatched first message — common before
    /// background embedding backfill finishes) used to dump every book's full
    /// highlight set into this uncached section unconditionally. On a
    /// 17-book library that was measured at up to ~850k characters on a
    /// single turn — an uncached block that large must finish prefilling
    /// before Anthropic streams back a single token, which routinely blew
    /// past `URLSession`'s default 60s idle timeout and looked, from the
    /// user's side, like "the first message just times out." ~150k chars is
    /// comfortably inside the model's context window even stacked on top of
    /// the (now title-only) cached prefix, while still leaving real headroom
    /// for a genuinely broad query.
    static let dynamicContextCharBudget = 150_000

    /// Per-book cap on how many of a SMALL (non-retrieval-gated) book's
    /// highlights get full-dumped into the dynamic section when it's
    /// relevant. Large books are already capped by `chunkTopK`; small books
    /// previously had no cap at all, so a single heavily-highlighted small
    /// book could still eat a large slice of `dynamicContextCharBudget` on
    /// its own.

    /// The shelf label, as a suffix on a book's header line in chat context.
    ///
    /// `BookTradition` was built so the library does not speak in one voice --
    /// Quiz enforces it via `requiresAttributedQuizStems` -- but chat never
    /// read it, so a Greene manoeuvre and an attachment-therapy chapter reached
    /// the model as equal-authority material. `PromptTemplates.traditionRegister`
    /// tells the model what to do with these labels; this is what puts them
    /// where it can see them.
    ///
    /// Empty for an untagged book rather than guessing a shelf: an unset
    /// tradition means unknown, and inventing one would be worse than silence.
    /// Byte-stable across turns (tradition changes only on a user edit, the
    /// same invalidation class as adding a book), so this is safe in the
    /// cached stable prefix.

    /// The 40 highlights most relevant to this question, not the first 40 on
    /// the shelf.
    ///
    /// Only books over the retrieval-gating threshold got query-ranked chunks;
    /// every other book contributed `highlights.prefix(40)` -- an UNRANKED
    /// slice in whatever order the relationship happened to return. That is
    /// worst exactly where it hurts most: The Art of Seduction (496
    /// highlights), the Kural (532) and The 48 Laws (431) are the books this
    /// class of question leans on hardest, and roughly nine in ten of their
    /// highlights could never reach the prompt no matter what was asked.
    ///
    /// Ranking the slice costs nothing extra -- `semanticSearch` is the same
    /// on-device embedding path already used for gated books -- and it
    /// improves every question in the app, not just interpersonal ones.
    /// Falls back to the old prefix behaviour when ranking yields nothing
    /// (no embeddings yet on a fresh install, or an empty query), so this can
    /// never return less than before.
    static func topHighlights(of book: Book, for query: String) -> [Highlight] {
        let cap = maxHighlightsPerBookInDynamicContext
        guard book.highlights.count > cap else { return book.highlights }
        let ranked = semanticSearch(query: query, books: [book], topK: cap)
        guard !ranked.isEmpty else { return Array(book.highlights.prefix(cap)) }
        guard ranked.count < cap else { return ranked }
        // Top up from the shelf so a thin ranking never shrinks the context.
        let have = Set(ranked.map(\.id))
        return ranked + book.highlights.filter { !have.contains($0.id) }
                                       .prefix(cap - ranked.count)
    }

    /// Query-side only: bridges how people actually type to how the library
    /// actually writes.
    ///
    /// The library's diction is 19th-century prose, Tamil verse and clinical
    /// attachment language. "left me on read" embeds against none of it, so
    /// the cosine scores are close to noise and the relevant-book union
    /// collapses to the whole-library fallback -- the answer then rides on
    /// chapter summaries instead of the sharpest passages.
    ///
    /// Expanded text is used for EMBEDDING AND KEYWORD MATCHING ONLY. It is
    /// never shown to the model and never shown to the user, so a wrong
    /// expansion can only cost retrieval precision, never put words in
    /// someone's mouth. Deterministic and testable, unlike an LLM rewrite,
    /// and it adds no request.
    static let vernacularAnchors: [String: String] = [
        "left me on read": "ignored message no reply waiting anxiety",
        "left on read": "ignored message no reply waiting anxiety",
        "rizz": "charm attraction flirting confidence courtship",
        "ghosted": "sudden silence withdrawal absence abandonment",
        "ghosting": "sudden silence withdrawal absence abandonment",
        "double text": "pursue again eagerness restraint patience",
        "dry texting": "indifference short replies waning interest",
        "situationship": "undefined relationship commitment ambiguity",
        "talking stage": "early courtship uncertainty interest",
        "mixed signals": "ambiguity inconsistency reading intentions",
        "breadcrumbing": "intermittent attention hope withholding",
        "love bombing": "excessive flattery rapid intensity manipulation",
        "clingy": "neediness anxious attachment over-pursuit",
        "needy": "neediness anxious attachment over-pursuit",
        "avoidant": "distance withdrawal intimacy fear independence",
        "toxic": "harmful pattern resentment contempt",
        "no contact": "silence absence distance self-command",
        "hard launch": "public commitment declaration",
        "situation": "circumstance predicament judgment",
        "vibe": "impression presence bearing",
        "simp": "over-pursuit deference loss of self-respect",
        "closure": "ending acceptance grief letting go",
    ]

    /// The question, plus anchors for any vernacular it contains.
    static func expandedRetrievalQuery(_ query: String) -> String {
        let lowered = query.lowercased()
        let hits = vernacularAnchors
            .filter { lowered.contains($0.key) }
            .map(\.value)
        guard !hits.isEmpty else { return query }
        return query + " " + hits.sorted().joined(separator: " ")
    }

    static func traditionSuffix(for book: Book) -> String {
        guard let tradition = book.tradition else { return "" }
        return " — Tradition: \(tradition.label)"
    }

    static let maxHighlightsPerBookInDynamicContext = 40

    /// Same retrieval as `buildContext`, but splits the result into a STABLE
    /// prefix and a DYNAMIC suffix instead of one combined string, so the
    /// caller can mark the stable piece as an Anthropic prompt-cache
    /// breakpoint (`cache_control`) and avoid re-billing it on every message.
    ///
    /// The stable piece is a TITLES-ONLY chapter index for every book,
    /// unconditionally — NOT the chapter summaries/key lessons themselves.
    /// Full summaries used to live here, on the theory that a byte-identical
    /// block is exactly what a cache breakpoint needs — true, but it also
    /// meant this "stable" block grew unboundedly as books were added (up to
    /// ~1M characters across 17 books), and a giant cache-cold prefill has
    /// the exact same first-token-latency problem as a giant uncached one,
    /// just on the FIRST turn of a session (or any turn after the ~5-minute
    /// cache TTL lapses) instead of every turn. A titles-only index is small
    /// regardless of library size (a chapter title is a name, not content),
    /// so cache-cold prefill time stays bounded no matter how many books get
    /// added later. Chapter summaries/key lessons moved into the dynamic
    /// section below, gated by the same per-query relevance as everything
    /// else there.
    ///
    /// Book order is deterministic (sorted by `id`) so `ChatView` and
    /// `VoiceSessionController` can never independently produce
    /// differently-ordered stable prefixes for the same library — a
    /// byte-difference there would silently split the cache in two.
    ///
    /// The dynamic piece keeps the EXISTING per-query behavior — relevant
    /// small books' highlight dumps (now capped per book, see
    /// `maxHighlightsPerBookInDynamicContext`), large reference books' top-K
    /// ranked highlight chunks, and now each relevant book's chapter
    /// summaries too — but the WHOLE section is now bounded by
    /// `dynamicContextCharBudget`, with content added in priority order
    /// (ranked/capped highlights, then chapter summaries, book by book in
    /// deterministic order) and a clean note appended if the budget is hit,
    /// rather than an unbounded dump. Citation logic (`bookTitles`) is
    /// unchanged from `buildContext`: small books cited whenever relevant,
    /// large books cited only when a ranked highlight from them actually
    /// made it into this turn's dynamic context — and now, specifically,
    /// only when its content actually fit inside the budget too, preserving
    /// the "never cite something that isn't actually in the prompt"
    /// invariant.
    ///
    /// Only used by the main chat flow (`ChatView`) and `VoiceSessionController`
    /// — the highest-volume, most cache-sensitive paths ("repeated questions
    /// in one study session"). Other one-shot templates (Symposium, Decision
    /// Consultation, Ask Intent) keep using `buildContext` above unchanged.
    /// Everything the cross-chat block needs, bundled so the two context
    /// builders take one defaulted parameter rather than six -- and so a caller
    /// that has not opted in cannot half-configure it.
    struct CrossChatInput {
        /// The memory block, ALREADY BUILT by `CrossChatMemory.contextBlock`
        /// off the main thread from value snapshots. The builders here only
        /// place it and charge it against the budget.
        ///
        /// This used to carry live `ChatMessage` models and rank them inside
        /// the builder -- which meant cosine similarity over up to two
        /// thousand vectors ran on the main actor, on the send tap, inside
        /// the documented crash-class boundary. Handing in a finished string
        /// moves the whole privacy core (pool gates + ranking + attribution)
        /// into pure `Sendable` land where it runs anywhere and tests as
        /// plain values.
        var prebuiltBlock: String = ""
        var enabled: Bool = false
    }

    static func buildSplitContext(
        query: String,
        books: [Book],
        personalWritingEntries: [PersonalWritingEntry] = [],
        includePersonalWriting: Bool = false,
        useRealNamesInLifeExamples: Bool = false,
        crossChat: CrossChatInput = .init()
    ) -> (stableContext: String, dynamicContext: String, bookTitles: [String]) {
        guard !books.isEmpty else {
            return ("No books in library yet.", "", [])
        }

        let sortedBooks = books.sorted { $0.id.uuidString < $1.id.uuidString }

        var stable = "## User's Book Library — Chapter Index\n\n"
        for book in sortedBooks where !book.chapters.isEmpty {
            stable += "### \"\(book.title)\" by \(book.author)\(traditionSuffix(for: book)) — Chapters:\n"
            let sortedChapters = book.chapters.sorted { ($0.chapterNumber ?? 0) < ($1.chapterNumber ?? 0) }
            for chapter in sortedChapters {
                stable += "- \(chapter.title)\n"
            }
            stable += "\n"
        }

        // Retrieval-only expansion. Never shown to the model or the user --
        // it exists so "left me on read" can find prose written in 1748.
        let retrievalQuery = expandedRetrievalQuery(query)
        let queryTokens = significantTokens(retrievalQuery)

        let matchedBooks = sortedBooks.filter { book in
            queryMentions(book.title, queryTokens: queryTokens) ||
            queryMentions(book.author, queryTokens: queryTokens)
        }

        let semanticHits = semanticSearch(query: retrievalQuery, books: sortedBooks, topK: 12)
        let semanticBooks = semanticHits.compactMap(\.book)
        var unionBooks = matchedBooks
        for book in semanticBooks where !unionBooks.contains(where: { $0.id == book.id }) {
            unionBooks.append(book)
        }

        // See `buildContext`'s matching block for why this runs for ALL
        // books, not just small ones — a large book with no fallback at all
        // was going completely invisible to chat whenever semantic matching
        // failed for it (missing embeddings, or clinical terminology not
        // scoring well against the on-device model).
        if Set(semanticBooks.map(\.id)).count < sortedBooks.count {
            for book in sortedBooks where !unionBooks.contains(where: { $0.id == book.id }) {
                let hasKeywordHit = book.highlights.contains { highlight in
                    highlightMatches(highlight, queryTokens: queryTokens)
                }
                if hasKeywordHit {
                    unionBooks.append(book)
                }
            }
        }

        // When nothing matched (vague/unmatched query, or embeddings still
        // backfilling), fall back to the whole library so the model has SOME
        // context — `dynamicContextCharBudget` below, not this fallback
        // itself, is what now keeps that safe; it used to mean an unbounded
        // full-highlight dump across every book on exactly this path.
        //
        // `unionBooks`' own insertion order IS a relevance ranking — books the
        // query named outright, then semantic hits, then keyword-fallback
        // hits — and it is deliberately preserved here. Re-sorting this by
        // `id` (what this line used to do) threw that ranking away and left
        // the per-book budget loop below consuming books in arbitrary UUID
        // order, so on a broad query the book the user actually *named* could
        // be the one truncated out while an incidental keyword match got the
        // budget. Ordering here is a priority decision, not a caching one:
        // this is the DYNAMIC section, downstream of the cache breakpoint, so
        // unlike `stable` above it never has to be byte-stable across turns.
        // The whole-library fallback keeps its deterministic `id` order.
        let relevantBooks = unionBooks.isEmpty ? sortedBooks : unionBooks

        let largeRelevantBooks = relevantBooks.filter { requiresRetrievalGating($0) }
        var chunkedHighlightIDs: Set<UUID> = []
        if !largeRelevantBooks.isEmpty {
            let rankedChunks = semanticSearch(query: retrievalQuery, books: largeRelevantBooks, topK: chunkTopK)
            chunkedHighlightIDs = Set(rankedChunks.map(\.id))

            // Same keyword safety net as `buildContext`: a large book landing
            // in `largeRelevantBooks` but contributing zero ranked highlights
            // is just as broken as being invisible outright.
            for book in largeRelevantBooks {
                let hasChunk = book.highlights.contains { chunkedHighlightIDs.contains($0.id) }
                guard !hasChunk else { continue }
                let keywordMatches = book.highlights.filter { highlight in
                    highlightMatches(highlight, queryTokens: queryTokens)
                }
                for highlight in keywordMatches.prefix(chunkTopK) {
                    chunkedHighlightIDs.insert(highlight.id)
                }
            }
        }

        var dynamic = "## Most Relevant Content for This Question\n\n"
        var referencedBookIDs = Set<UUID>()
        var budgetExhausted = false

        // Rajan's own personal writing — an additional, separately-capped,
        // retrieval-gated pool (see `personalWritingContextBlock`), added
        // FIRST so it survives on a turn where the library itself is large
        // enough to exhaust the budget on its own. Never computed at all
        // when `includePersonalWriting` is false (the caller's privacy
        // toggle) — no query embedding, no ranking, nothing added to the
        // prompt. Uses the exact same budget guard shape as the per-book
        // loop below: an oversized block sets `budgetExhausted` and appends
        // the same omission notice instead of exceeding the cap.
        if includePersonalWriting && !personalWritingEntries.isEmpty {
            let personalBlock = personalWritingContextBlock(query: query, entries: personalWritingEntries, useRealNames: useRealNamesInLifeExamples)
            if !personalBlock.isEmpty {
                if dynamic.count + personalBlock.count > dynamicContextCharBudget {
                    budgetExhausted = true
                    dynamic += "(Additional library content omitted to stay within this turn's context budget.)\n\n"
                } else {
                    dynamic += personalBlock
                }
            }
        }

        // Cross-conversation memory rides here, right after his journal and
        // before the books. That order IS the cut order when the budget is
        // tight: his own words survive longest, because book content is
        // re-derivable from the stable chapter index above and his is not.
        if crossChat.enabled && !crossChat.prebuiltBlock.isEmpty && !budgetExhausted {
            let memoryBlock = crossChat.prebuiltBlock
            if !memoryBlock.isEmpty {
                if dynamic.count + memoryBlock.count > dynamicContextCharBudget {
                    budgetExhausted = true
                    dynamic += "(Additional library content omitted to stay within this turn's context budget.)\n\n"
                } else {
                    dynamic += memoryBlock
                }
            }
        }

        for book in relevantBooks {
            guard !budgetExhausted else { break }

            let isLargeBook = requiresRetrievalGating(book)
            let highlightsToShow: [Highlight] = isLargeBook
                ? book.highlights.filter { chunkedHighlightIDs.contains($0.id) }
                : topHighlights(of: book, for: retrievalQuery)

            var bookBlock = ""
            var contributedHighlights = false

            if !highlightsToShow.isEmpty {
                bookBlock += "## Book: \"\(book.title)\" by \(book.author)\(traditionSuffix(for: book))\n\n### Highlights:\n"
                for highlight in highlightsToShow {
                    var locationParts: [String] = []
                    if let chapter = highlight.chapter {
                        locationParts.append("Chapter: \(chapter)")
                    }
                    if let page = highlight.page {
                        locationParts.append("Page: \(page)")
                    }
                    let locationString = locationParts.isEmpty ? "" : " (\(locationParts.joined(separator: ", ")))"

                    bookBlock += "- \"\(highlight.text)\"\(locationString)\n"

                    if let note = highlight.personalNote, !note.isEmpty {
                        bookBlock += "  Personal note: \(note)\n"
                    }
                    if !highlight.tags.isEmpty {
                        bookBlock += "  Tags: \(highlight.tags.joined(separator: ", "))\n"
                    }
                }
                bookBlock += "\n"
                contributedHighlights = true
            }

            // Chapter summaries now live here — dynamic, relevance-gated —
            // instead of unconditionally in the stable prefix.
            if !book.chapters.isEmpty {
                bookBlock += "### \"\(book.title)\" — Chapter Summaries:\n"
                let sortedChapters = book.chapters.sorted { ($0.chapterNumber ?? 0) < ($1.chapterNumber ?? 0) }
                for chapter in sortedChapters {
                    var chapterLine = "- \(chapter.title): \(chapter.summary)"
                    if !chapter.keyLessons.isEmpty {
                        chapterLine += " | Key lessons: \(chapter.keyLessons.joined(separator: ", "))"
                    }
                    bookBlock += chapterLine + "\n"
                }
                bookBlock += "\n"
            }

            guard !bookBlock.isEmpty else {
                // Nothing to show for this book, but small books are still
                // cited as "relevant" even with zero content — matches
                // `buildContext`'s exact rule.
                if !isLargeBook {
                    referencedBookIDs.insert(book.id)
                }
                continue
            }

            if dynamic.count + bookBlock.count > dynamicContextCharBudget {
                budgetExhausted = true
                dynamic += "(Additional library content omitted to stay within this turn's context budget.)\n\n"
                break
            }

            dynamic += bookBlock

            // Matches `buildContext`'s citation rule exactly: a large book is
            // cited only when it actually contributed a ranked highlight
            // that made it into the prompt; a small book is cited whenever
            // relevant, regardless of whether it had highlights to show.
            if contributedHighlights && isLargeBook {
                referencedBookIDs.insert(book.id)
            }
            if !isLargeBook {
                referencedBookIDs.insert(book.id)
            }
        }

        if !budgetExhausted && !relevantBooks.isEmpty && relevantBooks.count < sortedBooks.count {
            let otherBooks = sortedBooks.filter { book in
                !relevantBooks.contains(where: { $0.id == book.id })
            }
            if !otherBooks.isEmpty {
                dynamic += "### Other books in library:\n"
                for book in otherBooks {
                    dynamic += "- \"\(book.title)\" by \(book.author)\(traditionSuffix(for: book)) (\(book.highlightCount) highlights, \(book.chapterCount) chapters)\n"
                }
                dynamic += "\n"
            }
        }

        let citedTitles = unionBooks.filter { referencedBookIDs.contains($0.id) }.map(\.title)
        return (stable, dynamic, citedTitles)
    }

    /// Same stable/dynamic split as `buildSplitContext`, but scoped to a
    /// single book — the retrieval side of a book-specific chat thread. No
    /// "which books are relevant" guessing at all: the stable prefix is
    /// always just THIS book's own chapter map (a strict subset of, and
    /// therefore cheaper to cache than, the whole-library stable block used
    /// by the general thread), and the dynamic suffix is either this book's
    /// full highlight set (small books) or its own top-K ranked chunk for
    /// this specific question, with a keyword fallback if ranking comes up
    /// empty — same safety net as `buildSplitContext`, just scoped to one
    /// book instead of applied across the library.
    ///
    /// A book-scoped thread is a DEFAULT FRAME, not a capability restriction.
    /// It used to be the latter, in two reinforcing ways: the prompt template
    /// told the model to refuse anything off-book and suggest switching
    /// threads, and this function passed exactly one book, so the model had
    /// no other book's content available even if it wanted to answer. Asked
    /// "what would Jordan Peterson say across his two books?" inside one of
    /// those books' threads, it correctly reported it couldn't — a hard
    /// content wall, not a soft bias. Per Rajan: every chat surface must be
    /// able to do everything the general thread can; the only difference
    /// between thread types should be what each one ASSUMES the question is
    /// about.
    ///
    /// So `libraryBooks` (the whole library) is now accepted and consulted —
    /// but deliberately only through the DYNAMIC suffix, never the stable
    /// prefix. That split is what preserves this function's entire reason for
    /// existing. The cached prefix stays exactly what it always was, this
    /// book's own chapter index: byte-identical turn over turn, a strict
    /// subset of the general thread's stable block, and unaffected by library
    /// size. Prompt caching is a strict prefix match, so widening the prefix
    /// to the whole library would have reintroduced precisely the unbounded
    /// cache-cold prefill `buildSplitContext`'s doc comment describes. Instead
    /// the cross-book material rides in the uncached suffix, admitted only
    /// when the query gives explicit evidence it reaches outside this book,
    /// and separately capped by `crossBookContextCharBudget` so a book-scoped
    /// turn can never grow to a general-thread-sized turn (see
    /// `crossBookContextBlock`).
    ///
    /// Citation is no longer trivially "always this one book": a reply can now
    /// genuinely draw on a second book, so the caller shows a chip exactly
    /// when the model declares one other than this thread's own book (see
    /// `ChatView.completeReveal`).
    static func buildSplitContextForBook(
        query: String,
        book: Book,
        libraryBooks: [Book] = [],
        personalWritingEntries: [PersonalWritingEntry] = [],
        includePersonalWriting: Bool = false,
        useRealNamesInLifeExamples: Bool = false,
        crossChat: CrossChatInput = .init()
    ) -> (stableContext: String, dynamicContext: String) {
        var stable = "## Chapter Index — \"\(book.title)\" by \(book.author)\n\n"
        if !book.chapters.isEmpty {
            let sortedChapters = book.chapters.sorted { ($0.chapterNumber ?? 0) < ($1.chapterNumber ?? 0) }
            for chapter in sortedChapters {
                stable += "- \(chapter.title)\n"
            }
            stable += "\n"
        }

        let isLargeBook = requiresRetrievalGating(book)
        var highlightsToShow: [Highlight]
        if isLargeBook {
            let rankedChunks = semanticSearch(query: query, books: [book], topK: chunkTopK)
            highlightsToShow = rankedChunks
            if highlightsToShow.isEmpty {
                // Retrieval-only expansion. Never shown to the model or the user --
        // it exists so "left me on read" can find prose written in 1748.
        let retrievalQuery = expandedRetrievalQuery(query)
        let queryTokens = significantTokens(retrievalQuery)
                highlightsToShow = Array(book.highlights.filter { highlight in
                    highlightMatches(highlight, queryTokens: queryTokens)
                }.prefix(chunkTopK))
            }
        } else {
            highlightsToShow = Array(book.highlights.prefix(maxHighlightsPerBookInDynamicContext))
        }

        var dynamic = "## Most Relevant Content for This Question\n\n"

        // Same additional, separately-capped, retrieval-gated personal-writing
        // pool as `buildSplitContext` above — never computed when
        // `includePersonalWriting` is false. The final `dynamicContextCharBudget`
        // truncation below (this function's existing single-shot guard, unlike
        // `buildSplitContext`'s per-block loop) still applies to the whole
        // `dynamic` string including this block, so the budget ceiling holds
        // either way.
        if includePersonalWriting && !personalWritingEntries.isEmpty {
            dynamic += personalWritingContextBlock(query: query, entries: personalWritingEntries, useRealNames: useRealNamesInLifeExamples)
        }

        // Same position and same reasoning as in `buildSplitContext`: after his
        // journal, before the book's own material.
        if crossChat.enabled && !crossChat.prebuiltBlock.isEmpty {
            dynamic += crossChat.prebuiltBlock
        }

        if !highlightsToShow.isEmpty {
            dynamic += "### Highlights:\n"
            for highlight in highlightsToShow {
                var locationParts: [String] = []
                if let chapter = highlight.chapter {
                    locationParts.append("Chapter: \(chapter)")
                }
                if let page = highlight.page {
                    locationParts.append("Page: \(page)")
                }
                let locationString = locationParts.isEmpty ? "" : " (\(locationParts.joined(separator: ", ")))"

                dynamic += "- \"\(highlight.text)\"\(locationString)\n"

                if let note = highlight.personalNote, !note.isEmpty {
                    dynamic += "  Personal note: \(note)\n"
                }
                if !highlight.tags.isEmpty {
                    dynamic += "  Tags: \(highlight.tags.joined(separator: ", "))\n"
                }
            }
            dynamic += "\n"
        }

        // Chapter summaries live here now — dynamic, not the stable prefix —
        // matching `buildSplitContext`'s change above.
        if !book.chapters.isEmpty {
            dynamic += "### Chapter Summaries:\n"
            let sortedChapters = book.chapters.sorted { ($0.chapterNumber ?? 0) < ($1.chapterNumber ?? 0) }
            for chapter in sortedChapters {
                var chapterLine = "- \(chapter.title): \(chapter.summary)"
                if !chapter.keyLessons.isEmpty {
                    chapterLine += " | Key lessons: \(chapter.keyLessons.joined(separator: ", "))"
                }
                dynamic += chapterLine + "\n"
            }
            dynamic += "\n"
        }

        // The rest of the library, appended LAST and only when this question
        // actually reaches outside this book — so the focus book's own
        // material always has first claim on the budget, and an ordinary
        // in-book question produces byte-for-byte the same prompt it did
        // before this capability existed.
        dynamic += crossBookContextBlock(
            query: query,
            otherBooks: libraryBooks.filter { $0.id != book.id }
        )

        if dynamic.count > dynamicContextCharBudget {
            dynamic = String(dynamic.prefix(dynamicContextCharBudget))
                + "\n\n(Additional content omitted to stay within this turn's context budget.)\n"
        }

        return (stable, dynamic)
    }

    /// Hard ceiling on the cross-book section of a BOOK-SCOPED turn, well
    /// under `dynamicContextCharBudget` (which still bounds the turn overall).
    /// The point of a book-scoped thread is a smaller, cheaper, more focused
    /// context than the general thread; letting the "also check the rest of
    /// the library" section grow to general-thread size would erase that
    /// difference and make the thread distinction cosmetic.
    static let crossBookContextCharBudget = 30_000

    /// Per-book cap inside the cross-book section — deliberately tighter than
    /// `maxHighlightsPerBookInDynamicContext`, since this is supporting
    /// material for a thread that is still primarily about a different book.
    static let maxHighlightsPerCrossBook = 12

    /// The material a book-scoped thread pulls in from the REST of the
    /// library, or an empty string when the question doesn't reach outside
    /// this thread's book.
    ///
    /// Admission is by explicit textual evidence only — the query names
    /// another book's title or author (`queryMentions`), or shares a
    /// distinctive word with one of its highlights (`highlightMatches`) —
    /// rather than by unconditional semantic reach. That's the deliberate
    /// difference from `buildSplitContext`, and it is what keeps "book-scoped"
    /// meaningful: a question with no textual link to any other book produces
    /// nothing here and costs nothing, so the default framing is preserved
    /// without ever being enforced as a refusal. Once a book IS admitted, its
    /// highlights are chosen by exactly the same `semanticSearch`/`Ranker`
    /// path the general thread uses (with the same keyword safety net for
    /// books whose embeddings haven't backfilled yet), so nothing about
    /// relevance ranking is reimplemented here.
    static func crossBookContextBlock(query: String, otherBooks: [Book]) -> String {
        guard !otherBooks.isEmpty else { return "" }
        // Retrieval-only expansion. Never shown to the model or the user --
        // it exists so "left me on read" can find prose written in 1748.
        let retrievalQuery = expandedRetrievalQuery(query)
        let queryTokens = significantTokens(retrievalQuery)
        guard !queryTokens.isEmpty else { return "" }

        // Named books first, then books linked only by shared vocabulary —
        // same relevance ordering `buildSplitContext` relies on, so if the
        // budget below runs out it's never the explicitly-named book that
        // gets dropped.
        //
        // WHY the admission reason is carried forward rather than discarded:
        // a book the user NAMED usually shares no vocabulary with its own
        // highlights. "What would Jordan Peterson say about this?" has exactly
        // two distinctive words, and neither appears in the text of a Peterson
        // highlight — so a name-admitted book whose embeddings haven't
        // backfilled would pass admission and then contribute nothing, leaving
        // the model to answer about a book it was handed no content from.
        // That is Rajan's original failure wearing a different hat, so a named
        // book falls back to its own opening highlights rather than to a
        // keyword filter it can never satisfy.
        var admitted: [(book: Book, wasNamed: Bool)] = otherBooks
            .filter { queryMentions($0.title, queryTokens: queryTokens) || queryMentions($0.author, queryTokens: queryTokens) }
            .map { ($0, true) }
        for candidate in otherBooks where !admitted.contains(where: { $0.book.id == candidate.id }) {
            if candidate.highlights.contains(where: { highlightMatches($0, queryTokens: queryTokens) }) {
                admitted.append((candidate, false))
            }
        }
        guard !admitted.isEmpty else { return "" }

        let rankedIDs = Set(semanticSearch(query: query, books: admitted.map(\.book), topK: chunkTopK).map(\.id))

        var block = "## Other Books In This Library (relevant to this question)\n\n"
        block += "This question appears to reach beyond this thread's book, so relevant material from the rest of the user's library is included below. Name the book each point comes from when you use it.\n\n"

        var used = false
        for (candidate, wasNamed) in admitted {
            var highlights = candidate.highlights.filter { rankedIDs.contains($0.id) }
            if highlights.isEmpty {
                // Same safety net as everywhere else in this file: an admitted
                // book can contribute zero ranked highlights when its
                // embeddings haven't backfilled. A keyword-admitted book falls
                // back to the highlights that admitted it; a NAMED book falls
                // back to its opening highlights, because the words that
                // admitted it were the author's or the title's and will not
                // appear in its own prose (see the admission comment above).
                highlights = wasNamed
                    ? candidate.highlights
                    : candidate.highlights.filter { highlightMatches($0, queryTokens: queryTokens) }
            }
            highlights = Array(highlights.prefix(maxHighlightsPerCrossBook))
            guard !highlights.isEmpty else { continue }

            var bookBlock = "### \"\(candidate.title)\" by \(candidate.author)\n"
            for highlight in highlights {
                var locationParts: [String] = []
                if let chapter = highlight.chapter {
                    locationParts.append("Chapter: \(chapter)")
                }
                if let page = highlight.page {
                    locationParts.append("Page: \(page)")
                }
                let locationString = locationParts.isEmpty ? "" : " (\(locationParts.joined(separator: ", ")))"
                bookBlock += "- \"\(highlight.text)\"\(locationString)\n"
                if let note = highlight.personalNote, !note.isEmpty {
                    bookBlock += "  Personal note: \(note)\n"
                }
            }
            bookBlock += "\n"

            if block.count + bookBlock.count > crossBookContextCharBudget {
                block += "(Further cross-book material omitted to keep this thread focused.)\n\n"
                break
            }
            block += bookBlock
            used = true
        }

        // Every admitted book turned out to have nothing showable — emit
        // nothing at all rather than a header promising content that isn't
        // there, which would invite the model to invent it.
        return used ? block : ""
    }

    /// Ranks highlights across all books by cosine similarity between the
    /// query's embedding and each highlight's stored embedding. Falls back to
    /// case-insensitive substring matching (on highlight text and tags) if the
    /// query itself can't be embedded. Highlights that don't have an embedding
    /// yet are simply skipped in the ranked path (backfill fills them in over
    /// time) rather than surfaced with a meaningless score.
    ///
    /// Ranking itself is `CobuxCore.Ranker`, not a flat sorted top-K: the old
    /// implementation here took a flat top-K across `books.flatMap(\.highlights)`
    /// with an absolute `minimumSimilarity: Float = 0.4` floor meant to filter
    /// out noise matches. That floor was a no-op — mean-pooled
    /// `NLContextualEmbedding` vectors of arbitrary English sit in a narrow
    /// 0.7-0.95 cosine band regardless of relevance — and with the two medical
    /// textbooks holding ~95% of the corpus, an untargeted query's top-K was
    /// dominated by clinical text on sheer volume, drowning out a genuinely
    /// strong match from a small book. `Ranker` z-normalizes similarity PER
    /// BOOK before merging pools (so each book's own best item is comparable
    /// regardless of that book's absolute score band), caps how many items any
    /// one book can contribute, and uses a threshold relative to the pool's
    /// own best score instead of an absolute floor that doesn't mean anything
    /// for this embedding model.
    /// Finds a `Figure` relevant to `query`, scoped to books the reply already
    /// cited — a completely separate, ADDITIVE lookup that runs once per
    /// completed chat turn, AFTER a reply has already streamed back and been
    /// finalized (see `ChatView.completeReveal`). Never touches `buildContext`/
    /// `buildSplitContext`, the stable/dynamic cache split, or citation
    /// parsing — those pipelines are unaware this function exists.
    ///
    /// Deliberately cheap: reuses the existing ranked `semanticSearch` (no
    /// reimplemented ranking), then a single scoped `FetchDescriptor` fetch —
    /// not a full table scan — mirroring the exact safe by-id-predicate
    /// pattern already used in `BookCard.loadHighlightCount()`.
    static func relevantFigure(query: String, citedBooks: [Book], modelContext: ModelContext) -> Figure? {
        guard !citedBooks.isEmpty else { return nil }

        // Reuse the same ranked retrieval as everything else in this file.
        // A `Highlight`'s real `chapterRef` relationship (NOT the plain
        // `chapter: String?` display field) is the stable anchor back to a
        // `Chapter` — and therefore to any `Figure`s filed under it.
        let rankedHighlights = semanticSearch(query: query, books: citedBooks, topK: 5)
        for highlight in rankedHighlights {
            guard let chapterID = highlight.chapterRef?.id else { continue }
            var descriptor = FetchDescriptor<Figure>(
                predicate: #Predicate<Figure> { $0.chapter?.id == chapterID }
            )
            descriptor.fetchLimit = 1
            if let figure = try? modelContext.fetch(descriptor).first {
                return figure
            }
        }

        // Safety-net fallback, matching this file's own keyword-fallback style
        // elsewhere (see `buildContext`'s comments): no ranked highlight's
        // chapter turned up a figure, so fall back to a plain caption keyword
        // match against the cited books' own figures (`Book.figures` is
        // already the real inverse relationship — no separate fetch needed).
        let words = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 }
        guard !words.isEmpty else { return nil }

        for book in citedBooks {
            for figure in book.figures {
                let captionLower = figure.caption.lowercased()
                if words.contains(where: { captionLower.contains($0) }) {
                    return figure
                }
            }
        }

        return nil
    }

    /// How many ranked personal-writing entries get injected per chat turn —
    /// deliberately small (unlike `chunkTopK` for highlights): this is
    /// supplementary context to Rajan's own past reflections, not the
    /// library's primary content.
    static let personalWritingTopK = 3

    /// Per-entry excerpt cap. Personal-writing entries (journal/reflection
    /// text) can run far longer than a book highlight, so unlike highlights
    /// (injected in full) each one is truncated to a short excerpt here —
    /// combined with `personalWritingTopK`, this block can never meaningfully
    /// threaten `dynamicContextCharBudget` on its own.
    static let personalWritingExcerptCharLimit = 400

    /// Builds the "Rajan's Own Personal Writing" dynamic-context block for a
    /// chat turn, or an empty string when nothing is relevant. Callers
    /// (`buildSplitContext`/`buildSplitContextForBook`) are responsible for
    /// gating this behind the caller's privacy toggle — this function itself
    /// makes no such check, so it must never be called when that toggle is
    /// off.
    // internal (not private) solely so the anonymization instruction is unit-testable —
    // the names rule is the privacy core of the life-examples feature and must not
    // silently regress in a refactor.
    /// True when the user has actually asked about their own writing.
    ///
    /// The block below is written for INCIDENTAL use -- it tells the model to
    /// weave in at most one excerpt and that most replies need none, which is
    /// right when someone asks about a book and their journal merely happens to
    /// echo it. It is exactly wrong when they ask about the journal itself: the
    /// instruction then argues against the request. Rajan reported that shape:
    /// "i say get use my journals to extract more information out... Cobux is
    /// actually not utilizing the journals of a user".
    /// Dates every excerpt, so a reply can say WHEN he wrote something rather
    /// than referring to it as if it were undated.
    /// Built once, not per excerpt. `dateLabel` is called from inside the
    /// `for entry in ranked` loop in `personalWritingContextBlock`, on the
    /// send path, so a fresh `DateFormatter` here was a locale + calendar +
    /// date-symbol resolution per excerpt per turn.
    ///
    /// Safe to share: nothing mutates it after construction (the documented
    /// condition for `DateFormatter` reuse), and prompt assembly is main-actor
    /// work -- `ChatView.send` says so where it hands back from its detached
    /// task: "Assembly still faults models and so still belongs to the main
    /// actor." Same pair of conditions as `ChatView`'s time-mark formatters.
    private static let excerptDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    private static func dateLabel(_ entry: PersonalWritingEntry) -> String {
        "(" + excerptDateFormatter.string(from: entry.modifiedDate ?? entry.dateImported) + ")"
    }

    static func asksAboutOwnWriting(_ query: String) -> Bool {
        let lowered = query.lowercased()
        let markers = ["my journal", "my journals", "my writing", "my entries",
                       "my notes", "i wrote", "i've written", "ive written",
                       "my diary", "what i wrote", "from my journal"]
        return markers.contains { lowered.contains($0) }
    }

    static func personalWritingContextBlock(query: String, entries: [PersonalWritingEntry], useRealNames: Bool) -> String {
        // When he is asking about his own writing, retrieve more of it and
        // quote it at greater length -- a direct question deserves the material,
        // not three 400-character asides.
        let direct = asksAboutOwnWriting(query)
        // Quiet words apply to the INCIDENTAL weave, not to a direct question.
        //
        // The distinction is the whole point of the feature. Quieting a name
        // means "stop bringing this up at me unprompted" -- it is not a
        // redaction of his own journal, and an app that refused to answer "what
        // did I write about her" would be censoring him with his own setting.
        // But the non-direct branch is unprompted by construction: he asks about
        // Stoicism and gets his ex woven in as a lived example. That is the
        // exact surface the quiet list exists to close, and it was the last one
        // still open after the card, the deck and Ebb.
        let floor = Calendar.current.date(
            byAdding: .day, value: -JournalHighlightSelector.minimumAgeDays, to: .now)
        let pool = direct ? entries : entries.filter { entry in
            // The incidental weave is ambient-shaped -- an unprompted quotation
            // of his journal inside an answer about something else -- so it
            // inherits the whole ambient ruleset, not half of it. It had the
            // quiet-words gate but not the age floor, which meant something
            // written yesterday could be quoted back at him while he was asking
            // about a book. "Fresh writing is a wound, not a highlight."
            //
            // A DIRECT question keeps no floor: "how have I been doing lately"
            // is precisely about yesterday.
            guard JournalHighlightSelector.maySurface(entry.text) else { return false }
            guard let floor else { return true }
            return (entry.modifiedDate ?? entry.dateImported) < floor
        }
        var ranked = relevantPersonalWriting(query: query, entries: pool,
                                             topK: direct ? personalWritingTopK * 4 : personalWritingTopK)
        // THE JOURNAL THREAD MUST BE ABLE TO SEE ALL OF HIS WRITING.
        //
        // `relevantPersonalWriting` scores by embedding and SKIPS any entry
        // whose `embeddingData` is nil. Entries written inside Cobux are
        // embedded at save; entries IMPORTED from Notes and Apple Journal come
        // in with `deferEmbeddings` and wait for the background backfill. So
        // until that backfill reaches them, every older imported entry was
        // invisible to this thread -- which he read, exactly, as "the journal
        // chat only has access to journals since when we actually created the
        // feature, September 7". Nothing was scoped by date; the date was the
        // seam between embedded and not-yet-embedded rows.
        //
        // For a DIRECT question about his own journal, an entry without a
        // vector is still his writing and is not allowed to be unreachable.
        // Top up by recency from the un-embedded remainder, newest first, so
        // the thread has the whole archive to draw on while the backfill does
        // its work. The ambient (non-direct) weave keeps the vector-only rule:
        // there, an unranked quotation is exactly the unprompted surfacing the
        // quiet-words ruleset exists to prevent.
        if direct {
            let cap = personalWritingTopK * 4
            if ranked.count < cap {
                let seen = Set(ranked.map(\.persistentModelID))
                let unembedded = pool
                    .filter { $0.embeddingData == nil && !seen.contains($0.persistentModelID) }
                    .sorted { ($0.modifiedDate ?? $0.dateImported) > ($1.modifiedDate ?? $1.dateImported) }
                ranked.append(contentsOf: unembedded.prefix(cap - ranked.count))
            }
        }
        guard !ranked.isEmpty else { return "" }

        // The life-examples layer: the model may ground an answer in the
        // user's own lived experience the way it grounds one in a book —
        // sparingly, and only where the parallel genuinely fits. The names
        // rule is the privacy core: real names from journals stay private
        // unless the user has explicitly flipped the Settings toggle, so an
        // excerpt mentioning a real person surfaces as "a friend" / "someone
        // he was close to", never the name itself.
        // "The user's", not "Rajan's". Every install shares this prompt, so anyone else
        // importing their own writing had it introduced to the model under his name --
        // which is both wrong and quietly confusing for the model about whose life it is
        // reading. The excerpts are the user's own either way.
        var block = "## The User's Own Personal Writing (relevant excerpts, if any)\n\n"
        block += direct
            ? "The user is asking about their own writing, so these excerpts are the PRIMARY material for this reply -- read them closely, draw on as many as genuinely bear on the question, quote them, and cite each by its date. Do not hold back to one example and do not answer from the books alone when their own words are right here. "
            : "Where one of these excerpts genuinely parallels the question, you may briefly weave it in as a lived example alongside the books (\"something similar shows up in your own journal…\"). Use at most one such example per reply, only when it truly fits — most replies should not need one. "
        block += useRealNames
            ? "You may refer to people from these excerpts by the names used there.\n\n"
            : "NEVER repeat personal names of private individuals from these excerpts — refer to people only by role or relationship (\"a friend\", \"someone you wrote about\"), even if the excerpt names them.\n\n"
        for entry in ranked {
            let limit = direct ? personalWritingExcerptCharLimit * 3 : personalWritingExcerptCharLimit
            let excerpt = entry.text.count > limit
                ? String(entry.text.prefix(limit)) + "…"
                : entry.text
            block += "- [\(entry.source)] \(dateLabel(entry)) \"\(entry.title)\": \(excerpt)\n"
        }
        block += "\n"
        return block
    }

    /// Journal-thread retrieval caps -- deliberately much roomier than the
    /// aside injection above (`personalWritingTopK` 3 × 400 chars): there the
    /// journal is supplementary color on a book answer, here it is the entire
    /// grounding. 12 × 1200 ≈ 14k chars worst case, well inside a prompt.
    ///
    /// Twelve, not eight, as of build 58. A third of the slots is reserved for
    /// writing the ranker cannot see (`journalThreadUnembeddedReserve`), so at
    /// eight the ranked share would have been five entries -- too thin for "how
    /// have I been doing" once the reserve is taken out of it.
    static let journalThreadTopK = 12
    static let journalThreadEntryCharLimit = 1200

    /// How many of the `journalThreadTopK` slots go to entries WITHOUT a
    /// vector whenever any exist. The ranker only sees embedded entries;
    /// imported entries wait on the background backfill for theirs, and a
    /// long entry the embedder declines waits forever. Without a reserve, a
    /// journal with more embedded entries than slots fills every slot from
    /// the embedded side and the imported archive is invisible no matter how
    /// large it is -- which is exactly what build 57 shipped: the top-up ran
    /// only when the ranked list came back short, and with 318 entries it
    /// never did.
    static let journalThreadUnembeddedReserve = journalThreadTopK / 3

    /// What a journal question is asking about, as far as the date metadata
    /// is concerned. Decides whether a month named in the query narrows the
    /// pool and which end of the archive the top-up leans toward.
    enum JournalReach: Equatable {
        /// A point or period: "what was I writing about in March?". A named
        /// month narrows the pool to that month.
        case period
        /// A span or the whole archive: "since June", "between March and
        /// July", "all my journals". A named month is a boundary, not a
        /// filter, so narrowing is skipped; the top-up stays recency-first.
        case range
        /// The beginning of the archive: "before September", "my earliest
        /// entry", "the first thing I wrote". Narrowing is skipped AND the
        /// pool leans toward the oldest entries, because similarity between
        /// the word "earliest" and what was written years ago is noise -- the
        /// date is what answers the question.
        case earliest
    }

    /// Words that make a named month a boundary rather than a filter. Rajan
    /// asked the journal thread "Can you access before September 7 on all my
    /// journals?" and `monthMentioned` saw "September", narrowed the pool to
    /// September's entries, and the model truthfully reported that its
    /// earliest entry was September 7 -- for a question about everything
    /// before September, precisely backwards. Whole-word, lowercase.
    private static let rangeWords: Set<String> = [
        "before", "since", "until", "till", "after", "prior", "earlier", "ago",
        "between", "all", "every", "everything", "whole", "entire", "ever",
        "first", "earliest", "oldest", "beginning", "start", "started", "began",
    ]

    /// The subset of `rangeWords` that also points at the OLD end of the
    /// archive. "after" and "since" point at the new end, which is where the
    /// recency top-up already looks, so they are range words only.
    private static let earliestWords: Set<String> = [
        "before", "prior", "earlier", "first", "earliest", "oldest",
        "beginning", "start", "started", "began",
    ]

    /// Words that appear in nearly every journal question and so say nothing
    /// about which entry it is after. Only the substring top-up consults this;
    /// the embedding ranker weighs whole sentences and needs no stop list.
    private static let journalQueryStopWords: Set<String> = [
        "what", "when", "where", "which", "about", "have", "been", "were", "that",
        "this", "with", "from", "your", "mine", "could", "would", "should", "there",
        "their", "them", "they", "give", "tell", "show", "quick", "little", "summary",
        "summarize", "access", "journal", "journals", "entry", "entries", "diary",
        "write", "wrote", "writing", "written", "note", "notes", "please", "cobux",
    ]

    /// Classifies `query` by the date words it uses. Pure and Foundation-only
    /// so it is unit-testable without a store; `buildJournalContext` is its
    /// only production caller.
    static func journalReach(of query: String) -> JournalReach {
        let tokens = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let words = Set(tokens)
        if !words.isDisjoint(with: earliestWords) { return .earliest }
        if !words.isDisjoint(with: rangeWords) { return .range }
        // "from March to July": neither word is in the sets on its own --
        // "from my journal" and "to" are everywhere -- but the pair around a
        // month is a span.
        if words.contains("from"), words.contains("to"), monthMentioned(in: query) != nil {
            return .range
        }
        return .period
    }

    /// One sentence the model can rely on for what the journal COVERS, as
    /// opposed to what happens to be excerpted below it. Rajan's screenshot
    /// had the thread say "My earliest entry is September 7 at 6:44 PM" about
    /// a journal that begins in 2022: with only a selection in front of it and
    /// nothing saying so, the model described the oldest excerpt as the oldest
    /// entry, which is the honest reading of what it was given. This line
    /// makes that reading wrong. Always present, even when every entry fits,
    /// so the model never has to guess which case it is in.
    ///
    /// `excerpted` is how many entries follow; `narrowedToMonth` names the
    /// month the pool was narrowed to, when it was, so the model knows the
    /// selection is a period and not a sample of the whole.
    static func journalCoverageHeader(entries: [PersonalWritingEntry], excerpted: Int, narrowedToMonth: Int? = nil) -> String {
        let dates = entries.map { $0.modifiedDate ?? $0.dateImported }
        guard let first = dates.min(), let last = dates.max() else { return "" }
        let style = Date.FormatStyle.dateTime.month(.wide).day().year()
        let count = entries.count
        var header = "The journal holds \(count) \(count == 1 ? "entry" : "entries"), from \(first.formatted(style)) to \(last.formatted(style))."
        let excerpts = excerpted == 1 ? "The 1 excerpt below is" : "The \(excerpted) excerpts below are"
        if let narrowedToMonth {
            let monthName = Calendar.current.monthSymbols[max(0, min(11, narrowedToMonth - 1))]
            header += " \(excerpts) drawn from \(monthName) entries only, because the question named that month."
        } else if excerpted < count {
            header += " \(excerpts) a selection, not the whole journal."
        } else {
            header += " Every entry is excerpted below."
        }
        header += " Do not describe the earliest excerpt as the earliest entry, or the latest excerpt as the latest, and answer questions about how far back the journal goes from this line."
        return header
    }

    /// Whether an entry has a vector the ranker can score. An empty `Data`
    /// is the backfill's "tried, nothing to index" marker for empty text and
    /// counts as un-embedded here too -- such an entry has no text worth a
    /// slot, but it is also not something a ranked list ever contained.
    private static func hasVector(_ entry: PersonalWritingEntry) -> Bool {
        guard let data = entry.embeddingData else { return false }
        return !data.isEmpty
    }

    /// Builds the "My Journal" chat thread's context block (see
    /// `PromptTemplates.journalGrounded`): a coverage header, then the chosen
    /// entries, each prefixed with its date so "what was I writing about in
    /// March?" is answerable as a date question, not just a similarity one.
    ///
    /// Selection is `relevantPersonalWriting`'s embedding ranking with
    /// journal-specific layers on top, all soft so the thread never comes up
    /// empty while entries exist:
    /// - a month mentioned in a PERIOD question ("March") narrows the pool to
    ///   that month's entries first, because cosine similarity between the
    ///   word "march" and what was actually written that March is near noise
    ///   -- the date metadata, not the text, answers a period question. A
    ///   RANGE question ("before September", "since June") skips this: there
    ///   the month is a boundary, and narrowing to it inverted the question;
    /// - an EARLIEST question ("my first entries", "before September") seeds
    ///   half the slots with the oldest entries in the pool before any
    ///   ranking runs, for the same reason -- the date answers it;
    /// - a third of the slots is reserved for entries without a vector
    ///   whenever any exist (`journalThreadUnembeddedReserve`): substring hits
    ///   on the query's words first, then by date, leaning old or new with
    ///   the question. Imported entries waiting on the backfill are his
    ///   writing and are never invisible to the thread whose subject they are;
    /// - whatever is still unfilled is topped up by date from the rest of the
    ///   pool, so a vague "how have I been doing lately?" still gets real
    ///   grounding when nothing ranks.
    ///
    /// No privacy gate here, unlike `personalWritingContextBlock`'s caller
    /// contract: the aside toggle governs journal excerpts leaking into BOOK
    /// answers, while this runs only for the thread whose stated purpose is
    /// the journal, itself behind the journal's Face ID lock in `ChatView`.
    static func buildJournalContext(query: String, entries: [PersonalWritingEntry]) -> String {
        guard !entries.isEmpty else {
            return "(The journal has no entries yet. Say so plainly if asked about its contents.)\n"
        }

        let reach = journalReach(of: query)
        func stamp(_ entry: PersonalWritingEntry) -> Date { entry.modifiedDate ?? entry.dateImported }
        // Old end first for an earliest question, new end first otherwise.
        func byReach(_ a: PersonalWritingEntry, _ b: PersonalWritingEntry) -> Bool {
            reach == .earliest ? stamp(a) < stamp(b) : stamp(a) > stamp(b)
        }

        var pool = entries
        var narrowedToMonth: Int?
        if reach == .period, let month = monthMentioned(in: query) {
            let calendar = Calendar.current
            let matching = entries.filter { calendar.component(.month, from: stamp($0)) == month }
            if !matching.isEmpty {
                pool = matching
                narrowedToMonth = month
            }
        }

        let topK = journalThreadTopK
        var chosen: [PersonalWritingEntry] = []
        var chosenIDs = Set<UUID>()
        func take(_ candidates: [PersonalWritingEntry], upTo limit: Int) {
            for entry in candidates where chosen.count < limit && !chosenIDs.contains(entry.id) {
                chosen.append(entry)
                chosenIDs.insert(entry.id)
            }
        }

        if reach == .earliest {
            take(pool.sorted { stamp($0) < stamp($1) }, upTo: topK / 2)
        }

        let remaining = pool.filter { !chosenIDs.contains($0.id) }
        let unembedded = remaining.filter { !hasVector($0) }
        let reserve = min(unembedded.count, journalThreadUnembeddedReserve)
        let ranked = relevantPersonalWriting(query: query, entries: remaining, topK: topK)
        take(ranked, upTo: max(chosen.count, topK - reserve))

        // The reserve: his un-embedded writing, query words first, then by date.
        // Function words and the words every journal question shares
        // ("journal", "wrote") would match every entry and make the hit
        // ordering meaningless, so they are not query words here.
        let queryWords = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !rangeWords.contains($0) && !journalQueryStopWords.contains($0) }
        func mentionsQuery(_ entry: PersonalWritingEntry) -> Bool {
            guard !queryWords.isEmpty else { return false }
            let haystack = (entry.title + " " + entry.text).lowercased()
            return queryWords.contains { haystack.contains($0) }
        }
        let hits = unembedded.filter(mentionsQuery).sorted(by: byReach)
        let misses = unembedded.filter { !mentionsQuery($0) }.sorted(by: byReach)
        take(hits + misses, upTo: topK)
        // Anything still open goes to the rest of the pool by date.
        take(remaining.sorted(by: byReach), upTo: topK)

        var block = journalCoverageHeader(entries: entries, excerpted: chosen.count, narrowedToMonth: narrowedToMonth) + "\n\n"
        for entry in chosen.sorted(by: { stamp($0) < stamp($1) }) {
            let date = stamp(entry).formatted(.dateTime.month(.wide).day().year())
            let excerpt = entry.text.count > journalThreadEntryCharLimit
                ? String(entry.text.prefix(journalThreadEntryCharLimit)) + "…"
                : entry.text
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            block += title.isEmpty
                ? "[\(date)]\n\(excerpt)\n\n"
                : "[\(date)] \"\(title)\"\n\(excerpt)\n\n"
        }
        return block
    }

    /// The 1-12 month number a query names, or nil. Whole-word match against
    /// the calendar's full and abbreviated month symbols ("march", "mar"),
    /// case-insensitive -- kept Foundation-only and pure so it runs in the
    /// macOS assertion harness. "May" is special-cased: it's also an everyday
    /// modal verb ("what may help?"), so it only counts as the month when a
    /// preposition/determiner that dates it comes immediately before ("in
    /// may", "last may") -- a soft miss there just skips the month narrowing,
    /// it never empties the pool.
    ///
    /// Deliberately blind to range words: this answers "is a month named",
    /// and `journalReach(of:)` answers "is it a filter or a boundary". Kept
    /// separate so each stays a one-line test.
    static func monthMentioned(in query: String) -> Int? {
        let tokens = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let words = Set(tokens)

        func accept(_ name: String, _ index: Int) -> Int? {
            guard words.contains(name) else { return nil }
            if name == "may" {
                let dateContexts: Set<String> = ["in", "during", "last", "this", "since", "of", "for", "until", "through", "early", "late", "mid"]
                guard let position = tokens.firstIndex(of: "may"), position > 0,
                      dateContexts.contains(tokens[position - 1]) else { return nil }
            }
            return index + 1
        }

        let calendar = Calendar.current
        for (index, name) in calendar.monthSymbols.enumerated() {
            if let month = accept(name.lowercased(), index) { return month }
        }
        for (index, name) in calendar.shortMonthSymbols.enumerated() {
            if let month = accept(name.lowercased(), index) { return month }
        }
        return nil
    }

    /// Ranks Rajan's own personal-writing entries (imported via
    /// `PersonalWritingImportService`) against `query`, reusing the exact
    /// same `Ranker`/cosine-similarity approach `semanticSearch` uses for
    /// highlights above — no reimplemented ranking logic. `entry.source`
    /// (the Notes folder it came from) stands in for `Highlight`'s `bookID`
    /// as `Ranker`'s per-pool grouping key, so no one folder can crowd out
    /// the others the same way no one book can crowd out another.
    ///
    /// Falls back to case-insensitive substring matching on `text`/`title` if
    /// the query itself can't be embedded, same degrade-gracefully rule as
    /// `semanticSearch`. Entries without an embedding yet are simply skipped
    /// in the ranked path, same as an un-embedded highlight.
    ///
    /// This is retrieval only — callers (`ChatView`/`ChatPromptBuilder`) are
    /// responsible for skipping the call entirely when the user's privacy
    /// toggle is off, not this function.
    static func relevantPersonalWriting(query: String, entries: [PersonalWritingEntry], topK: Int = 3) -> [PersonalWritingEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, !entries.isEmpty else { return [] }

        guard let queryVector = EmbeddingService.embed(trimmedQuery) else {
            let queryLower = trimmedQuery.lowercased()
            return Array(
                entries.filter { entry in
                    entry.text.lowercased().contains(queryLower) ||
                    entry.title.lowercased().contains(queryLower)
                }
                .prefix(topK)
            )
        }

        return relevantPersonalWriting(queryVector: queryVector, entries: entries, topK: topK)
    }

    /// The ranked half of `relevantPersonalWriting(query:...)`. Its only
    /// caller today is that wrapper, one line up: nothing outside this file
    /// holds a query vector to hand in. What actually stops one chat send
    /// paying for the same inference several times over is
    /// `EmbeddingService.embed`'s memo, which collapses repeated
    /// `(query:)` calls for the SAME text to one forward pass -- so this
    /// overload is a seam for a caller that has the vector already, not a
    /// de-dup mechanism anything currently depends on. No keyword fallback
    /// here: a caller with a vector has, by definition, an embeddable query.
    static func relevantPersonalWriting(queryVector: [Float], entries: [PersonalWritingEntry], topK: Int = 3) -> [PersonalWritingEntry] {
        guard !queryVector.isEmpty, !entries.isEmpty else { return [] }

        var entriesByID: [String: PersonalWritingEntry] = [:]
        var items: [RankableItem] = []
        items.reserveCapacity(entries.count)
        for entry in entries {
            // Bulk decode straight from the stored bytes -- see
            // `EmbeddingService.decodeVector`. An empty vector is the
            // backfill's "nothing to index" marker and is skipped, not scored
            // as a zero that `Ranker` might still admit for a one-entry pool.
            guard let data = entry.embeddingData else { continue }
            let vector = EmbeddingService.decodeVector(data)
            guard !vector.isEmpty else { continue }
            let idString = entry.id.uuidString
            entriesByID[idString] = entry
            items.append(RankableItem(
                id: idString,
                bookID: entry.source,
                rawScore: EmbeddingService.cosineSimilarity(queryVector, vector)
            ))
        }

        return Ranker.rank(items: items, topK: topK).compactMap { entriesByID[$0.id] }
    }

    static func semanticSearch(query: String, books: [Book], topK: Int = 8) -> [Highlight] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        guard let queryVector = EmbeddingService.embed(trimmedQuery) else {
            return keywordFallback(query: trimmedQuery, books: books, topK: topK)
        }

        return semanticSearch(queryVector: queryVector, books: books, topK: topK)
    }

    /// Off the main actor: the same search as `semanticSearch(query:books:topK:)`,
    /// with the inference, the vector decode and the ranking all done on
    /// `SemanticSearchProbe`'s executor. Only `SemanticHit` values -- ids and
    /// scores -- cross back; the rows are then fetched on `modelContext`, which
    /// must be the context that owns `books` (a view's `@Environment` context).
    ///
    /// Why this exists: `books.flatMap(\.highlights)` faults every embedded
    /// highlight in the library -- ~33,400 rows, each carrying a 2 KB vector,
    /// ~66 MB in all -- and did so on the main actor, under the typing
    /// indicator in Chat and behind every keystroke of Library search.
    /// `LibraryView.refreshSemanticResults` said as much in its own comment
    /// ("the search itself stays on this actor"). The probe reads the rows on
    /// its own context, keeps the decoded vectors in `SemanticVectorCache`
    /// for the life of the process, and ranks through the SAME
    /// `rankedHits(queryVector:entries:topK:)` the synchronous path uses --
    /// one ranking function, two callers, so the two can only ever disagree
    /// on the order of exact ties (see `rankedHits`).
    ///
    /// The keyword fallback for a query the on-device model cannot embed
    /// stays on the caller's actor, unchanged: it needs `text`/`tags`, not
    /// vectors, and the model declining a query is the rare path.
    @MainActor
    static func semanticSearch(
        query: String,
        books: [Book],
        topK: Int = 8,
        in modelContext: ModelContext
    ) async -> [Highlight] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, !books.isEmpty else { return [] }

        let scope = Set(books.map(\.id))
        let probe = SemanticVectorCache.shared.probe(for: modelContext.container)
        switch await probe.search(query: trimmedQuery, scope: scope, topK: topK) {
        case .queryNotEmbeddable:
            return keywordFallback(query: trimmedQuery, books: books, topK: topK)
        case .ranked(let hits):
            return resolve(hits, in: modelContext)
        }
    }

    /// The degrade-gracefully path when the query itself can't be embedded:
    /// case-insensitive substring matching on `text`/`tags`, first `topK` in
    /// relationship order. Byte-for-byte what `semanticSearch(query:)` did
    /// inline before the async overload needed the same behaviour.
    private static func keywordFallback(query trimmedQuery: String, books: [Book], topK: Int) -> [Highlight] {
        let queryLower = trimmedQuery.lowercased()
        return Array(
            books.flatMap(\.highlights).filter { highlight in
                highlight.text.lowercased().contains(queryLower) ||
                highlight.tags.contains { $0.lowercased().contains(queryLower) }
            }
            .prefix(topK)
        )
    }

    /// The ranked half of `semanticSearch(query:...)`, for a caller that
    /// already holds the query's vector. Same ranking, same per-book pooling;
    /// the only work saved is the inference. (Repeated `semanticSearch(query:)`
    /// calls for the SAME text within one send are already collapsed to one
    /// inference by `EmbeddingService.embed`'s memo, so existing call sites
    /// need not change to benefit -- this overload is for callers that have
    /// the vector in hand and want to say so.)
    ///
    /// Two ways to the same answer, chosen by what is already in memory:
    ///
    ///   * `SemanticVectorCache` holds a FRESH decoded table for this store --
    ///     score it (33k `vDSP.dot`s, a few milliseconds) and fetch only the
    ///     `topK` winners by id, per book, on the caller's context. No
    ///     relationship is faulted, no `Data` is decoded, nothing is
    ///     materialised that is not returned. This is the path a chat send
    ///     takes once the table has been built once; `buildContext` and
    ///     friends are synchronous by design (their callers in
    ///     `ChatPromptBuilder`/`ChatView`/`AskCobuxIntent` are), so making
    ///     THEIR inner loop cheap is how they stop freezing the typing
    ///     indicator without every caller becoming async.
    ///   * No fresh table yet (first call in the process, or a Highlight was
    ///     saved a moment ago): rank over `books.flatMap(\.highlights)` exactly
    ///     as before -- correctness first -- and ask the cache to warm off-main
    ///     so the NEXT call takes the fast path.
    ///
    /// Both paths hand `rankedHits(queryVector:entries:topK:)` the same shape
    /// of entry, so the ranking cannot drift between them.
    static func semanticSearch(queryVector: [Float], books: [Book], topK: Int = 8) -> [Highlight] {
        guard !queryVector.isEmpty, !books.isEmpty else { return [] }

        let container = books.first?.modelContext?.container
        if let container,
           let modelContext = books.first?.modelContext,
           let table = SemanticVectorCache.shared.freshTable(for: container) {
            let scope = Set(books.map(\.id))
            let hits = rankedHits(queryVector: queryVector, entries: table.entries(inBooks: scope), topK: topK)
            return resolve(hits, in: modelContext)
        }

        SemanticVectorCache.shared.warm(using: container)
        let hits = rankedHits(queryVector: queryVector, highlights: books.flatMap(\.highlights), topK: topK)
        guard !hits.isEmpty else { return [] }
        // Relationship order is the pool order here, exactly as before; the
        // objects are already registered, so this is a dictionary walk.
        var byID: [UUID: Highlight] = [:]
        for book in books {
            for highlight in book.highlights { byID[highlight.id] = highlight }
        }
        return hits.compactMap { byID[$0.id] }
    }

    /// Ranks already-materialised rows -- the pre-cache pool. Builds one
    /// `SemanticVectorTable.Entry` per embedded highlight (empty vectors, the
    /// backfill's "nothing to index" marker, are skipped, not scored) and
    /// hands them to the one ranking function. Public to the test target so
    /// the parity test can hold the relationship pool and the probe's table
    /// side by side.
    static func rankedHits(queryVector: [Float], highlights: [Highlight], topK: Int) -> [SemanticHit] {
        var entries: [SemanticVectorTable.Entry] = []
        entries.reserveCapacity(highlights.count)
        for highlight in highlights {
            // Bulk decode straight from the stored bytes -- see
            // `EmbeddingService.decodeVector`.
            guard let data = highlight.embeddingData else { continue }
            let vector = EmbeddingService.decodeVector(data)
            guard !vector.isEmpty else { continue }
            entries.append(SemanticVectorTable.Entry(
                id: highlight.id,
                bookKey: highlight.book?.id.uuidString ?? SemanticVectorTable.unknownBookKey,
                vector: vector))
        }
        return rankedHits(queryVector: queryVector, entries: entries, topK: topK)
    }

    /// THE ranking. Every semantic search in the app -- the synchronous chat
    /// path, the off-main probe, the pre-cache relationship pool -- ends here,
    /// so there is exactly one place where a highlight's score is decided.
    ///
    /// One `RankableItem` per entry: `id` is the highlight's UUID string,
    /// `bookID` is the owning book's UUID string (or `unknownBookKey` for a
    /// row with no book, which the probe never produces but the relationship
    /// pool could), `rawScore` is the cosine similarity. `Ranker.rank` then
    /// z-normalises per book, applies the per-book cap and the relative
    /// threshold, and returns the top-K -- unchanged, and not reimplemented.
    /// The returned `score` is `Ranker`'s normalised score, not a count of
    /// anything.
    ///
    /// Entry ORDER is the only thing the two pools can differ on, and
    /// `Ranker` sorts by score before it caps, so order can only affect the
    /// relative placement of exact ties -- two rows whose vectors are equal
    /// to the float, i.e. the same text stored twice. That is the whole
    /// difference "identical to today's" allows.
    static func rankedHits(queryVector: [Float], entries: [SemanticVectorTable.Entry], topK: Int) -> [SemanticHit] {
        guard !queryVector.isEmpty, !entries.isEmpty, topK > 0 else { return [] }

        var items: [RankableItem] = []
        items.reserveCapacity(entries.count)
        for entry in entries {
            items.append(RankableItem(
                id: entry.idKey,
                bookID: entry.bookKey,
                rawScore: EmbeddingService.cosineSimilarity(queryVector, entry.vector)
            ))
        }

        let ranked = Ranker.rank(items: items, topK: topK)
        guard !ranked.isEmpty else { return [] }

        // Only the winners are looked up -- a dictionary over the whole pool
        // (what the old loop built, 33k `String` keys per call) is not needed
        // to find `topK` of them.
        let wanted = Set(ranked.map(\.id))
        var byKey: [String: SemanticVectorTable.Entry] = [:]
        byKey.reserveCapacity(wanted.count)
        for entry in entries where wanted.contains(entry.idKey) {
            byKey[entry.idKey] = entry
        }
        return ranked.compactMap { item -> SemanticHit? in
            guard let entry = byKey[item.id] else { return nil }
            return SemanticHit(id: entry.id, bookID: UUID(uuidString: entry.bookKey), score: item.rawScore)
        }
    }

    /// Fetches the winners as rows on `modelContext`, in rank order.
    ///
    /// Per book rather than one `ids.contains($0.id)` over the table:
    /// `Highlight.id` carries no index (see `FlowResonanceProbe`), so a bare
    /// id predicate is a scan of every row's record -- and each record holds
    /// its 2 KB vector inline, so the scan reads the whole table's pages to
    /// find two dozen rows. `book?.id == bookID` walks the relationship's own
    /// index and reads only that book's rows; `WisdomProbe.visibleCounts` is
    /// the precedent. A hit whose row has gone since the table was built
    /// simply drops out.
    private static func resolve(_ hits: [SemanticHit], in modelContext: ModelContext) -> [Highlight] {
        guard !hits.isEmpty else { return [] }
        var byID: [UUID: Highlight] = [:]
        byID.reserveCapacity(hits.count)
        let byBook = Dictionary(grouping: hits, by: \.bookID)
        for (bookID, group) in byBook {
            let ids = group.map(\.id)
            let descriptor: FetchDescriptor<Highlight>
            if let bookID {
                descriptor = FetchDescriptor<Highlight>(
                    predicate: #Predicate<Highlight> { $0.book?.id == bookID && ids.contains($0.id) })
            } else {
                descriptor = FetchDescriptor<Highlight>(
                    predicate: #Predicate<Highlight> { ids.contains($0.id) })
            }
            for highlight in (try? modelContext.fetch(descriptor)) ?? [] {
                byID[highlight.id] = highlight
            }
        }
        return hits.compactMap { byID[$0.id] }
    }
}

// MARK: - Semantic search off the main actor

/// One ranked semantic hit, as it crosses back from `SemanticSearchProbe`.
/// Plain values only -- a `@ModelActor`'s methods must return `Sendable`
/// structs, never a `@Model` (the SE-0338 crash class the repo documents on
/// `WisdomGraphView.loadCounts`). `score` is `Ranker`'s normalised score.
struct SemanticHit: Sendable, Equatable, Identifiable {
    let id: UUID
    /// `nil` only for a row with no book -- the relationship pool can hold
    /// one, the probe's table never does.
    let bookID: UUID?
    let score: Float
}

/// Every embedded highlight in the store, decoded once: `id`, the owning
/// book's key as `Ranker` groups by it, and the `[Float]` vector.
///
/// ~33,400 entries × 512 floats is ~66 MB resident. That is the same set of
/// bytes the old path faulted into the main context's row cache on every
/// chat send and then threw away; here it is paid once per process, off the
/// main actor, and released on a memory warning (`SemanticVectorCache`).
struct SemanticVectorTable: Sendable {
    struct Entry: Sendable, Equatable {
        let id: UUID
        /// `id.uuidString` -- `RankableItem.id` is a `String`, and building
        /// 33k of them per query was measurable; once per table instead.
        let idKey: String
        /// `book.id.uuidString`, or `unknownBookKey`, precomputed for the
        /// same reason.
        let bookKey: String
        let vector: [Float]

        init(id: UUID, bookKey: String, vector: [Float]) {
            self.id = id
            self.idKey = id.uuidString
            self.bookKey = bookKey
            self.vector = vector
        }
    }

    /// What the relationship pool used for a highlight with no book.
    static let unknownBookKey = "unknown"

    let entries: [Entry]

    /// The pool `books.flatMap(\.highlights)` would have produced for these
    /// books: every entry whose owning book is in `bookIDs`.
    func entries(inBooks bookIDs: Set<UUID>) -> [Entry] {
        let keys = Set(bookIDs.map(\.uuidString))
        return entries.filter { keys.contains($0.bookKey) }
    }
}

/// The result of one probe search. The keyword fallback needs `text`/`tags`
/// on the caller's rows, so the probe reports that the model declined the
/// query rather than reaching for them itself.
enum SemanticSearchOutcome: Sendable {
    case ranked([SemanticHit])
    case queryNotEmbeddable
}

/// Semantic search's reads, on their own executor.
///
/// `FlowResonanceProbe`/`WisdomProbe`'s shape exactly: a `@ModelActor` owns a
/// `ModelContext` confined to its own serial executor, every model read
/// happens there, and only plain `Sendable` values come back. One instance per
/// container for the life of the process (`SemanticVectorCache.probe(for:)`),
/// so its serial executor is also what stops two callers building the table
/// at once -- the second simply waits for the first.
///
/// Lives in this file rather than in its own because the project lists every
/// source file individually in `project.pbxproj` (no synchronised folder
/// groups), so a new file would not join the target without a project edit --
/// the same reason `FlowResonanceProbe` lives in `FlowView.swift`.
@ModelActor
actor SemanticSearchProbe {
    /// Embeds, ranks, returns. The inference (`EmbeddingService.embed`, its
    /// own locks, callable from any executor) runs here too, so a Library
    /// keystroke no longer pays a CoreML forward pass on the main actor.
    func search(query: String, scope: Set<UUID>, topK: Int) -> SemanticSearchOutcome {
        guard let queryVector = EmbeddingService.embed(query) else { return .queryNotEmbeddable }
        let table = SemanticVectorCache.shared.freshTable(for: modelContainer) ?? rebuildTable()
        return .ranked(SearchService.rankedHits(
            queryVector: queryVector, entries: table.entries(inBooks: scope), topK: topK))
    }

    /// Builds the table and publishes it to the cache under the generation
    /// that was current when the build began -- so a save that lands DURING
    /// the build marks the result stale rather than letting it stand.
    @discardableResult
    func rebuildTable() -> SemanticVectorTable {
        let generation = SemanticVectorCache.shared.currentGeneration()
        let table = buildTable()
        SemanticVectorCache.shared.store(table, builtAt: generation, for: modelContainer)
        return table
    }

    /// One indexed fetch per book, `id` and `embeddingData` columns only.
    ///
    /// Per book on purpose, and NOT `\.book` in `propertiesToFetch`: SwiftData
    /// documents `propertiesToFetch` for attributes, and reading a
    /// relationship off a partially fetched row may fault the rest of that row
    /// back in -- which would re-read the very blob this is trying to read
    /// once. `book?.id == bookID` walks the relationship's own index and
    /// yields the book id from the predicate, so no relationship is ever
    /// touched on a highlight. 156 fetches over 33k rows, once per build.
    ///
    /// Only highlights attached to a book are included -- the relationship
    /// pool (`books.flatMap(\.highlights)`) never contained an unsorted
    /// Share-Extension capture either.
    /// Internal, not private, so the parity test can build a table without
    /// publishing it to the process-wide cache.
    func buildTable() -> SemanticVectorTable {
        var bookDescriptor = FetchDescriptor<Book>()
        bookDescriptor.propertiesToFetch = [\.id]
        let books = (try? modelContext.fetch(bookDescriptor)) ?? []

        var entries: [SemanticVectorTable.Entry] = []
        for book in books {
            let bookID = book.id
            let bookKey = bookID.uuidString
            var descriptor = FetchDescriptor<Highlight>(
                predicate: #Predicate<Highlight> { $0.book?.id == bookID && $0.embeddingData != nil })
            descriptor.propertiesToFetch = [\.id, \.embeddingData]
            for highlight in (try? modelContext.fetch(descriptor)) ?? [] {
                guard let data = highlight.embeddingData else { continue }
                let vector = EmbeddingService.decodeVector(data)
                // The backfill's "tried, nothing to index" marker -- skipped
                // here exactly as the relationship pool skips it.
                guard !vector.isEmpty else { continue }
                entries.append(SemanticVectorTable.Entry(id: highlight.id, bookKey: bookKey, vector: vector))
            }
        }
        return SemanticVectorTable(entries: entries)
    }
}

/// Process-lifetime home of the decoded vector table, and the one place that
/// knows whether it is still true.
///
/// A lock-guarded value rather than actor state so the SYNCHRONOUS chat path
/// (`SearchService.semanticSearch(queryVector:books:)`, whose callers are
/// synchronous by design) can read the table without an `await`. Only
/// `SemanticSearchProbe` ever writes a table; everything else reads or
/// invalidates. `NSLock`, as `EmbeddingService`'s memo uses.
///
/// Freshness:
///   * `ModelContext.didSave` from ANY context in this process (the main
///     context, `SeedRunner`'s backfill, `AddHighlightView`) -- if the save
///     touched a `Highlight`, or the payload cannot say what it touched, the
///     table is stale and a rebuild is scheduled off-main after a short
///     debounce, so the chat path finds it warm again. Saves that touched
///     only other tables (a journal entry, a sleep session) are ignored:
///     `embeddingData` lives on `Highlight` alone.
///   * Cross-process writes (`CrossProcessSync`) never carry an embedding --
///     the Share Extension and the intents deliberately do not link
///     `EmbeddingService` -- so a capture from there enters the pool only when
///     this process's backfill embeds it, which is a `didSave` here.
///   * A memory warning drops the table outright; the next search rebuilds.
///   * Bound to one container: a table built from one store is never served
///     for another (the test target opens many in-memory containers).
final class SemanticVectorCache: @unchecked Sendable {
    static let shared = SemanticVectorCache()

    private struct State {
        var table: SemanticVectorTable?
        var tableGeneration = -1
        var containerID: ObjectIdentifier?
        var generation = 0
        var container: ModelContainer?
        var probe: SemanticSearchProbe?
        var rebuild: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var state = State()
    private var observers: [NSObjectProtocol] = []

    /// How long after the last Highlight-touching save the rebuild waits.
    /// The embedding backfill saves in batches; this folds a burst of them
    /// into one build.
    static let rebuildDebounce: Duration = .seconds(2)

    private init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: nil
        ) { [weak self] note in
            guard let self, Self.touchesHighlights(note) else { return }
            self.invalidate(rebuildAfter: Self.rebuildDebounce)
        })
        #if canImport(UIKit)
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.dropTable()
        })
        #endif
    }

    /// The one probe for this container, created on first use.
    func probe(for container: ModelContainer) -> SemanticSearchProbe {
        lock.lock(); defer { lock.unlock() }
        if let probe = state.probe, state.containerID == ObjectIdentifier(container) { return probe }
        let probe = SemanticSearchProbe(modelContainer: container)
        state.probe = probe
        state.container = container
        state.containerID = ObjectIdentifier(container)
        return probe
    }

    /// The table, only if it was built from THIS container and nothing has
    /// invalidated it since. `nil` means "rank the old way and warm".
    func freshTable(for container: ModelContainer) -> SemanticVectorTable? {
        lock.lock(); defer { lock.unlock() }
        guard state.containerID == ObjectIdentifier(container),
              state.tableGeneration == state.generation else { return nil }
        return state.table
    }

    func currentGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        return state.generation
    }

    /// Publishes a built table. Ignored -- and a rebuild rescheduled -- if the
    /// store changed while it was being built.
    func store(_ table: SemanticVectorTable, builtAt generation: Int, for container: ModelContainer) {
        lock.lock()
        // A build for a container the cache has since moved off (only the
        // test target ever has more than one) is dropped, not rescheduled.
        guard state.containerID == ObjectIdentifier(container) else { lock.unlock(); return }
        let stillCurrent = generation == state.generation
        if stillCurrent {
            state.table = table
            state.tableGeneration = generation
        }
        lock.unlock()
        if !stillCurrent { warm(using: container) }
    }

    /// Kicks an off-main build if the table is missing or stale and none is
    /// already in flight. Safe to call on every search; a no-op when warm.
    /// `nil` (a book with no context -- unsaved test objects) does nothing.
    func warm(using container: ModelContainer?) {
        guard let container else { return }
        lock.lock()
        if state.containerID != ObjectIdentifier(container) {
            // A different store: nothing built so far applies to it.
            state.probe = nil
            state.table = nil
            state.tableGeneration = -1
            state.generation += 1
            state.rebuild?.cancel()
            state.rebuild = nil
        }
        state.container = container
        state.containerID = ObjectIdentifier(container)
        let isFresh = state.table != nil && state.tableGeneration == state.generation
        let inFlight = state.rebuild != nil
        lock.unlock()
        guard !isFresh, !inFlight else { return }
        scheduleRebuild(after: .zero)
    }

    /// Marks the table stale. Reads fall back to the relationship pool until
    /// the rebuild lands.
    func invalidate(rebuildAfter delay: Duration) {
        lock.lock()
        state.generation += 1
        state.rebuild?.cancel()
        state.rebuild = nil
        let hasContainer = state.container != nil
        lock.unlock()
        guard hasContainer else { return }
        scheduleRebuild(after: delay)
    }

    private func dropTable() {
        lock.lock()
        state.generation += 1
        state.table = nil
        state.tableGeneration = -1
        state.rebuild?.cancel()
        state.rebuild = nil
        lock.unlock()
    }

    private func scheduleRebuild(after delay: Duration) {
        lock.lock()
        guard state.rebuild == nil, let container = state.container else { lock.unlock(); return }
        let probe = state.probe ?? SemanticSearchProbe(modelContainer: container)
        state.probe = probe
        let task = Task.detached(priority: .utility) { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            // Not during a seed merge: the same guard every reader of the
            // library carries (`LibraryView.refreshSemanticResults`,
            // `WisdomGraphView.loadCounts`). Try again once it is over.
            if await MainActor.run { SeedingStatus.shared.isSeeding } {
                self?.finishRebuild()
                self?.scheduleRebuild(after: Self.rebuildDebounce)
                return
            }
            await probe.rebuildTable()
            self?.finishRebuild()
        }
        state.rebuild = task
        lock.unlock()
    }

    private func finishRebuild() {
        lock.lock()
        state.rebuild = nil
        lock.unlock()
    }

    /// Whether a `ModelContext.didSave` payload names a `Highlight`.
    ///
    /// Defensive about the payload's shape on purpose: the identifiers are
    /// read under both the enum key and its raw string, as an array or a set,
    /// and a payload that carries no identifier lists at all -- or says every
    /// identifier was invalidated -- is treated as touching highlights. A
    /// needless rebuild costs background time; a missed one serves a stale
    /// pool.
    static func touchesHighlights(_ note: Notification) -> Bool {
        guard let info = note.userInfo else { return true }
        if identifiers(in: info, for: .invalidatedAllIdentifiers) != nil { return true }
        var sawAnyKey = false
        for key in [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers] {
            guard let ids = identifiers(in: info, for: key) else { continue }
            sawAnyKey = true
            if ids.contains(where: { $0.entityName == "Highlight" }) { return true }
        }
        return !sawAnyKey
    }

    private static func identifiers(in info: [AnyHashable: Any], for key: ModelContext.NotificationKey) -> [PersistentIdentifier]? {
        let value = info[key] ?? info[key.rawValue]
        if let array = value as? [PersistentIdentifier] { return array }
        if let set = value as? Set<PersistentIdentifier> { return Array(set) }
        return nil
    }
}
