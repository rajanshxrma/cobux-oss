import Foundation
import SwiftData
import CobuxCore

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

        let queryTokens = significantTokens(query)

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
            let rankedChunks = semanticSearch(query: query, books: largeRelevantBooks, topK: chunkTopK)
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

            context += "## Book: \"\(book.title)\" by \(book.author)\n\n"

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
                    context += "- \"\(book.title)\" by \(book.author) (\(book.highlightCount) highlights, \(book.chapterCount) chapters)\n"
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
    static func buildSplitContext(
        query: String,
        books: [Book],
        personalWritingEntries: [PersonalWritingEntry] = [],
        includePersonalWriting: Bool = false,
        useRealNamesInLifeExamples: Bool = false
    ) -> (stableContext: String, dynamicContext: String, bookTitles: [String]) {
        guard !books.isEmpty else {
            return ("No books in library yet.", "", [])
        }

        let sortedBooks = books.sorted { $0.id.uuidString < $1.id.uuidString }

        var stable = "## User's Book Library — Chapter Index\n\n"
        for book in sortedBooks where !book.chapters.isEmpty {
            stable += "### \"\(book.title)\" by \(book.author) — Chapters:\n"
            let sortedChapters = book.chapters.sorted { ($0.chapterNumber ?? 0) < ($1.chapterNumber ?? 0) }
            for chapter in sortedChapters {
                stable += "- \(chapter.title)\n"
            }
            stable += "\n"
        }

        let queryTokens = significantTokens(query)

        let matchedBooks = sortedBooks.filter { book in
            queryMentions(book.title, queryTokens: queryTokens) ||
            queryMentions(book.author, queryTokens: queryTokens)
        }

        let semanticHits = semanticSearch(query: query, books: sortedBooks, topK: 12)
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
            let rankedChunks = semanticSearch(query: query, books: largeRelevantBooks, topK: chunkTopK)
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

        for book in relevantBooks {
            guard !budgetExhausted else { break }

            let isLargeBook = requiresRetrievalGating(book)
            let highlightsToShow: [Highlight] = isLargeBook
                ? book.highlights.filter { chunkedHighlightIDs.contains($0.id) }
                : Array(book.highlights.prefix(maxHighlightsPerBookInDynamicContext))

            var bookBlock = ""
            var contributedHighlights = false

            if !highlightsToShow.isEmpty {
                bookBlock += "## Book: \"\(book.title)\" by \(book.author)\n\n### Highlights:\n"
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
                    dynamic += "- \"\(book.title)\" by \(book.author) (\(book.highlightCount) highlights, \(book.chapterCount) chapters)\n"
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
        useRealNamesInLifeExamples: Bool = false
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
                let queryTokens = significantTokens(query)
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
        let queryTokens = significantTokens(query)
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
    static func personalWritingContextBlock(query: String, entries: [PersonalWritingEntry], useRealNames: Bool) -> String {
        let ranked = relevantPersonalWriting(query: query, entries: entries, topK: personalWritingTopK)
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
        block += "Where one of these excerpts genuinely parallels the question, you may briefly weave it in as a lived example alongside the books (\"something similar shows up in your own journal…\"). Use at most one such example per reply, only when it truly fits — most replies should not need one. "
        block += useRealNames
            ? "You may refer to people from these excerpts by the names used there.\n\n"
            : "NEVER repeat personal names of private individuals from these excerpts — refer to people only by role or relationship (\"a friend\", \"someone you wrote about\"), even if the excerpt names them.\n\n"
        for entry in ranked {
            let excerpt = entry.text.count > personalWritingExcerptCharLimit
                ? String(entry.text.prefix(personalWritingExcerptCharLimit)) + "…"
                : entry.text
            block += "- [\(entry.source)] \"\(entry.title)\": \(excerpt)\n"
        }
        block += "\n"
        return block
    }

    /// Journal-thread retrieval caps -- deliberately much roomier than the
    /// aside injection above (`personalWritingTopK` 3 × 400 chars): there the
    /// journal is supplementary color on a book answer, here it is the entire
    /// grounding. 8 × 1200 ≈ 10k chars worst case, well inside a prompt.
    static let journalThreadTopK = 8
    static let journalThreadEntryCharLimit = 1200

    /// Builds the "My Journal" chat thread's context block (see
    /// `PromptTemplates.journalGrounded`): the most relevant entries, each
    /// prefixed with its date so "what was I writing about in March?" is
    /// answerable as a date question, not just a similarity one.
    ///
    /// Retrieval is `relevantPersonalWriting`'s embedding ranking with two
    /// journal-specific layers on top, both soft so the thread never comes up
    /// empty while entries exist:
    /// - a month mentioned in the query ("March") narrows the pool to that
    ///   month's entries first, because cosine similarity between the word
    ///   "march" and what was actually written that March is near noise --
    ///   the date metadata, not the text, is what answers a period question;
    /// - when ranking returns nothing (query can't be embedded and matches no
    ///   substring), the most recent entries stand in, so a vague "how have I
    ///   been doing lately?" still gets real grounding.
    ///
    /// No privacy gate here, unlike `personalWritingContextBlock`'s caller
    /// contract: the aside toggle governs journal excerpts leaking into BOOK
    /// answers, while this runs only for the thread whose stated purpose is
    /// the journal, itself behind the journal's Face ID lock in `ChatView`.
    static func buildJournalContext(query: String, entries: [PersonalWritingEntry]) -> String {
        guard !entries.isEmpty else {
            return "(The journal has no entries yet. Say so plainly if asked about its contents.)\n"
        }

        var pool = entries
        if let month = monthMentioned(in: query) {
            let calendar = Calendar.current
            let matching = entries.filter {
                calendar.component(.month, from: $0.modifiedDate ?? $0.dateImported) == month
            }
            if !matching.isEmpty { pool = matching }
        }

        var ranked = relevantPersonalWriting(query: query, entries: pool, topK: journalThreadTopK)
        if ranked.isEmpty {
            ranked = Array(
                pool.sorted { ($0.modifiedDate ?? $0.dateImported) > ($1.modifiedDate ?? $1.dateImported) }
                    .prefix(journalThreadTopK)
            )
        }

        var block = ""
        for entry in ranked.sorted(by: { ($0.modifiedDate ?? $0.dateImported) < ($1.modifiedDate ?? $1.dateImported) }) {
            let date = (entry.modifiedDate ?? entry.dateImported)
                .formatted(.dateTime.month(.wide).day().year())
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

        var entriesByID: [String: PersonalWritingEntry] = [:]
        var items: [RankableItem] = []
        items.reserveCapacity(entries.count)
        for entry in entries {
            guard let vector = entry.embedding else { continue }
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

        let allHighlights = books.flatMap(\.highlights)

        guard let queryVector = EmbeddingService.embed(trimmedQuery) else {
            let queryLower = trimmedQuery.lowercased()
            return Array(
                allHighlights.filter { highlight in
                    highlight.text.lowercased().contains(queryLower) ||
                    highlight.tags.contains { $0.lowercased().contains(queryLower) }
                }
                .prefix(topK)
            )
        }

        var highlightsByID: [String: Highlight] = [:]
        var items: [RankableItem] = []
        items.reserveCapacity(allHighlights.count)
        for highlight in allHighlights {
            guard let vector = highlight.embedding else { continue }
            let idString = highlight.id.uuidString
            highlightsByID[idString] = highlight
            items.append(RankableItem(
                id: idString,
                bookID: highlight.book?.id.uuidString ?? "unknown",
                rawScore: EmbeddingService.cosineSimilarity(queryVector, vector)
            ))
        }

        return Ranker.rank(items: items, topK: topK).compactMap { highlightsByID[$0.id] }
    }
}
