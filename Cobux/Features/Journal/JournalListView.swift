import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The feed's vertical scale, written down once.
///
/// Rajan on build 52: "the spacing here bewten saved jounals entries and the
/// font and overall looks ugly and not claen and simple and sleak". The spacing
/// half of that was not one bad number, it was three numbers that nobody had
/// ever set together -- 8pt row insets, a 20pt header padding, and the plain
/// `List`'s own undocumented header inset stacked on top. Whatever that summed
/// to on his phone read as two blank lines between one day and the next, which
/// is what turned a diary into a row of islands.
///
/// Three steps, ordered by how closely two things belong to each other. Nothing
/// in the feed sets a vertical gap that is not one of these.
enum JournalFeedRhythm {
    /// A day's header and the first card under it: the tightest pair on the
    /// screen, because the header is that card's date, not a divider above it.
    static let headerToCard: CGFloat = 6
    /// Two entries written on the same day. Separate objects, one day.
    static let betweenCards: CGFloat = 10
    /// The last card of one day and the next day's header -- the only break in
    /// the feed that is a real change of subject, so it is the only large one.
    static let betweenDays: CGFloat = 22

    // ------------------------------------------------------- the head
    //
    // The same scale, extended upward over the tip card, the streak line, the
    // calendar and the archive card. Before this the head had no scale at all:
    // seven or eight elements each carrying whatever padding it happened to
    // bring, which is what he was looking at -- *"look this lok congested up
    // aread then space witht the from your archive elises too muc then journal
    // entries. its assyemtrical spacing and looks out of palce and not
    // consistent."*
    //
    // Three numbers govern the whole screen now. Parts of ONE object sit at
    // `withinObject`; one head object to the next sits at `betweenObjects`;
    // and the head to the feed sits at `betweenDays`, because that is the same
    // kind of break as one day to the next -- a change of subject.

    /// The month header, its stats line and its bars are one object. So are a
    /// card and its page dots.
    static let withinObject: CGFloat = 6
    /// The tip card, the calendar, the archive card -- separate objects, and
    /// the gap has to read as clearly larger than `withinObject` or the head
    /// looks like one undifferentiated stack, which is exactly what it looked
    /// like.
    static let betweenObjects: CGFloat = 18
}

/// The ground the journal is read on, in one place so the feed and the page it
/// opens cannot drift apart.
///
/// Rajan, on build 55: *"I like how Journal has a little bit of a red tint when
/// we have the light theme but whenever I turn into the dark theme, the tint
/// goes away and Journal is just like it just kinda is black. There's nothing,
/// no tint in the background too, so I want something there as well."*
///
/// He is describing something real and slightly counter-intuitive. The light
/// warmth he likes is not painted by the ground at all -- `CobuxBackground` is a
/// near-white -- it is the MONTH HUE, which the calendar bars, the day numerals,
/// the day threads and the archive card's wash all carry, and which in September
/// is a rust red. Over white those hues read; over the near-black dark ground
/// the same washes land at a couple of percent of luminance and simply vanish.
/// So dark mode lost the entire chromatic layer of the screen, and "just kinda
/// is black" is a precise description of what is left.
///
/// The answer is `CobuxAtmosphere` -- the design system's existing living
/// background, the same component Ebb and Chat use -- washed in `cobuxCrimson`.
///
/// At `.ground`, not `.reading`. Build 57 shipped `.reading` here and he saw
/// nothing: "i dont relly see what dark mode warm tint theres none." `.reading`
/// is 0.10 of the accent, tuned on white; over near-black it is a slightly
/// different black. `.ground` is the strength added for exactly this screen --
/// 0.26 at the top stop in dark -- and the reason it is a new strength rather
/// than a stronger `.reading` is measured in `CobuxAtmosphere`'s doc comment:
/// Ebb sets small month-hue type on `.reading`, and 0.30 there would have
/// halved that pairing's already-failing contrast.
///
/// Two decisions worth stating, because both could reasonably have gone the
/// other way:
///
/// - **Crimson, not the month hue.** The month hue would echo the rest of the
///   screen, but it is only red in autumn; in March the journal would open
///   green, which is not what he asked for and does not sit with a ground whose
///   own value is a warm red-black by deliberate choice. Crimson is the 3.0
///   identity's lead colour on exactly this ground, so this makes the cast the
///   ground already has visible rather than introducing a new hue.
/// - **Dark only.** Light mode is the half he likes, and adding a crimson wash
///   there would put a second hue system beside the month hues it already
///   carries -- the "three doors in three hues" defect this codebase names
///   elsewhere. In dark mode there is no competing layer to collide with,
///   because that is the whole complaint.
///
/// Measured before it was written, with `CobuxColor.swift`'s own arithmetic:
/// against the washed ground at the 0.26 top stop, `CobuxInk` reads 13.2:1
/// (was 17.5 flat) and `CobuxMuted` 4.59:1 (was 6.08) -- above the 7:1 and
/// 4.5:1 floors `scripts/check-contrast.py` holds them to, and 0.26 is the
/// strongest stop at which Muted still clears. The wash itself is 1.32:1
/// against the flat ground (0.10 was 1.06:1 -- the number that says why he
/// could not see it). The card surface sits close to the washed ground, which
/// sounds alarming and is not: flat, it was already 1.05:1, because a
/// dark-mode journal card has never been separated from its ground by fill.
/// It is separated by the hairline `JournalEntryCard` draws for exactly this
/// reason.
struct JournalGround: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .dark {
            CobuxAtmosphere(accent: Color.cobuxCrimson, strength: .ground)
        } else {
            Color.cobuxBackground
        }
    }
}

/// A real browsing surface for `PersonalWritingEntry` -- until now this data
/// existed only as a bare count row in Settings ("Personal Writing Entries:
/// 12") with no way to actually read a single one back. Shows every entry
/// regardless of `source`: an entry composed here via `JournalEntryComposeView`
/// and one imported from Notes are the same kind of thing to a user going
/// through "my journal," even though they're tagged differently for chat's
/// own citation purposes.
///
/// Redesigned (2.5.13) toward Apple's own Journal app's visual language:
/// date-grouped sections instead of one flat list, a `BookCard`-style
/// photo-forward card for any entry with an attachment, and
/// `CobuxTypography.display()`'s serif face for text-only entries instead of
/// stock system type -- reusing this codebase's own existing photo-card and
/// typography patterns rather than inventing new visual language.
struct JournalListView: View {
    /// Opens the compose sheet on arrival, for entry points whose whole intent
    /// is "let me write right now" -- the Journal widget's write tap and the
    /// `cobux://journal/new` deep link. Defaults false so the ordinary More →
    /// Journal tap is unchanged (land on the list, browse what's there).
    var startingNewEntry: Bool = false

    @Environment(\.modelContext) private var modelContext
    @Query private var entries: [PersonalWritingEntry]
    /// A bounded, day-stable sample of the library -- at most 150 standalone
    /// highlights -- only so the highlight card can pair his writing against
    /// it. This was `@Query private var libraryHighlights: [Highlight]`: the
    /// whole highlight table -- 32,125 highlights across 156 seed books
    /// (scripts/check-corpus-scale.py, build 52) -- materialised on the main
    /// actor every time the journal opened, consumed by nothing but a
    /// once-a-day 150-row sample. `loadLibrarySample()` now samples off the
    /// main actor and fetches only the winners here; the card's own
    /// `sampleLibrary` sees ≤150 rows and keeps every one (its stride is 1
    /// below 150), so what reaches the pairing is the same kind of thing it
    /// always was.
    @State private var libraryHighlights: [Highlight] = []
    /// Passages he chose to keep, for the threshold window's ladder.
    @Query private var journalKeeps: [JournalKeep]
    /// Identity, not a Bool. This was a plain `@State Bool` that nothing ever
    /// set back to `false` -- SwiftUI clears it when the sheet dismisses
    /// normally, but if a presentation is DROPPED (the documented hazard
    /// below: the lock gate swaps this subtree mid-flight) the flag stays
    /// latched at `true`. Re-asserting `true` on an already-`true` `@State`
    /// is not a change, so it publishes nothing and opens nothing -- and
    /// every subsequent tap for the rest of the session is a silent no-op.
    /// That is the reported bug: "the new entry button does not work. I have
    /// to open the app and its separate way for it to work."
    ///
    /// A fresh identity per tap is always a real state change, so a dropped
    /// presentation costs one tap instead of the whole session.
    @State private var composeSession: ComposeSession?
    /// Identity, not a Bool -- the same lesson `composeSession` records: a Bool
    /// latches after a dropped presentation and every later tap is a silent
    /// no-op.
    @State private var ebbSession: EbbSession?
    /// Identity, not a Bool, for the third time on this screen -- see
    /// `composeSession`. The type lives in `JournalCalendarBrowserView.swift`.
    @State private var calendarBrowserSession: JournalCalendarBrowserSession?
    /// Identity, not a Bool, for the push into `VolumesView` -- see
    /// `composeSession`. Pushed from two doors (the filter menu and the row
    /// under the calendar) via one `.navigationDestination(item:)`.
    @State private var volumesSession: VolumesSession?
    /// Identity, not a Bool, for the push into `PeopleView` -- the same two
    /// doors as Volumes (the filter menu and the row under the calendar),
    /// one `.navigationDestination(item:)`.
    @State private var peopleSession: PeopleSession?
    /// "Notice people in my journal" (Settings). Absent means ON. Off removes
    /// both doors and stops the pass; the rows stay, so turning it back on
    /// is instant (`docs/people-in-the-journal.md` §6).
    @AppStorage(JournalPeopleIndexer.enabledKey) private var peopleEnabled: Bool = true
    /// The entry a tapped card is opening. An id rather than the model, so the
    /// destination is a value the navigation stack can hold and the `@Model` is
    /// re-resolved on the main actor where it lives -- the same shape `HeldView`
    /// uses. Replaces the row's `NavigationLink`; see the row itself for why.
    @State private var openEntryID: UUID?
    /// A day the feed should jump to, recorded by a surface that has no scroll
    /// proxy of its own (Ebb is a fullScreenCover, presented outside the
    /// ScrollViewReader). The reader watches this and performs the jump.
    @State private var pendingJumpDay: Date?
    /// Today's pick, lifted out of the highlight card so Ebb can open on the
    /// same passage rather than computing a second, disagreeing one.
    @State private var todaysPick: JournalHighlightSelector.Pick?
    @State private var filter: JournalFilter = .all
    @Environment(\.colorScheme) private var colorScheme
    /// One-shot latch: `.task` can re-run (and `startingNewEntry` stays true
    /// for this view's whole lifetime), so without this, dismissing the sheet
    /// would immediately re-present it and trap the user in compose.
    @State private var didAutoOpenCompose = false
    @State private var showJournalImporter = false
    @State private var showAppleJournalImporter = false
    @State private var importToast: String?
    @State private var searchText = ""
    /// What the filter actually runs against. Trails `searchText` by 250ms:
    /// the audit measured the search filter as an O(whole-corpus)
    /// case-insensitive scan per keystroke -- twice, because two parts of the
    /// body read it -- which on years of writing is a stutter on every letter
    /// typed. Debounce turns that into one scan per pause, which is when a
    /// result can actually be read anyway.
    @State private var debouncedSearchText = ""
    @State private var searchDebounce: Task<Void, Never>?
    // A minimal, read-only echo of `JournalLocked`'s own lock check --
    // deliberately NOT the whole gate/auto-prompt mechanism (that stays
    // de-duplicated in `JournalLocked`), just enough to decide whether the
    // compose button should even be reachable. Hidden while locked: composing
    // a new entry wouldn't itself expose anything already written, but a
    // half-locked screen (content hidden, yet still able to add to it) reads
    // as broken rather than protected.
    @AppStorage(JournalLockStatus.enabledKey) private var lockEnabled = true
    @State private var lockStatus = JournalLockStatus.shared
    /// Armed by content, like the gate itself (`JournalLocked.armed`): an
    /// empty journal is never "locked", so the widget's deep link into compose
    /// (`.task(id: isLocked)` below) and the first-run screen's own New Entry
    /// both work on a fresh install without a Face ID demand for nothing.
    private var isLocked: Bool { lockEnabled && !entries.isEmpty && !lockStatus.isUnlocked }

    /// This screen's walkthrough hints, in priority order; exactly ONE shows
    /// per visit (see `CobuxFeatureTipHost`). Ebb first -- it is the pillar
    /// -- then the Messages extension, then writing back, then keeps while
    /// nothing is kept yet. A first visit used to stack the Ebb card AND the
    /// Messages card above the calendar; now it shows one, and the rest wait
    /// for later visits.
    private var journalTips: [CobuxTip] {
        var tips: [CobuxTip] = [.ebb, .messages, .writeBack]
        if journalKeeps.isEmpty { tips.append(.keeps) }
        return tips
    }

    /// `.messages` is the one tip with no natural retirement hook: every other
    /// tip is retired by a control the user presses (`ebb`, `writeBack`,
    /// `keeps`), but the Messages panel writes its entry in ANOTHER PROCESS, so
    /// nothing in this app is ever tapped. Without this the card could never
    /// leave the rotation -- permanent, un-retireable chrome, which is exactly
    /// the failure the "a tip retires when you use it" rule exists to prevent,
    /// and it only became visible once the slot stopped being dismissible.
    ///
    /// The evidence a person has used it is the entry itself: an entry whose
    /// source resolves to `.messages` can only have arrived through that panel.
    private func retireMessagesTipIfUsed() {
        guard !CobuxTip.messages.seen else { return }
        if entries.contains(where: { JournalSourceFamily(source: $0.source) == .messages }) {
            CobuxTip.messages.markUsed()
        }
    }

    /// `@Query`'s own sort descriptor only takes a single stored KeyPath, and
    /// the one date that actually matters for ordering -- "when did this
    /// happen" -- is `modifiedDate ?? dateImported` (an entry composed here
    /// has both equal; an imported one only reliably has `dateImported`, see
    /// `PersonalWritingEntry.modifiedDate`'s own doc comment on why it can be
    /// `nil`). Sorting in Swift over the unsorted `@Query` result is the same
    /// pattern `LibraryView.filteredBooks` already uses for the identical
    /// reason.
    private var sortedEntries: [PersonalWritingEntry] {
        entries.sorted { ($0.modifiedDate ?? $0.dateImported) > ($1.modifiedDate ?? $1.dateImported) }
    }

    /// A small menu rather than a screen: four states, no configuration, and
    /// it disappears back into the toolbar the moment it is not being used.
    enum JournalFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case photos = "Photos"
        case voice = "Voice"
        case imported = "Imported"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .all: "tray.full"
            case .photos: "photo"
            case .voice: "waveform"
            case .imported: "square.and.arrow.down"
            }
        }
    }

    private var filteredEntries: [PersonalWritingEntry] {
        var result = sortedEntries
        switch filter {
        case .all:
            break
        case .photos:
            result = result.filter { entry in
                entry.attachments.contains { !JournalAttachmentStore.isVoiceNote(id: $0.id) }
            }
        case .voice:
            result = result.filter { entry in
                entry.attachments.contains { JournalAttachmentStore.isVoiceNote(id: $0.id) }
            }
        case .imported:
            // Anything that did not originate in the composer -- Apple Notes,
            // Apple Journal, his writing folders, handwritten transcriptions.
            result = result.filter { $0.source != "journal" }
        }
        guard !debouncedSearchText.isEmpty else { return result }
        let query = debouncedSearchText
        return result.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.text.localizedCaseInsensitiveContains(query)
        }
    }

    /// The door into binding, as one quiet line. It USED to be a card at the
    /// very bottom of the feed, on the reasoning that a binder near the
    /// calendar would advertise daily. Rajan, build 57: "bind a volume
    /// feature is hidden at the bottom of all journals which is not good. It
    /// should be up top with the main section, maybe somewhere else in a
    /// little menu -- not a big deal." So it is both: an item in the filter
    /// menu, and this row beside "All months" under the calendar, in the same
    /// caption grammar. Still a pull door -- no count of volumes, no nudge to
    /// bind another; it exists, it never calls him.
    private var volumesDoor: some View {
        Button {
            // Opening Volumes is the feature being used, so More's hint about
            // it retires -- the same line `MoreView`'s Saved row draws.
            CobuxTip.boundVolumes.markUsed()
            volumesSession = VolumesSession()
        } label: {
            Label("Volumes", systemImage: "books.vertical")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.cobuxAccent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("A season of your writing, set as a book")
    }

    /// The door into People, beside Volumes, in the same caption grammar.
    /// Pull only: no count of people, no "new", nothing on this screen
    /// announces the section -- it waits to be looked for.
    private var peopleDoor: some View {
        Button {
            peopleSession = PeopleSession()
        } label: {
            Label("People", systemImage: "person.2")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.cobuxAccent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Who keeps appearing in your writing")
    }

    private struct DateSection: Identifiable {
        let id: Date
        let entries: [PersonalWritingEntry]
    }

    /// Newest section first, entries within a section newest first -- same
    /// `Dictionary(grouping:)` -> sort -> map shape `BookThreadPickerView`
    /// already establishes for its own category sections, just keyed by day
    /// instead of category.
    /// Entries per day, for the calendar's intensity bubbles. A count rather
    /// than a set of days: the calendar shades each day by how much was
    /// written, so presence alone isn't enough. Built off the unfiltered set on
    /// purpose -- the calendar shows your journaling history, which shouldn't
    /// shrink just because a search is narrowing the list.
    /// Per-day weight, not just presence. Entry COUNT caps out at three and
    /// then flattens everything above it, so one 2,000-word entry looked
    /// lighter than three one-liners. Words are the honest signal, and the
    /// calendar derives its tier thresholds from the spread of these.
    /// Cached, not recomputed on every render.
    ///
    /// This was a computed property, so SwiftUI rebuilt it on EVERY `body`
    /// evaluation -- every keystroke in the search field, every filter tap,
    /// every scroll update. Each rebuild split the full text of every entry to
    /// count words AND faulted the `attachments` relationship once per entry,
    /// across an archive going back to 2022. Nothing was broken; it was just
    /// slow, on the screen he opens most, in the interaction (typing) where
    /// slowness is most visible.
    ///
    /// His rule for this app: complex underneath, "very fast smooth simple" on
    /// top. Work whose result cannot change between two keystrokes must not be
    /// redone between two keystrokes.
    @State private var dayStats: [Date: JournalDayStat] = [:]

    /// Cheap change-detector for the cache above: entry count plus the newest
    /// modification date. It walks the entries but splits no text and faults no
    /// relationship, so it costs a small fraction of the real computation, and
    /// it moves whenever an entry is added, edited or imported.
    private var dayStatsSignature: String {
        let newest = entries
            .map { ($0.modifiedDate ?? $0.dateImported).timeIntervalSince1970 }
            .max() ?? 0
        return "\(entries.count)-\(newest)"
    }

    /// Must stay on the main actor: it reads SwiftData models bound to the main
    /// context, and reading those from another actor is the crash class this
    /// codebase has already paid for twice.
    @MainActor
    private func recomputeDayStats() {
        let calendar = Calendar.current
        dayStats = entries.reduce(into: [:]) { stats, entry in
            let day = calendar.startOfDay(for: entry.modifiedDate ?? entry.dateImported)
            var stat = stats[day] ?? JournalDayStat()
            stat.entries += 1
            stat.words += entry.text.split(whereSeparator: \.isWhitespace).count
            stat.seconds += entry.writingSeconds ?? 0
            stat.hasAttachment = stat.hasAttachment || !entry.attachments.isEmpty
            stats[day] = stat
        }
    }

    /// Samples the library for the highlight card WITHOUT materialising it.
    ///
    /// Off the main actor, on a throwaway context of the same container:
    /// `fetchIdentifiers` walks the table as identifiers, never as model
    /// objects; a day-seeded stride then visits ~450 candidates spread across
    /// the WHOLE library (books are inserted in blocks, so a contiguous window
    /// would sample one or two books rather than the shelf), faults each just
    /// far enough to test `readsStandalone`, and keeps the first 150 that
    /// pass. Only those ids return to the main actor, where they are fetched
    /// on the main context -- the card reads `highlight.book` there, and
    /// SwiftData models never cross actors. Same day seed as the card's own
    /// `sampleLibrary`, so the sample holds still for a day, as before.
    /// `@MainActor` for the same reason `recomputeDayStats` is: the final
    /// fetch and the `@State` write must happen where the main context lives.
    @MainActor
    private func loadLibrarySample() async {
        let container = modelContext.container
        let seed = Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
        let ids: [UUID] = await Task.detached(priority: .utility) { () -> [UUID] in
            let context = ModelContext(container)
            let all = FetchDescriptor<Highlight>(sortBy: [SortDescriptor(\.dateAdded)])
            guard let identifiers = try? context.fetchIdentifiers(all), !identifiers.isEmpty else { return [] }
            let stride = max(1, identifiers.count / 450)
            var index = seed % stride
            var sampled: [UUID] = []
            while index < identifiers.count, sampled.count < 150 {
                if let highlight = context.model(for: identifiers[index]) as? Highlight,
                   FlowQueueBuilder.readsStandalone(highlight.text) {
                    sampled.append(highlight.id)
                }
                index += stride
            }
            return sampled
        }.value
        guard !ids.isEmpty else { libraryHighlights = []; return }
        var winners = FetchDescriptor<Highlight>(predicate: #Predicate { ids.contains($0.id) })
        // The card reads `id`, `text` and `book` (title, tradition) -- never
        // `embeddingData`, whose 2 KB per row was ~300 KB of vectors fetched
        // onto the main actor for 150 rows that only ever show their text.
        // Should a later reader ask for the vector on one of these rows,
        // SwiftData faults it in lazily; nothing here is lost, only deferred.
        winners.propertiesToFetch = [\.id, \.text, \.dateAdded]
        winners.relationshipKeyPathsForPrefetching = [\.book]
        libraryHighlights = (try? modelContext.fetch(winners)) ?? []
    }

    private var dateSections: [DateSection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredEntries) { entry in
            calendar.startOfDay(for: entry.modifiedDate ?? entry.dateImported)
        }
        return grouped
            .sorted { $0.key > $1.key }
            .map { day, entries in
                DateSection(id: day, entries: entries)
            }
    }

    /// A journal-specific streak, deliberately separate from
    /// `StreakTracker.currentStreak` (the app-wide streak `MoreView`/
    /// `QuizHomeView` already show, fed by highlights and quizzes too) --
    /// Apple's own Journal app counts only journaling itself, and Rajan
    /// asked for that same read here. No new persistence: every entry's
    /// `modifiedDate ?? dateImported` is already loaded by this view's own
    /// `@Query`, so this is a pure derived value over data that already
    /// exists, cheap at the confirmed ~100-row scale this app runs at.
    ///
    /// Counts backward from today, but doesn't zero out the instant today
    /// has no entry yet -- same grace `StreakTracker.currentStreak` itself
    /// grants via its freeze bank: a streak that was alive through
    /// yesterday should still read as alive first thing this morning,
    /// before anyone's had the chance to write today's entry.
    /// Computed straight from `entries`, deliberately NOT from the cached
    /// `dayStats`.
    ///
    /// Reading the cache would be free, but the cache is empty on the very
    /// first render and fills a beat later -- and since the streak banner now
    /// appears above the calendar, that beat would pop the banner in and shove
    /// the whole feed down every time the journal opens. The expensive part of
    /// `dayStats` was splitting every entry's text and faulting its
    /// attachments; this walks the same entries but does neither, so it is
    /// cheap enough to be correct on the first frame instead.
    private var journalStreak: Int {
        let calendar = Calendar.current
        let days = Set(entries.map { calendar.startOfDay(for: $0.modifiedDate ?? $0.dateImported) })
        guard !days.isEmpty else { return 0 }

        let today = calendar.startOfDay(for: .now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return 0 }
        var cursor = days.contains(today) ? today : yesterday
        guard days.contains(cursor) else { return 0 }

        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    var body: some View {
        // `autoPromptsWhenTopmost: composeSession == nil && ebbSession == nil` -- while the compose
        // sheet is up, IT is the topmost visible screen, not this list
        // underneath it. Without this, backgrounding mid-compose would
        // relock and this list's own auto-prompt would pop a Face ID dialog
        // over the still-open compose sheet the user is actively typing in.
        //
        // `armed: !entries.isEmpty` -- the lock protects entries, and a
        // journal with none has nothing behind the gate. Before this the
        // first-run carousel sat inside a prompting gate, so a brand-new
        // install demanded Face ID to look at SAMPLE cards, and a cancelled
        // system sheet was answered with "That didn't work." That is the
        // first-run path a potential investor was shown. The lock arms the
        // moment the first entry exists.
        JournalLocked(autoPromptsWhenTopmost: composeSession == nil && ebbSession == nil
                                              && calendarBrowserSession == nil,
                      armed: !entries.isEmpty) {
            journalContent
                // Bottom-right, not the top-right toolbar -- reported live
                // as an awkward one-handed reach on a real phone. A plain
                // filled circle floating over the list, not a toolbar item,
                // is what actually lands in easy thumb range regardless of
                // device size.
                // Deliberate thumb-range FAB over a scrolling list; the
                // list scrolls its last row clear, and no fixed sibling
                // occupies this corner to collide with.
                // lint-ok: floating-tap-overlay -- deliberate FAB, see above
                .overlay(alignment: .bottomTrailing) {
                    // Hidden while the journal is empty. The annotation above
                    // claims no fixed sibling occupies this corner, and that is
                    // true of the LIST -- it scrolls its last row clear -- but
                    // false of the empty state, which centres its own text and
                    // its own New Entry button right here. Amal's first launch
                    // showed the FAB sitting on top of the last line of the
                    // explanation, cutting it off mid-sentence.
                    //
                    // It is also redundant there: the empty state already offers
                    // New Entry, larger and labelled.
                    if !isLocked && !entries.isEmpty {
                        Button {
                            // Logged because this path is only reproducible on a
                            // real device from a widget tap, and Diagnostics now
                            // ships in release builds -- so if it still fails, the
                            // log says whether the tap was even received.
                            DiagnosticLog.log("journal: new-entry tapped (locked=\(isLocked), startingNewEntry=\(startingNewEntry), autoOpened=\(didAutoOpenCompose))")
                            composeSession = ComposeSession()
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 56, height: 56)
                                .background(Color.cobuxAccent, in: Circle())
                                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                        }
                        .padding(20)
                    }
                }
        }
        .navigationTitle("Journal")
        .toolbar {
            // Ebb's permanent door.
            //
            // Every design in the panel made a dismissible card the sole
            // entrance, and that card renders nothing at all when it has been
            // dismissed or has no pick -- so the pillar would have been
            // unreachable exactly when he most wanted it. A door that always
            // exists, and never calls him.
            ToolbarItem(placement: .topBarTrailing) {
                // Not a regular toolbar icon on purpose. Rajan's reminder:
                // "rather than having like an icon to it, it should mention
                // something like EBB so that people could just click on
                // that... EBB is actually lost" -- the situations glyph
                // shipped its own colour (73c62ad) but a bare
                // `clock.arrow.circlepath` still reads as generic chrome
                // however it is tinted, because the name never renders. So
                // the name renders: a wordmark in Ebb's own teal, in a tinted
                // pill, the same "worth pressing" register as the Flow
                // button and the situations glyph rather than a plain icon
                // sharing the screen's default tint.
                // The name ALONE, all caps -- his second pass on this door:
                // "it should say EBB instead, because this will help user
                // actually click and see 'oh what is this ebb thing?! let me
                // see!'" A glyph explains nothing; an unexplained NAME is a
                // question the finger wants answered. Same wordmark grammar
                // as the EBB screen itself, so the door and the room match.
                Button { CobuxTip.ebb.markUsed(); ebbSession = EbbSession() } label: {
                    Text("EBB")
                        .font(.caption.weight(.bold))
                        .kerning(2.2)
                        .foregroundStyle(Color.cobuxEbb)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Color.cobuxEbb.opacity(0.14), in: Capsule())
                }
                .accessibilityLabel("Ebb, walk back through your writing")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Show", selection: $filter) {
                        ForEach(JournalFilter.allCases) { option in
                            Label(option.rawValue, systemImage: option.systemImage).tag(option)
                        }
                    }
                    // The "little menu" he named for the binder. Under the
                    // filters because it is the one item here that is not a
                    // filter; a `Divider` keeps that clear. The pill widens by
                    // nothing -- the menu already exists.
                    Divider()
                    Button {
                        CobuxTip.boundVolumes.markUsed()
                        volumesSession = VolumesSession()
                    } label: {
                        Label("Volumes", systemImage: "books.vertical")
                    }
                    if peopleEnabled {
                        Button {
                            peopleSession = PeopleSession()
                        } label: {
                            Label("People", systemImage: "person.2")
                        }
                    }
                } label: {
                    // The glyph fills in when a filter is active, so a narrowed
                    // list can never look like an empty journal.
                    Image(systemName: filter == .all
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel("Filter entries")
            }
        }
        // Presented from the view itself, not from inside `JournalLocked`'s
        // content. A sheet whose presenter sits under a gate that swaps its
        // subtree on every lock/unlock transition can lose the presentation
        // mid-flight -- the button sets the flag, the subtree rebuilds, and
        // nothing opens. Reported as: arriving from the Journal widget, "the
        // new entry button does not work. I have to open the app and its
        // separate way for it to work."
        // The types come from the importer itself, so the picker can never
        // again admit something the import cannot honestly read (`.text` let
        // RTF and HTML through as raw markup) or refuse something the
        // first-run copy promises (folders). The toast names every skipped
        // file and why -- an import creates permanent entries, so what it
        // declined must be as visible as what it took.
        .fileImporter(isPresented: $showJournalImporter,
                      allowedContentTypes: PersonalWritingImportService.supportedContentTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                Task {
                    let r = try? await PersonalWritingImportService.importPlainTextFiles(
                        urls: urls, modelContext: modelContext)
                    importToast = r.map(PersonalWritingImportService.fileImportSummary)
                        ?? "That didn't import. Pick a text, Markdown, RTF or HTML file, or a folder of them."
                }
            }
        }
        .fileImporter(isPresented: $showAppleJournalImporter,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task {
                    let r = try? await AppleJournalImportService.importFolder(at: url, modelContext: modelContext)
                    importToast = r.map { "Brought in \($0.imported) from Apple Journal." }
                        ?? "That didn't import — pick the unzipped export folder."
                }
            }
        }
        .alert("Import", isPresented: .init(get: { importToast != nil },
                                            set: { if !$0 { importToast = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(importToast ?? "") }
        // Declared out here on the gate's own view, beside the compose sheet and
        // for the identical reason: `JournalLocked` swaps its content subtree on
        // every lock/unlock transition, and a destination declared inside that
        // subtree goes with it mid-push. The detail view wraps itself in the
        // gate, so a relock while it is open is still handled.
        .navigationDestination(item: $openEntryID) { entryID in
            if let match = entries.first(where: { $0.id == entryID }) {
                JournalEntryDetailView(entry: match)
            }
        }
        // Out here beside the entry destination, for its reason: a destination
        // declared inside the gate's subtree is lost mid-push on a relock.
        .navigationDestination(item: $volumesSession) { _ in
            VolumesView()
        }
        .navigationDestination(item: $peopleSession) { _ in
            PeopleView()
        }
        .sheet(item: $composeSession) { session in
            if let target = session.answeringEntryID,
               let original = entries.first(where: { $0.id == target }) {
                JournalEntryComposeView(answering: .init(
                    entryID: original.id,
                    date: original.modifiedDate ?? original.dateImported,
                    dateIsCertain: original.modifiedDate != nil,
                    body: original.text,
                    month: Calendar.current.component(
                        .month, from: original.modifiedDate ?? original.dateImported)))
            } else {
                JournalEntryComposeView()
            }
        }
        // Out here beside the compose sheet, for the identical reason: a sheet
        // declared inside `JournalLocked`'s content can lose its presentation
        // when the gate swaps its subtree. The browser records where to land
        // rather than scrolling itself -- it has no scroll proxy, exactly like
        // Ebb. `filter` is cleared as well as the search: jumping to a day
        // whose section a live filter is hiding would scroll to nothing.
        .task { retireMessagesTipIfUsed() }
        .sheet(item: $calendarBrowserSession) { _ in
            JournalCalendarBrowserView(dayStats: dayStats) { day in
                searchText = ""
                filter = .all
                pendingJumpDay = day
            }
        }
        .fullScreenCover(item: $ebbSession) { _ in
            EbbView(entries: entries,
                    todaysPick: todaysPick,
                    onWrite: { composeSession = ComposeSession() },
                    onWriteBack: { entryID in
                        CobuxTip.writeBack.markUsed()
                        composeSession = ComposeSession(answeringEntryID: entryID)
                    }) { entryID in
                guard let match = entries.first(where: { $0.id == entryID }) else { return }
                searchText = ""
                filter = .all
                pendingJumpDay = Calendar.current.startOfDay(
                    for: match.modifiedDate ?? match.dateImported)
            }
        }
        // Arrived from the widget / `cobux://journal/new` -- go straight to
        // writing. Deliberately respects the lock: if Journal is locked, the
        // sheet waits rather than opening over a gate the user hasn't passed,
        // and `JournalLocked`'s own auto-prompt handles authentication first.
        // Recomputed only when the entries themselves actually change.
        .task(id: dayStatsSignature) { recomputeDayStats() }
        // The card's library sample: off-main, bounded, and re-drawn when
        // seeding finishes (an update launch seeds, and a sample taken during
        // it would be partial) or when the journal gains its first entry.
        .task(id: "\(SeedingStatus.shared.isSeeding)-\(entries.isEmpty)") {
            guard !entries.isEmpty else { libraryHighlights = []; return }
            await loadLibrarySample()
        }
        // A keep made anywhere -- the threshold card, Ebb -- is the feature
        // being used, so the hint retires itself. Observed here rather than
        // at each call site because the keeps table is the one truth.
        .onChange(of: journalKeeps.isEmpty) { _, isEmpty in
            if !isEmpty { CobuxTip.keeps.markUsed() }
        }
        .task(id: isLocked) {
            guard startingNewEntry, !didAutoOpenCompose, !isLocked else { return }
            DiagnosticLog.log("journal: auto-opening compose from deep link")
            composeSession = ComposeSession()
            // Consume the one-shot only once the sheet is genuinely up. Setting
            // it first meant a dropped auto-open was swallowed permanently:
            // the guard above would never let it retry.
            didAutoOpenCompose = composeSession != nil
        }
    }

    @ViewBuilder
    private var journalContent: some View {
        if entries.isEmpty {
            // Not a blank apology -- a preview of what the journal becomes,
            // with the real import paths as first-class actions. See
            // JournalFirstRunView for the iOS-honest reason it is
            // import-by-action, not silent sync.
            JournalFirstRunView(
                onNewEntry: { composeSession = ComposeSession() },
                onImportFile: { showJournalImporter = true },
                onImportAppleJournal: { showAppleJournalImporter = true })
        } else {
            ScrollViewReader { proxy in
            // Grouped ONCE per body pass. `dateSections` derives from
            // `filteredEntries`, which sorts every entry and then filters it --
            // and `body` reached that twice: once here for the feed, and again
            // in the empty-state overlay below as `filteredEntries.isEmpty`.
            // `Dictionary(grouping:)` never drops a row, so an empty grouping
            // and an empty filtered list are the same fact; asking the cheaper
            // one is exact, not an approximation.
            let sections = dateSections
            List {
                // The screen's ONE walkthrough hint rides above the calendar,
                // inside its row, so it sits in the feed's own rhythm rather
                // than floating as chrome -- and `journalTips` decides which of
                // this screen's tips it is.
                //
                // Placed DIRECTLY rather than through `.cobuxTip(firstOf:)`.
                // That modifier wraps its host in a `VStack(spacing: 12)`, and
                // 12 is a number from nowhere on this screen -- it is the one
                // gap in the head that would not have belonged to
                // `JournalFeedRhythm`, on the screen whose complaint was that
                // its spacing is inconsistent. Every other surface still uses
                // the modifier unchanged; the journal owns its own head.
                //
                // `bottomGap` rather than a `.padding` out here: the gap has to
                // travel with the card, or a journal with nothing left to teach
                // carries a permanent 18pt hole above its calendar. Same trap
                // `JournalHighlightCard` documents for the archive slot.
                Section {
                    CobuxFeatureTipHost(firstOf: journalTips,
                                        bottomGap: JournalFeedRhythm.betweenObjects)
                        .padding(.horizontal, CobuxSpacing.screenMargin)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    JournalCalendarStrip(dayStats: dayStats, streak: journalStreak,
                                         onBrowseMonths: {
                                             calendarBrowserSession = JournalCalendarBrowserSession()
                                         }) { day in
                        // Jump the list to that day's section -- the section
                        // ids ARE startOfDay dates, so the tapped bubble and
                        // its section share an identity by construction. A
                        // live search can be hiding the day's section
                        // entirely; clearing it first is what "go to that
                        // particular day" has to mean, and the tiny hop lets
                        // the unfiltered list exist before scrolling it.
                        searchText = ""
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(60))
                            withAnimation { proxy.scrollTo(day, anchor: .top) }
                        }
                    }
                    .padding(.horizontal, CobuxSpacing.screenMargin)

                    // The door to every month. Deliberately NOT a gesture on
                    // the bars: the strip's tap is jump-to-day, which he asked
                    // for three times and 52 finally fixed, and a long-press
                    // there is the gesture that already broke month paging
                    // once. A named door cannot steal either one. (The month's
                    // NAME on the strip now opens the same browser -- build 57,
                    // "clicking on a calendar ... should actually open a whole
                    // view of a big calendar" -- and this row stays as the
                    // labelled path, so there are two ways in and no guessing.)
                    // Volumes shares the row: two quiet doors, one line, the
                    // same caption grammar -- see `volumesDoor`.
                    HStack(spacing: 16) {
                        Button {
                            calendarBrowserSession = JournalCalendarBrowserSession()
                        } label: {
                            Label("All months", systemImage: "calendar")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.cobuxAccent)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        volumesDoor
                        if peopleEnabled { peopleDoor }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, CobuxSpacing.screenMargin)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                // Directly under the calendar, above the feed. Inside the lock
                // gate's subtree by position, which matters: it surfaces entry
                // content by design.
                Section {
                    JournalHighlightCard(entries: entries,
                                         highlights: libraryHighlights,
                                         keeps: journalKeeps,
                                         onPick: { todaysPick = $0 },
                                         onOpenEbb: { CobuxTip.ebb.markUsed(); ebbSession = EbbSession() },
                                         onWriteBack: { entryID in
                                             CobuxTip.writeBack.markUsed()
                                             composeSession = ComposeSession(answeringEntryID: entryID)
                                         }) { entryID in
                        guard let match = entries.first(where: { $0.id == entryID }) else { return }
                        searchText = ""
                        filter = .all
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(60))
                            withAnimation {
                                proxy.scrollTo(Calendar.current.startOfDay(
                                    for: match.modifiedDate ?? match.dateImported), anchor: .top)
                            }
                        }
                    }
                    .padding(.horizontal, CobuxSpacing.screenMargin)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                ForEach(sections) { section in
                    Section {
                        ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                            let excerpt = Self.preview(for: entry)
                            // A Button plus `.navigationDestination(item:)`, NOT a
                            // `NavigationLink` -- the same swap `HeldView` already
                            // made, for a different reason, forty lines from here.
                            //
                            // A `NavigationLink` inside a `List` is given a
                            // disclosure chevron by the list cell itself. It is not
                            // drawn by this view and it cannot be positioned by
                            // this view, so the corner rule written at the top of
                            // `CobuxRadius` -- a control in a rounded card's corner
                            // keeps its centre at least the radius in from both
                            // edges -- had no way to reach it. That is the same
                            // defect he reported on two other surfaces tonight:
                            // "the top corss here is weirdly palced formatted absed
                            // on the curve similarly the rigt arrow thingy here".
                            //
                            // It also cost the row real width: the cell narrows its
                            // content to make room for the accessory, so the entry
                            // cards ended a chevron's width short of the calendar
                            // and the threshold card stacked directly above them.
                            //
                            // Removed rather than relocated, and that IS the answer
                            // to the rule: a full-bleed card in a diary feed does
                            // not need an arrow to say it opens (Apple's own
                            // Journal draws none), the whole card is the target,
                            // and the cards now line up with everything above them.
                            Button {
                                openEntryID = entry.id
                            } label: {
                                JournalEntryCard(entry: entry,
                                                 preview: excerpt.text,
                                                 sessions: excerpt.sessions)
                            }
                            .buttonStyle(.plain)
                            // The day thread: a hairline in the leading margin
                            // joining cards written on the same day. It is the
                            // calendar's ink-run idea turned vertical, and it
                            // is what makes a multi-entry day read as one day
                            // rather than as unrelated rows.
                            .background(alignment: .leading) {
                                if section.entries.count > 1 {
                                    Rectangle()
                                        .fill(Color.cobuxMonthHue(
                                            Calendar.current.component(.month, from: section.id),
                                            dark: colorScheme == .dark).opacity(0.35))
                                        .frame(width: 1)
                                        .padding(.top, index == 0 ? 18 : 0)
                                        .padding(.bottom, index == section.entries.count - 1 ? 18 : 0)
                                        .offset(x: -10)
                                }
                            }
                            // The whole gap between two cards is paid on the
                            // BOTTOM, so every step in `JournalFeedRhythm` is one
                            // number in one place rather than two halves that have
                            // to be remembered together.
                            .listRowInsets(EdgeInsets(top: 0,
                                                      leading: CobuxSpacing.screenMargin,
                                                      bottom: JournalFeedRhythm.betweenCards,
                                                      trailing: CobuxSpacing.screenMargin))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        // A diary's margin date rather than a grey caps label:
                        // the day numeral large in that month's hue, the rest
                        // small beside it. The journal was the only screen in
                        // the app with no colour at all -- Library has cover
                        // colours, Flow has atmospheres -- which is a real part
                        // of why it read as dull.
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            // 18, not 22. At 22 the day numeral was larger than
                            // the entry titles beneath it, so the date outranked
                            // the writing. It stays the only colour on the
                            // screen -- keeping the month hue is deliberate,
                            // it's what the calendar strip is keyed to.
                            Text(Self.dayNumeral(section.id))
                                .font(CobuxTypography.display(colorScheme, size: 18, weight: .semibold))
                                .foregroundStyle(Color.cobuxMonthHue(
                                    Calendar.current.component(.month, from: section.id),
                                    dark: colorScheme == .dark))
                                .monospacedDigit()
                            Text(Self.weekdayAndMonth(section.id))
                                .font(.system(size: 11, weight: .semibold))
                                .textCase(.uppercase)
                                .kerning(0.8)
                                .foregroundStyle(.secondary)
                        }
                        .textCase(nil)
                        // The header's own row insets, rather than paddings on
                        // top of whatever a plain `List` gives a section header
                        // by default. That default was the missing term in the
                        // arithmetic: the gap between a card and the next day's
                        // header was `8 + <system header padding> + 20`, which
                        // nobody had written down and which came out at roughly
                        // two dead lines of text on his phone.
                        //
                        // Stating all four edges makes the three steps in
                        // `JournalFeedRhythm` the only numbers involved, and puts
                        // the header's text on exactly the same margin as the
                        // cards beneath it, which it was not before.
                        .listRowInsets(EdgeInsets(
                            top: JournalFeedRhythm.betweenDays - JournalFeedRhythm.betweenCards,
                            leading: CobuxSpacing.screenMargin,
                            bottom: JournalFeedRhythm.headerToCard,
                            trailing: CobuxSpacing.screenMargin))
                    }
                    // The calendar's jump target -- section ids are already
                    // startOfDay dates, the same key the strip's bubbles use.
                    .id(section.id)
                }

                // No binder card at the foot of the feed any more: the door
                // moved up beside "All months" and into the filter menu at
                // his request (see `volumesDoor`). A third copy here would be
                // the redundancy he called "not good".
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Performed HERE because this is where the proxy exists. Ebb is
            // presented as a fullScreenCover outside this reader, so it records
            // where to land rather than scrolling itself.
            .onChange(of: pendingJumpDay) { _, day in
                guard let day else { return }
                Task { @MainActor in
                    // The list must rebuild with the cleared filter before the
                    // target section exists to scroll to.
                    try? await Task.sleep(for: .milliseconds(120))
                    withAnimation { proxy.scrollTo(day, anchor: .top) }
                    pendingJumpDay = nil
                }
            }
            .background { JournalGround() }
            .searchable(text: $searchText, prompt: "Search your journal")
            .onChange(of: searchText) { _, newValue in
                searchDebounce?.cancel()
                // Clearing applies instantly -- an empty query costs nothing
                // and "results linger after I cleared the field" reads as
                // broken. Only typing is debounced.
                guard !newValue.isEmpty else {
                    debouncedSearchText = ""
                    return
                }
                searchDebounce = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    debouncedSearchText = newValue
                }
            }
            .overlay {
                if sections.isEmpty, !entries.isEmpty {
                    if !searchText.isEmpty {
                        CobuxEmptyStateView(icon: "magnifyingglass", title: "No matches",
                                            message: "Try a different search.")
                    } else if filter != .all {
                        // Never let an active filter read as "you have written
                        // nothing" -- name the filter and offer the way out.
                        CobuxEmptyStateView(icon: filter.systemImage,
                                            title: "No \(filter.rawValue.lowercased()) entries",
                                            message: "Nothing here matches this filter.") {
                            CobuxEmptyStateButton("Show all", systemImage: "tray.full") {
                                filter = .all
                            }
                        }
                    }
                }
            }
            }
        }
    }

    // The streak chip is gone: the streak now lives in the calendar's own
    // month line, so a returning reader sees it beside the month it belongs to
    // rather than as a badge floating above the feed.
    //
    // (The paragraph that used to sit here described `previewText` while
    // attached to the formatter below it -- a doc comment pointing at the wrong
    // symbol is a trap for the next reader, so it now lives on the extraction
    // itself, further down.)
    private static let dayNumeralFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d"; return f
    }()
    /// Two formatters, and which one runs is the whole point.
    ///
    /// The header used to be `"EEEE · MMMM"` unconditionally -- no year, in any
    /// branch -- so an entry from April 2023 and one from April 2025 both read
    /// "SUNDAY · APRIL" and could not be told apart. Against an archive going
    /// back to 2023 that is not a formatting nit, it is the feed losing the one
    /// fact that orders it. Rajan, on build 49: "one of the oldest journals but
    /// no dates to distinguish from tha fuck!!!!!"
    ///
    /// It survived a fix and a verification because `sectionLabel` -- which DID
    /// handle the year correctly -- was computed into `DateSection.label` and
    /// then never read by anything. Checking that function proved nothing about
    /// what the screen renders. It has been deleted rather than left to fool the
    /// next reader; this is now the only place a section header is formatted.
    private static let weekdayMonthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE · MMMM"; return f
    }()
    private static let weekdayMonthYearFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE · MMMM yyyy"; return f
    }()
    static func dayNumeral(_ date: Date) -> String { dayNumeralFormatter.string(from: date) }
    /// The year appears exactly when it carries information: never for this
    /// year (where it would repeat on every header), always for any other.
    static func weekdayAndMonth(_ date: Date) -> String {
        Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
            ? weekdayMonthFormatter.string(from: date)
            : weekdayMonthYearFormatter.string(from: date)
    }

    /// What a card shows, and how much of the entry that actually is.
    struct EntryPreview {
        /// The first sitting's writing, with every session stamp removed.
        let text: String
        /// How many sittings the whole entry holds. 1 for almost everything.
        let sessions: Int
    }

    /// The entry's first WRITING SESSION, without the stamp it opens with --
    /// plus how many sessions the entry holds in all.
    ///
    /// This used to strip only the opening stamp and hand back everything else,
    /// and that is the run-on card he reported: "Continue Entry" appends
    /// `"\n\n" + stamp + "\n"` to the SAME entry (see
    /// `JournalEntryComposeView.init`), so a day picked up again in the evening
    /// left a bare `9:01 AM` sitting in the middle of the excerpt with writing
    /// above and below it. On screen that reads as two entries crammed into one
    /// card with a floating timestamp between them -- which is exactly how he
    /// described it, and which is a rendering fault the eye catches before it
    /// reads a word of the writing.
    ///
    /// (Two entries genuinely written on one day were never the problem: they
    /// are two rows, so `dateSections` already gives them two cards. The defect
    /// was always ONE entry written twice.)
    ///
    /// So the excerpt is one sitting, the card says how many there are
    /// (`JournalEntryCard`'s footer), and the whole entry with its stamps in
    /// place is what the detail view is for. Nothing is hidden -- the card is
    /// one tap from all of it, and it now says so instead of implying it.
    static func preview(for entry: PersonalWritingEntry) -> EntryPreview {
        let lines = entry.text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return EntryPreview(text: entry.text, sessions: 1) }
        let opensWithStamp = isSessionStamp(first)

        var body: [Substring] = []
        // Later stamps seen, and which sitting the excerpt is taking. They are
        // usually both 0: the window only moves on when a sitting was opened and
        // nothing was typed in it, which must not leave the card blank.
        var laterStamps = 0
        var takingSitting = 0
        var hasWriting = false
        for line in lines.dropFirst(opensWithStamp ? 1 : 0) {
            if isSessionStamp(line) {
                laterStamps += 1
                if !hasWriting {
                    takingSitting = laterStamps
                    body.removeAll()
                }
                continue
            }
            guard laterStamps == takingSitting else { continue }
            body.append(line)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { hasWriting = true }
        }

        return EntryPreview(
            text: dropDuplicatedTitle(
                from: body.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                title: entry.title),
            sessions: laterStamps + 1)
    }

    /// Kept as the plain-string form for callers that only want the words --
    /// `JournalEntryComposeView`'s prompt chips. One extraction, two shapes.
    static func previewText(for entry: PersonalWritingEntry) -> String {
        preview(for: entry).text
    }

    /// The shared matcher with a cheap gate in front of it.
    ///
    /// `JournalSessionStamp.isStampLine` is a regular expression, and this now
    /// runs once per LINE of every visible entry, on the feed's render path. A
    /// stamp is always short and always carries a colon ("4:16 AM"); a paragraph
    /// of his writing is neither. `utf8.count` is a byte range on a `Substring`,
    /// so the common case -- a long prose line -- is rejected without scanning
    /// anything. The regex itself is untouched: one matcher, so a stamp that
    /// gains a ` · 72° · Berlin` tail keeps being recognised everywhere.
    private static func isSessionStamp(_ line: Substring) -> Bool {
        guard line.utf8.count <= 96, line.contains(":") else { return false }
        return JournalSessionStamp.isStampLine(line.trimmingCharacters(in: .whitespaces))
    }

    /// Drops a first line that just repeats the entry's own title.
    ///
    /// Imported notes take their title FROM their first line, so the card drew
    /// the same words twice -- once as the heading and again as the opening of
    /// the body ("when u" / "when u | when u can see how..."). Visible in his
    /// build-49 screenshot on every imported entry, and a large part of why the
    /// feed read as ugly: the eye reads the repeat as a rendering fault before
    /// it reads any of the writing.
    ///
    /// Only ever removes an EXACT match of the title line, so an entry that
    /// genuinely opens by restating its own heading in a longer sentence keeps
    /// every word the user wrote.
    static func dropDuplicatedTitle(from body: String, title: String) -> String {
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heading.isEmpty else { return body }
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == heading {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // There is deliberately NO delete path for a journal entry.
    //
    // His instruction, and the reasoning is his: "this is LIFE and really
    // important... none of the journal should be deletable ever." A swipe is
    // the easiest gesture on the device and it sat one careless thumb away from
    // destroying an entry with no undo — against a corpus that goes back to
    // 2023 and cannot be rewritten.
    //
    // If a delete is ever genuinely needed, it belongs behind something
    // deliberate and reversible, not a swipe. Do not reintroduce this without
    // asking him first.
}

/// Renders as a `BookCard`-style photo card (thumbnail + bottom gradient
/// scrim + overlaid title) when the entry has at least one photo, or a
/// clean serif text card otherwise -- the same "photo-forward when there's a
/// photo, editorial type when there isn't" split Apple's own Journal makes,
/// built from this app's own existing `BookCard` pattern and
/// `CobuxTypography.display()` face rather than new visual language.
private struct JournalEntryRow: View {
    let entry: PersonalWritingEntry
    @Environment(\.colorScheme) private var colorScheme

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// Falls back to a formatted time exactly the way a plain daily journal
    /// with no per-entry title convention already reads -- the section
    /// header already carries the date, so the row itself only needs the
    /// time of day. Never shows a raw blank row.
    private var displayTitle: String {
        guard entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return entry.title }
        return Self.timeFormatter.string(from: entry.modifiedDate ?? entry.dateImported)
    }

    /// The entry text WITHOUT the session stamp it opens with.
    ///
    /// Every entry's body starts with a stamp this app writes ("4:16 AM", or
    /// "August 29, 2026 · 4:16 AM"), and the row title is already a time. So
    /// each row rendered two different times stacked on top of each other --
    /// the modified time as the title, the stamp as the first line of the
    /// preview -- with nothing explaining why they differ. Strip the stamp so
    /// the preview is the writing.
    private var previewText: String {
        let lines = entry.text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return entry.text }
        let head = first.trimmingCharacters(in: .whitespaces)
        // One shared matcher, so a stamp that gains a weather/place
        // tail keeps being recognised here. See `JournalSessionStamp`.
        let isStamp = JournalSessionStamp.isStampLine(head)
        guard isStamp else { return entry.text }
        return lines.dropFirst()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// PHOTO attachments only. This used to be `entry.attachments.first?.id`,
    /// which happily handed a voice note to `photoCard` -- and since a voice
    /// note has no image, the row rendered as a blank grey card with no
    /// indication that a recording existed at all.
    private var firstPhotoAttachmentID: UUID? {
        entry.attachments.first { !JournalAttachmentStore.isVoiceNote(id: $0.id) }?.id
    }

    private var hasVoiceNote: Bool {
        entry.attachments.contains { JournalAttachmentStore.isVoiceNote(id: $0.id) }
    }

    var body: some View {
        if let attachmentID = firstPhotoAttachmentID {
            photoCard(attachmentID: attachmentID)
        } else {
            textCard
        }
    }

    private func photoCard(attachmentID: UUID) -> some View {
        ZStack(alignment: .bottomLeading) {
            JournalThumbnailImage(attachmentID: attachmentID)
                .aspectRatio(contentMode: .fill)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(previewText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .bottom, endPoint: .top))
        }
        .frame(height: 140)
        .clipShape(RoundedRectangle(cornerRadius: CobuxRadius.card))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    private var textCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(displayTitle)
                    .font(.subheadline.weight(.semibold))
                // A voice-note entry is otherwise indistinguishable from a
                // plain text one in this list, so there was no way to tell a
                // recording existed without opening the entry.
                if hasVoiceNote {
                    Image(systemName: "waveform")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.cobuxAccent)
                        .accessibilityLabel("Has a voice note")
                }
                Spacer()
                // Only shown for anything other than an entry composed here --
                // an in-app entry's own source is never in question, so
                // labeling it would just be noise every single row would carry.
                if entry.source != "journal" {
                    Text(entry.source)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.cobuxSurface2)
                        .clipShape(Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            Text(previewText)
                .font(CobuxTypography.display(colorScheme, size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
    }
}

/// Loads and caches `JournalAttachmentStore.thumbnail(for:)` for one row --
/// a dedicated view (rather than loading inline in `JournalEntryRow`) so
/// `.task(id:)` only re-runs when THIS row's specific attachment changes,
/// not on every parent re-render.
///
/// Fills and crops, never stretches. This was `Image(uiImage:).resizable()`
/// with no aspect ratio, so the image took the exact box each call site gave
/// it -- a 100pt grid tile, the card's `maxHeight: 320` frame -- and a
/// portrait photo was squashed to fit. Rajan, build 57: "it kind of
/// compresses the dimensions and it kinda looks weird ... the image should not
/// be compressed ... flattening the image itself." `.fill` plus `.clipped()`
/// HERE, so every fixed-frame caller becomes fill-and-crop by construction
/// rather than each one remembering to. A caller that wants the photo's own
/// proportions sizes its box from `onLoad` (`JournalEntryCard`).
struct JournalThumbnailImage: View {
    let attachmentID: UUID
    /// The decoded image's point size, once. `UIImage.size` already accounts
    /// for EXIF orientation, so a portrait shot reports portrait.
    var onLoad: ((CGSize) -> Void)? = nil
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.cobuxSurface2
            }
        }
        // The flexible frame is what makes `.clipped()` mean anything: a
        // `.fill` image reports its own overflowing size, so clipping it
        // directly clips nothing. The frame reports whatever the caller
        // proposed (a 100pt tile, the card's box) and the clip lands there.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: attachmentID) {
            // Off the main thread: the disk read and the 900px JPEG decode
            // are exactly the work a scrolling list must not do on the thread
            // that scrolls it. The store is a stateless enum; the result is a
            // finished `UIImage`.
            let id = attachmentID
            let loaded = await Task.detached(priority: .userInitiated) {
                JournalAttachmentStore.thumbnail(for: id)
            }.value
            image = loaded
            if let loaded { onLoad?(loaded.size) }
        }
    }
}

/// A single "the user asked to open Volumes" event -- the identity
/// `.navigationDestination(item:)` pushes `VolumesView` on. Same reason as
/// `ComposeSession`: a value is new on every tap, so a push dropped by the
/// lock gate swapping its subtree costs one tap, not the session.
struct VolumesSession: Identifiable, Hashable {
    let id = UUID()
}

/// A single "the user asked to open People" event -- `VolumesSession`'s
/// shape, for the same reason.
struct PeopleSession: Identifiable, Hashable {
    let id = UUID()
}

/// A single "the user asked to compose" event.
///
/// Exists purely so the compose sheet is driven by `.sheet(item:)` rather than
/// `.sheet(isPresented:)`. A Bool can only ever transition false->true once
/// before something has to set it back; an identity is new on every tap, which
/// is what makes a re-tap recoverable after a dropped presentation.
struct ComposeSession: Identifiable {
    let id = UUID()
    /// Set when this session is a Write Back -- the compose sheet opens in
    /// answer mode quoting this entry. The Correspondence's plumbing.
    var answeringEntryID: UUID? = nil
}
