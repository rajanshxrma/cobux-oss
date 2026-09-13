import SwiftData
import SwiftUI

/// Destinations under More that something OUTSIDE the view can push -- today
/// the Journal widget and the `cobux://journal` deep link.
///
/// The ordinary rows here use `NavigationLink(destination:)`, which is fine for
/// a tap but can't be triggered programmatically: there's no value to append to
/// the tab's `NavigationPath`. Rather than convert every row (churn with no
/// benefit -- the others have no external entry point), this adds one typed
/// route for the destinations that genuinely need to be reachable from a
/// widget, a deep link, or a future Shortcut.
enum MoreRoute: Hashable {
    /// Journal's list. `startingNewEntry` opens the compose sheet straight
    /// away, which is the whole point of the widget's "write" tap -- Rajan's
    /// reminder was "Cobux journal widget direct", i.e. land on the page you
    /// actually came to use, not two taps short of it.
    case journal(startingNewEntry: Bool)
    /// Settings, for `cobux://settings` -- the "Open Settings" action on every
    /// "API Key Required" alert. Those alerts used to name a screen three
    /// taps away with no way to it.
    case settings
}

/// The More tab, organised by what each thing IS -- a place (Journal), a
/// collection (Liked), a record (the streak), and utilities (everything else)
/// -- never by rank. That distinction is the whole answer to a tension Rajan
/// named directly: Journal is one of the app's pillars and looked like "just
/// another row", but he explicitly loves that nothing here gets shrine
/// treatment. So the Journal entry point renders in the JOURNAL'S OWN visual
/// language (month hue, display face, entry facts) -- bigger because a
/// writing surface is a different kind of thing than a settings row, not
/// because it outranks one.
struct MoreView: View {
    @State private var showingWidgetHelp = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    /// The Journal card's two facts. This was `@Query private var
    /// journalEntries: [PersonalWritingEntry]` -- every entry, full text,
    /// materialised on the main actor to show a count and a minimum, and
    /// re-walked on every body. Now a `fetchCount` and two `fetchLimit: 1`
    /// fetches (see `refreshJournalFacts`), re-read when the store saves.
    @State private var journalCount = 0
    @State private var journalSince: Date?
    /// The line the widget mock shows, resolved ONCE when this screen appears
    /// -- see `refreshWidgetSample`. Plain strings, not a `Book`/`Highlight`,
    /// so nothing about presenting the sheet can touch the store.
    ///
    /// Optional, and `nil` means STRICTLY "the library has not been read yet"
    /// -- never "the library is empty". It used to start life holding the
    /// Meditations stand-in, which made those two states indistinguishable and
    /// let the sheet print a quotation as though it came from his own library
    /// before it had opened it. `DiagnosticsView` draws the same line for the
    /// same reason (`counts` is `nil` until the probe answers, and the screen
    /// shows nothing rather than a zero). Once the probe returns this is
    /// non-nil forever, fallback included, so `nil` cannot linger.
    @State private var widgetSample: WidgetSample?
    let notificationManager: NotificationManager
    @Binding var path: NavigationPath
    @State private var streak = StreakTracker.currentStreak

    /// Used until a real line lands, and on a library that genuinely has none.
    /// Meditations is public domain, so this ships as itself rather than as an
    /// invented quotation.
    private static let fallbackWidgetSample = WidgetSample(
        quote: "The impediment to action advances action. What stands in the way becomes the way.",
        book: "Meditations",
        accentHex: "#6366F1")

    /// What the mock actually draws: the real line once it lands, the
    /// public-domain stand-in until then -- and `isAwaitingSample` below tells
    /// the sheet which of the two it is holding, so the stand-in is never
    /// PRESENTED as his.
    private var widgetMockSample: WidgetSample { widgetSample ?? Self.fallbackWidgetSample }

    private static let sinceFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter
    }()

    /// This screen's one walkthrough hint: binding a volume, shown above the
    /// Journal card (Saved → Volumes is right below it) once the journal is
    /// big enough for a volume to be a real thing. Entry count stands in for
    /// `VolumeBinder.minimumPassages` -- the binder's own passage selection
    /// is too heavy to run for a hint, and with fewer entries than that the
    /// tip would promise a book that binds nothing.
    private var moreTips: [CobuxTip] {
        journalCount >= VolumeBinder.minimumPassages ? [.boundVolumes] : []
    }

    /// The Journal entry point, in the journal's own language: the current
    /// month's hue as a wash, the display face, and the two facts that only
    /// ever grow -- entry count and how far back the writing reaches. NEVER
    /// "last written N days ago": elapsed-time-since-writing is streak-shame
    /// through a mirror.
    ///
    /// The compose button is a SIBLING in the ZStack, not nested in the
    /// link's label -- the documented dead-tap trap.
    private var journalCard: some View {
        let hue = Color.cobuxMonthHue(Calendar.current.component(.month, from: .now),
                                      dark: colorScheme == .dark)
        let count = journalCount
        let earliest = journalSince
        return ZStack(alignment: .trailing) {
            // A Button into `path`, NOT a NavigationLink -- a NavigationLink in
            // a List row gets the platform's disclosure chevron drawn by the
            // CELL, outside this card's own background and hard against its
            // rounded corner. Rajan photographed it beside the same defect on
            // the feature tip: "the top corss here is weirdly palced formatted
            // absed on the curve similarly the rigt arrow thingy here". The
            // chevron is unreachable from here by any modifier, so the fix is
            // to stop asking for one; `MoreRoute.journal` already exists and
            // the destination is identical (`JournalListView` handles its own
            // Face ID gate). Same shape `JournalListView`'s entry cards use.
            Button {
                path.append(MoreRoute.journal(startingNewEntry: false))
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Journal")
                        .font(CobuxTypography.display(colorScheme, size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(count > 0
                         ? "\(count) entr\(count == 1 ? "y" : "ies")\(earliest.map { " · since \(Self.sinceFormatter.string(from: $0))" } ?? "")"
                         : "The book you're writing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                path.append(MoreRoute.journal(startingNewEntry: true))
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New journal entry")
            .padding(.trailing, 6)
        }
        // 0.08 of the month hue is a wash on the light ground and nothing at
        // all on the dark one -- the dark hue already paints at 0.85, and 0.08
        // of that over near-black is a black. This card is the first thing he
        // looked at when told the journal had a warm tint in dark mode ("i
        // dont relly see what dark mode warm tint theres none"), so it carries
        // one he can see. Light is untouched.
        .background(hue.opacity(colorScheme == .dark ? 0.24 : 0.08),
                    in: RoundedRectangle(cornerRadius: CobuxRadius.card, style: .continuous))
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                // Second consumer of CobuxFormSection/CobuxSettingsRow (2.2.0),
                // proving the pattern established on SettingsView generalizes.
                // This screen was a flat, unsectioned List before -- grouping it
                // into "Progress"/"Library" is itself part of "looks modern," not
                // just a mechanical swap: a flat list of unrelated rows is exactly
                // the stock-Form look this redesign is fixing.
                // 1. The place. First, and no section header -- a "Journal"
                // header over a Journal card is noise. The screen's one tip
                // rides above it (`moreTips`), in the same row, so the list
                // keeps its rhythm.
                Section {
                    VStack(spacing: 12) {
                        CobuxFeatureTipHost(firstOf: moreTips)
                        journalCard
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                if streak > 0 {
                    CobuxFormSection(title: "Progress") {
                        CobuxSettingsRow(
                            icon: "flame.fill",
                            iconTint: Color.cobuxWarning,
                            // 61: his words -- "remove the current streak text and the
                            // days on the right, and instead display the number of days
                            // and then streak the way it says in quiz", keeping this row.
                            label: "\(streak) day\(streak == 1 ? "" : "s") streak",
                            value: nil,
                            valueNumericTransition: true
                        )
                        .animation(.easeOut(duration: 0.3), value: streak)
                    }
                }

                // Its own section, not folded into "Library" below -- unlike
                // Reminders/Settings/What's New (each a one-time visit, or an
                // occasional check-in), this is meant to be a daily habit, and
                // burying it as the fourth row of a settings-shaped list would
                // undersell that. `path` binding matches the four other tabs'
                // convention (see `ContentView.tabSelection`'s doc comment) --
                // More is a menu, not content, so this is the one place that
                // convention doesn't apply, and this NavigationLink is fine
                // pushing onto More's own reset-on-leave path.
                CobuxFormSection(title: "Saved") {
                    NavigationLink(destination: LikedHighlightsView()) {
                        Label("Liked", systemImage: "heart.fill")
                    }
                    NavigationLink(destination: HeldView()) {
                        Label("Held", systemImage: "bookmark")
                    }
                    // Opening Volumes is the feature being used, so its hint
                    // retires itself.
                    NavigationLink(destination: VolumesView().onAppear { CobuxTip.boundVolumes.markUsed() }) {
                        Label("Volumes", systemImage: "books.vertical")
                    }
                }

                // 4. Utilities -- one honest section. This header used to
                // say "Library", which it never was. The widget row folds in
                // here too (its doc rationale -- the invite must stay
                // reachable forever, no badge, it waits to be looked for --
                // holds unchanged).
                CobuxFormSection(title: "App") {
                    Button { showingWidgetHelp = true } label: {
                        Label("Home Screen Widgets", systemImage: "square.grid.2x2.fill")
                    }
                    .buttonStyle(.plain)
                    NavigationLink(destination: RemindersView(notificationManager: notificationManager)) {
                        Label("Reminders", systemImage: "bell.fill")
                    }
                    NavigationLink(destination: SettingsView()) {
                        Label("Settings", systemImage: "gearshape")
                    }
                    NavigationLink(destination: ChangelogView()) {
                        Label("What's New", systemImage: "sparkles")
                    }
                    // Not #if DEBUG. DiagnosticLog writes in Release too, and its whole
                    // purpose is letting a tester share what happened after a crash -- but
                    // the only viewer was compiled out of exactly the builds testers run,
                    // so the log had no way out of the device. The launch-crash hunt this
                    // was built for had to fall back to pulling logs off the phone by hand.
                    NavigationLink(destination: DiagnosticsView()) {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                }
            }
            // The tab room's ground (P9): the journal's crimson wash in dark
            // under the inset cards, nothing added in light.
            .cobuxRoomGround()
            .navigationTitle("More")
            // Programmatic counterpart to the Journal row's own NavigationLink,
            // so a widget tap / deep link lands on the same screen the tap does
            // (including its Face ID gate, which lives inside JournalListView).
            .sheet(isPresented: $showingWidgetHelp) {
                // Three reads of a stored value. This used to be three reads of
                // a COMPUTED property, and each one walked the library from
                // scratch: `books.first(where: { !$0.highlights.isEmpty })`
                // faults a whole book's `highlights` relationship, and on a
                // reference textbook that is thousands of rows carrying their
                // full text and a 512-float embedding each -- then
                // `readsStandalone` scans them. Three times, between the tap on
                // "Home Screen Widgets" and the sheet's first frame. *"when
                // clickcing on home scren widegets button ins ettings that also
                // takes time to open liek diagnotics section."* It did.
                WidgetInviteView(quote: widgetMockSample.quote,
                                 bookTitle: widgetMockSample.book,
                                 accentHex: widgetMockSample.accentHex,
                                 isAwaitingSample: widgetSample == nil) {
                    showingWidgetHelp = false
                }
            }
            .navigationDestination(for: MoreRoute.self) { route in
                switch route {
                case .journal(let startingNewEntry):
                    JournalListView(startingNewEntry: startingNewEntry)
                case .settings:
                    SettingsView()
                }
            }
            .onAppear {
                streak = StreakTracker.currentStreak
                refreshJournalFacts()
            }
            // Off the tap path AND off the main actor. The first `await` hops
            // to the probe's own actor, so this tab's frame commits with no
            // store work in front of it at all -- not a yield-then-block, which
            // is what this was and what left the tap queued behind a fetch.
            .task {
                await refreshWidgetSample()
            }
            // Writing an entry, importing an archive, restoring a backup: the
            // facts follow the store, the way the old `@Query` did, without
            // holding the table to do it.
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
                        .receive(on: DispatchQueue.main)) { _ in
                // Not during a seed: the seed saves in small batches, hundreds
                // of times, and writes no journal entries. The facts are
                // re-read when the screen next appears anyway.
                guard !SeedingStatus.shared.isSeeding else { return }
                refreshJournalFacts()
            }
        }
    }

    /// Count and earliest date, bounded. The earliest date is the minimum
    /// of `modifiedDate ?? dateImported` over every entry, which no single
    /// sort descriptor can express -- so it is the smaller of two
    /// one-row fetches: the earliest `modifiedDate` among entries that have
    /// one, and the earliest `dateImported` among entries that do not.
    /// Exactly the old `map { $0.modifiedDate ?? $0.dateImported }.min()`,
    /// without loading a single body.
    private func refreshJournalFacts() {
        journalCount = (try? modelContext.fetchCount(FetchDescriptor<PersonalWritingEntry>())) ?? 0

        var dated = FetchDescriptor<PersonalWritingEntry>(
            predicate: #Predicate { $0.modifiedDate != nil },
            sortBy: [SortDescriptor(\PersonalWritingEntry.modifiedDate, order: .forward)])
        dated.fetchLimit = 1
        dated.propertiesToFetch = [\.modifiedDate]
        var undated = FetchDescriptor<PersonalWritingEntry>(
            predicate: #Predicate { $0.modifiedDate == nil },
            sortBy: [SortDescriptor(\PersonalWritingEntry.dateImported, order: .forward)])
        undated.fetchLimit = 1
        undated.propertiesToFetch = [\.dateImported]

        let earliestDated = (try? modelContext.fetch(dated))?.first?.modifiedDate
        let earliestUndated = (try? modelContext.fetch(undated))?.first?.dateImported
        journalSince = [earliestDated, earliestUndated].compactMap { $0 }.min()
    }

    /// One real line for the widget mock, resolved OFF the main actor.
    ///
    /// `@MainActor` explicitly, the way `DiagnosticsView.load()` is: this
    /// assigns `@State`, and a bare `async` method makes no promise about which
    /// actor it resumes on (SE-0338). The probe's own method is isolated to its
    /// `@ModelActor`, so the `await` genuinely leaves main and only a `Sendable`
    /// struct of plain strings comes back -- no `@Model` object and no
    /// `ModelContext` crosses.
    ///
    /// The stand-in is applied only once the probe has actually LOOKED, so
    /// `widgetSample` stops being nil by either route and the sheet's redaction
    /// always clears. Nil never lingers.
    @MainActor
    private func refreshWidgetSample() async {
        let probe = WidgetSampleProbe(modelContainer: modelContext.container)
        widgetSample = (await probe.sample()) ?? Self.fallbackWidgetSample
    }
}

/// The widget mock's one line, as plain strings -- never a `Book` or a
/// `Highlight`, so nothing about presenting the sheet can touch the store.
///
/// File scope and `Sendable` for exactly the reason `DiagnosticsCounts` is: it
/// crosses back from a `@ModelActor`, and only `Sendable` values may.
struct WidgetSample: Equatable, Sendable {
    var quote: String
    var book: String
    var accentHex: String
}

/// Resolves that line off the main actor, one row at a time.
///
/// This is the SECOND fix for "Home Screen Widgets takes a visible moment to
/// open" (R-2026-09-widget-sheet-library-walk), and the first one is why the
/// record needed reopening rather than replacing. That fix moved the work out
/// of the sheet's content closure -- three whole-book `highlights` faults
/// between the tap and the first frame -- into a `.task` on the tab. Correct,
/// and not sufficient: what it moved was still a SYNCHRONOUS main-actor fetch
/// of up to 200 `Highlight` rows, each carrying its full text and a 512-float
/// `embeddingData` blob, with no `propertiesToFetch` to bound the columns. It
/// ran milliseconds before the tap it was meant to get out of the way of, so
/// the tap simply queued behind it and the pause moved rather than went.
///
/// Two changes, and both have a precedent in this codebase rather than being
/// invented here:
///
///   * OFF the main actor -- `DiagnosticsProbe`'s shape exactly, which exists
///     because this same screen's Diagnostics row had this same symptom.
///   * ONE row at a time -- the primitive `ContentView.widgetInviteSample` and
///     `WidgetHighlightPool` were both moved onto for this same reason
///     (R-2026-09-nudges-and-watch-walk-whole-library): a bounded walk of
///     `fetchLimit = 1` fetches, so peak materialization is a single
///     `Highlight` plus its `Book` instead of 200 of them.
///
/// Newest-first is preserved deliberately, NOT swapped for the random offset
/// the other two samplers use. That was a considered choice when this sampler
/// was written -- the mock should show a line he has actually seen recently,
/// not whichever row sits first in store order -- and making the fetch cheap is
/// no reason to spend it.
@ModelActor
actor WidgetSampleProbe {
    /// How many rows deep to look for a line that reads on its own before
    /// settling for the newest one. Each step is its own indexed single-row
    /// fetch, so this is a budget of QUERIES, not of materialized rows -- which
    /// is why it is 12 and not the 200 a scan-then-filter could afford.
    /// Comfortably past any realistic run of consecutive fragments.
    private static let maxSteps = 12

    func sample() -> WidgetSample? {
        var descriptor = FetchDescriptor<Highlight>(
            predicate: #Predicate<Highlight> { $0.book != nil },
            sortBy: [SortDescriptor(\Highlight.dateAdded, order: .reverse)])
        descriptor.fetchLimit = 1
        // The mock shows `text` and the book's title and colour -- never the
        // row's 2 KB `embeddingData`, so that column stays out of each of
        // these single-row fetches. SwiftData faults it lazily if a later
        // reader asks.
        descriptor.propertiesToFetch = [\.id, \.text, \.dateAdded]
        descriptor.relationshipKeyPathsForPrefetching = [\.book]

        // The newest attached highlight, held as the fallback -- exactly the
        // `?? candidates[0]` the scanning version ended on.
        var newest: WidgetSample?
        for step in 0..<Self.maxSteps {
            descriptor.fetchOffset = step
            // Past the end of the library: stop, don't keep asking.
            guard let candidate = (try? modelContext.fetch(descriptor))?.first else { break }
            // `book != nil` is already the predicate -- the mock prints the
            // book's title and cover colour, and an unsorted Share-Extension
            // capture has neither. Belt and braces.
            guard let book = candidate.book else { continue }
            let sample = WidgetSample(quote: candidate.text,
                                      book: book.title,
                                      accentHex: book.coverColorHex)
            if FlowQueueBuilder.readsStandalone(candidate.text) { return sample }
            if newest == nil { newest = sample }
        }
        return newest
    }
}
