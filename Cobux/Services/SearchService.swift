import Foundation
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

    /// Builds the library context for the system prompt and reports which
    /// books were included, so replies can cite their sources.
    static func buildContext(query: String, books: [Book]) -> (context: String, bookTitles: [String]) {
        guard !books.isEmpty else {
            return ("No books in library yet.", [])
        }

        let queryLower = query.lowercased()

        let matchedBooks = books.filter { book in
            queryLower.contains(book.title.lowercased()) ||
            queryLower.contains(book.author.lowercased())
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
                    highlight.text.lowercased().contains(queryLower) ||
                    highlight.tags.contains { $0.lowercased().contains(queryLower) }
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
                    highlight.text.lowercased().contains(queryLower) ||
                    highlight.tags.contains { $0.lowercased().contains(queryLower) }
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
        return (context, citedTitles)
    }

    /// Same retrieval as `buildContext`, but splits the result into a STABLE
    /// prefix and a DYNAMIC suffix instead of one combined string, so the
    /// caller can mark the stable piece as an Anthropic prompt-cache
    /// breakpoint (`cache_control`) and avoid re-billing it on every message.
    ///
    /// The stable piece is every book's chapter summaries and key lessons,
    /// unconditionally — NOT gated by per-query relevance. This is a
    /// deliberate change from `buildContext`'s per-book behavior: chapter
    /// summaries were never part of citation logic for either large or small
    /// books (citation is driven entirely by highlight contribution below),
    /// so always including them doesn't change who gets cited — it just
    /// means this block is byte-identical across every question in a
    /// session (and across sessions, until the library itself changes),
    /// which is exactly what a cache breakpoint needs to actually hit. At
    /// reference-book scale this is also the single biggest resent-every-turn
    /// cost identified in this codebase (up to ~116 chapter summary/key-lesson
    /// lines across the two medical textbooks) — caching it is the main point.
    ///
    /// The dynamic piece keeps the EXACT existing per-query behavior:
    /// relevant small books' full highlight dumps, and large reference
    /// books' top-K ranked highlight chunks for this specific question — the
    /// part that genuinely must be recomputed per message. Citation logic
    /// (`bookTitles`) is unchanged from `buildContext`: small books cited
    /// whenever relevant, large books cited only when a ranked highlight
    /// from them actually made it into this turn's dynamic context.
    ///
    /// Only used by the main chat flow (`ChatView`) — the highest-volume,
    /// most cache-sensitive path ("repeated questions in one study
    /// session"). Other one-shot templates (Symposium, Decision
    /// Consultation, Ask Intent) keep using `buildContext` above unchanged.
    static func buildSplitContext(query: String, books: [Book]) -> (stableContext: String, dynamicContext: String, bookTitles: [String]) {
        guard !books.isEmpty else {
            return ("No books in library yet.", "", [])
        }

        var stable = "## User's Book Library — Chapter Map\n\n"
        for book in books where !book.chapters.isEmpty {
            stable += "### \"\(book.title)\" by \(book.author) — Chapter Summaries:\n"
            let sortedChapters = book.chapters.sorted { ($0.chapterNumber ?? 0) < ($1.chapterNumber ?? 0) }
            for chapter in sortedChapters {
                var chapterLine = "- \(chapter.title): \(chapter.summary)"
                if !chapter.keyLessons.isEmpty {
                    chapterLine += " | Key lessons: \(chapter.keyLessons.joined(separator: ", "))"
                }
                stable += chapterLine + "\n"
            }
            stable += "\n"
        }

        let queryLower = query.lowercased()

        let matchedBooks = books.filter { book in
            queryLower.contains(book.title.lowercased()) ||
            queryLower.contains(book.author.lowercased())
        }

        let semanticHits = semanticSearch(query: query, books: books, topK: 12)
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
        if Set(semanticBooks.map(\.id)).count < books.count {
            for book in books where !unionBooks.contains(where: { $0.id == book.id }) {
                let hasKeywordHit = book.highlights.contains { highlight in
                    highlight.text.lowercased().contains(queryLower) ||
                    highlight.tags.contains { $0.lowercased().contains(queryLower) }
                }
                if hasKeywordHit {
                    unionBooks.append(book)
                }
            }
        }

        let relevantBooks = unionBooks.isEmpty ? books : unionBooks

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
                    highlight.text.lowercased().contains(queryLower) ||
                    highlight.tags.contains { $0.lowercased().contains(queryLower) }
                }
                for highlight in keywordMatches.prefix(chunkTopK) {
                    chunkedHighlightIDs.insert(highlight.id)
                }
            }
        }

        var dynamic = "## Most Relevant Content for This Question\n\n"
        var referencedBookIDs = Set<UUID>()

        for book in relevantBooks {
            let isLargeBook = requiresRetrievalGating(book)
            let highlightsToShow = isLargeBook
                ? book.highlights.filter { chunkedHighlightIDs.contains($0.id) }
                : book.highlights

            if !highlightsToShow.isEmpty {
                dynamic += "## Book: \"\(book.title)\" by \(book.author)\n\n### Highlights:\n"
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

                // Matches `buildContext`'s citation rule exactly: a large book
                // is cited only when it actually contributed a ranked
                // highlight; a small book is always cited below regardless
                // (this branch only skips the "Highlights:" section header
                // when a small book happens to have zero highlights).
                if isLargeBook {
                    referencedBookIDs.insert(book.id)
                }
            }

            // Small books are cited whenever relevant, same as `buildContext`
            // — independent of whether they had any highlights to show.
            if !isLargeBook {
                referencedBookIDs.insert(book.id)
            }
        }

        if !relevantBooks.isEmpty && relevantBooks.count < books.count {
            let otherBooks = books.filter { book in
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
    /// book instead of applied across the library. Citation is trivial: a
    /// book-specific thread's replies are always about that one book, so
    /// there's nothing to disambiguate — callers shouldn't show a
    /// "referenced books" chip for this thread at all.
    static func buildSplitContextForBook(query: String, book: Book) -> (stableContext: String, dynamicContext: String) {
        var stable = "## Chapter Map — \"\(book.title)\" by \(book.author)\n\n"
        if !book.chapters.isEmpty {
            let sortedChapters = book.chapters.sorted { ($0.chapterNumber ?? 0) < ($1.chapterNumber ?? 0) }
            for chapter in sortedChapters {
                var chapterLine = "- \(chapter.title): \(chapter.summary)"
                if !chapter.keyLessons.isEmpty {
                    chapterLine += " | Key lessons: \(chapter.keyLessons.joined(separator: ", "))"
                }
                stable += chapterLine + "\n"
            }
            stable += "\n"
        }

        let isLargeBook = requiresRetrievalGating(book)
        var highlightsToShow: [Highlight]
        if isLargeBook {
            let rankedChunks = semanticSearch(query: query, books: [book], topK: chunkTopK)
            highlightsToShow = rankedChunks
            if highlightsToShow.isEmpty {
                let queryLower = query.lowercased()
                highlightsToShow = Array(book.highlights.filter { highlight in
                    highlight.text.lowercased().contains(queryLower) ||
                    highlight.tags.contains { $0.lowercased().contains(queryLower) }
                }.prefix(chunkTopK))
            }
        } else {
            highlightsToShow = book.highlights
        }

        var dynamic = "## Most Relevant Content for This Question\n\n"
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

        return (stable, dynamic)
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
