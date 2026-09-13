import SwiftUI
import SwiftData

/// Which books the *browsing* surfaces are allowed to draw from — Flow's feed
/// and the Wisdom Graph, which are the two places the app hands you content
/// you didn't ask for by name.
///
/// One filter, deliberately, not one per feature. This started as Flow's own
/// book picker; the Wisdom Graph needed the identical scoping and the obvious
/// move — a second, parallel exclusion set — would have been a bug wearing a
/// feature's clothes. Switching a book off in one place and still meeting it
/// in the other reads as the setting being broken, and nothing about "this
/// book isn't what I want handed to me" is Flow-specific. Quiz, Chat and
/// Search are untouched: you reach those having already named a book, so
/// scoping them would be hiding content someone explicitly asked for.
///
/// Two sets, not one, because a book can be in three states and a single set
/// can only express two:
///
/// - **explicitly excluded** — someone switched it off. Always wins.
/// - **explicitly included** — someone switched a default-off book back on.
///   Sticky, so it survives adding more books later.
/// - **neither** — the default, which is on for ordinary books and off for
///   the profiles `BookContentProfile.startsExcludedFromBrowsing` covers.
///
/// The exclusion set is still an exclusion set rather than an inclusion list,
/// for the original reason: a book added next month has to be included
/// automatically without anyone remembering to opt it in. An inclusion list
/// would silently hide every future book.
///
/// Both persist in `UserDefaults` as comma-joined UUID strings, matching the
/// `@AppStorage`-key pattern every other preference in the app uses
/// (`themePreference`, `reviewNudgeEnabled`, …) rather than introducing a
/// SwiftData model for what is one small device-local setting.
enum BookSourceFilter {
    /// Unchanged from when this was `FlowBookFilter` — the key is renamed
    /// nowhere on purpose. Anyone who has already switched books off keeps
    /// those choices across this update; renaming it would silently reset
    /// them, which is exactly the kind of quiet data loss a rename should
    /// never cause.
    static let excludedKey = "flowExcludedBookIDs"

    /// Books switched back ON that would otherwise start off by profile.
    static let includedKey = "bookSourceIncludedBookIDs"

    static func decode(_ raw: String) -> Set<UUID> {
        guard !raw.isEmpty else { return [] }
        return Set(raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    /// Sorted so the stored string is stable for a given set — an unordered
    /// `Set` would otherwise rewrite the default (and re-fire every
    /// `@AppStorage` observer) on writes that changed nothing.
    static func encode(_ ids: Set<UUID>) -> String {
        ids.map(\.uuidString).sorted().joined(separator: ",")
    }

    /// The set the browsing surfaces actually filter on: explicit choices
    /// plus whatever the content profiles switch off by default.
    ///
    /// A library with no default-off books returns exactly the explicit
    /// exclusions — byte-identical to the behaviour before profiles were
    /// consulted at all, so a library of ordinary books cannot notice this
    /// code exists.
    static func effectiveExcludedIDs(
        books: [Book],
        excludedRaw: String,
        includedRaw: String
    ) -> Set<UUID> {
        let explicitlyExcluded = decode(excludedRaw)
        guard !books.isEmpty else { return explicitlyExcluded }

        let explicitlyIncluded = decode(includedRaw)
        let defaultExcluded = Set(
            books.lazy
                .filter { $0.contentProfile.startsExcludedFromBrowsing && !explicitlyIncluded.contains($0.id) }
                .map(\.id)
        )
        guard !defaultExcluded.isEmpty else { return explicitlyExcluded }

        let combined = explicitlyExcluded.union(defaultExcluded)

        // Someone whose whole library is reference texts must not open Flow
        // to an empty screen they never asked for. A default that empties the
        // feed is a bug, not a preference, so it yields entirely — while an
        // explicit "I switched everything off" is left alone, because that
        // one really was asked for and has its own honest empty state.
        if combined.count >= books.count && explicitlyExcluded.count < books.count {
            return explicitlyExcluded
        }
        return combined
    }

    /// Whether a single highlight survives the filter — the one definition of
    /// that question, so the Wisdom Graph's grid, its counts and its detail
    /// screens cannot drift apart on it.
    ///
    /// A highlight with no book attached is never hidden. An orphan is a data
    /// repair concern, not a filtering decision, and quietly swallowing it here
    /// would make it that much harder to ever notice.
    static func isVisible(_ highlight: Highlight, excluding excludedBookIDs: Set<UUID>) -> Bool {
        guard let book = highlight.book else { return true }
        return !excludedBookIDs.contains(book.id)
    }

    /// For non-SwiftUI readers. Views should use `@AppStorage` on both keys so
    /// changes actually re-render.
    static func effectiveExcludedIDs(books: [Book]) -> Set<UUID> {
        effectiveExcludedIDs(
            books: books,
            excludedRaw: UserDefaults.standard.string(forKey: excludedKey) ?? "",
            includedRaw: UserDefaults.standard.string(forKey: includedKey) ?? ""
        )
    }
}

/// The picker itself: one row per book, on = Flow and the Wisdom Graph may use
/// it. Reachable from Flow's own top bar (Rajan asked for "an option in flow"),
/// from the Wisdom Graph's menu, and from Settings — all three writing the same
/// two keys.
struct BookSourceFilterView: View {
    @Query(sort: \Book.title) private var books: [Book]
    @AppStorage(BookSourceFilter.excludedKey) private var excludedRaw: String = ""
    @AppStorage(BookSourceFilter.includedKey) private var includedRaw: String = ""

    private var effectiveExcluded: Set<UUID> {
        BookSourceFilter.effectiveExcludedIDs(books: books, excludedRaw: excludedRaw, includedRaw: includedRaw)
    }

    /// Everything `body` needs about the current filter, in ONE pass over the
    /// library rather than one pass per question and one more per row.
    ///
    /// `effectiveExcludedIDs` decodes two comma-joined UUID strings and reads
    /// `contentProfileRaw` on every `Book`. `body` reached it four ways --
    /// `allExcluded`, the "Include All Books" test, `footerText`'s
    /// `hasDefaultOffBooks`, and, worst, `binding(for:)`'s GETTER, which runs
    /// once per row. On 156 books that is roughly 159 full scans of the library
    /// to draw one list of toggles, and it is the list Flow, Wisdom and
    /// Settings all open.
    private struct FilterState {
        var excluded: Set<UUID> = []
        var defaultOffIDs: Set<UUID> = []
        var bookCount = 0

        var allExcluded: Bool { bookCount > 0 && excluded.count >= bookCount }
        var hasDefaultOffBooks: Bool { !defaultOffIDs.isEmpty }
    }

    private func makeFilterState() -> FilterState {
        FilterState(
            excluded: effectiveExcluded,
            defaultOffIDs: Set(books.lazy
                .filter { $0.contentProfile.startsExcludedFromBrowsing }
                .map(\.id)),
            bookCount: books.count)
    }

    private func footerText(_ state: FilterState) -> String {
        let base = "Flow and the Wisdom Graph only draw on the books switched on here. Any book you add later joins automatically."
        guard state.hasDefaultOffBooks else { return base }
        return base + "\n\nReference textbooks start switched off. They carry many times more highlights than an ordinary book, so leaving them on crowds out everything else. Switch one on any time to get it back in both places."
    }

    var body: some View {
        let state = makeFilterState()
        Form {
            // Both of these sit ABOVE the book list, not below it. They used to
            // follow it, which meant that on a real library (26 books and
            // growing) the one control that fixes an over-filtered state — and
            // the warning explaining why you'd want it — were only reachable by
            // scrolling past every book to the very bottom. The warning comes
            // first because it's what makes the button underneath it make sense.
            if state.allExcluded {
                // Not blocked — just told the truth about what it does. Flow's
                // own empty state says the same thing and links back here.
                CobuxFormSection(title: "Heads Up") {
                    Label("Every book is switched off, so Flow and the Wisdom Graph have nothing to show. Switch at least one back on.", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.cobuxWarning)
                }
            }

            if !state.excluded.isEmpty {
                Section {
                    Button("Include All Books") { includeAll(defaultOffIDs: state.defaultOffIDs) }
                }
            }

            CobuxFormSection(
                title: "Books in Flow and Wisdom",
                footer: footerText(state)
            ) {
                if books.isEmpty {
                    Text("No books in your library yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(books) { book in
                        // The already-resolved set, not another whole-library
                        // scan inside every row's binding getter.
                        Toggle(isOn: binding(for: book, excluded: state.excluded)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(book.title)
                                Text(book.author)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if book.contentProfile.startsExcludedFromBrowsing {
                                    Text("Reference text — off by default")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Flow and Wisdom Sources")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: pruneDeletedBooks)
    }

    private func binding(for book: Book, excluded: Set<UUID>) -> Binding<Bool> {
        Binding(
            get: { !excluded.contains(book.id) },
            set: { included in
                var excluded = BookSourceFilter.decode(excludedRaw)
                var includedIDs = BookSourceFilter.decode(includedRaw)
                if included {
                    excluded.remove(book.id)
                    // Only default-off books need a sticky opt-in recorded;
                    // for an ordinary book, "on" is just the absence of an
                    // exclusion and storing anything would be noise.
                    if book.contentProfile.startsExcludedFromBrowsing {
                        includedIDs.insert(book.id)
                    }
                } else {
                    includedIDs.remove(book.id)
                    excluded.insert(book.id)
                }
                writeIfChanged(excluded: excluded, included: includedIDs)
            }
        )
    }

    /// Means every book, including the ones that start off by profile — so it
    /// has to record those opt-ins explicitly rather than just clearing the
    /// exclusion set, or the default would immediately switch them back off.
    private func includeAll(defaultOffIDs: Set<UUID>) {
        writeIfChanged(excluded: [], included: defaultOffIDs)
    }

    /// A deleted book's ID would otherwise sit in either set forever, and —
    /// worse — silently exclude a re-imported book that restored the same UUID
    /// from a backup. Guarded on a non-empty library so a @Query that hasn't
    /// loaded yet can't wipe the whole setting.
    private func pruneDeletedBooks() {
        guard !books.isEmpty else { return }
        let live = Set(books.map(\.id))
        writeIfChanged(
            excluded: BookSourceFilter.decode(excludedRaw).intersection(live),
            included: BookSourceFilter.decode(includedRaw).intersection(live)
        )
    }

    /// Writes only real changes, so a no-op pass can't re-fire every
    /// `@AppStorage` observer in the app.
    private func writeIfChanged(excluded: Set<UUID>, included: Set<UUID>) {
        let encodedExcluded = BookSourceFilter.encode(excluded)
        let encodedIncluded = BookSourceFilter.encode(included)
        if encodedExcluded != excludedRaw { excludedRaw = encodedExcluded }
        if encodedIncluded != includedRaw { includedRaw = encodedIncluded }
    }
}
