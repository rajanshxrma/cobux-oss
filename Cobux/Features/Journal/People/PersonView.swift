import SwiftUI
import SwiftData

/// One person's page: a header, and a timeline of his entries that mention
/// them — the same `JournalEntryCard`, the same tap into the detail view, with
/// one addition under each card: the sentence from that entry that names
/// them, found live (`PersonMentionLine`), in the passage face.
///
/// Self-wrapped in `JournalLocked` like `VolumesView`: a pushed surface does
/// not inherit the gate, and this is the journal at its most concentrated.
/// Background the app here and return: Face ID, nothing of the page behind
/// it (his decision Q2).
///
/// First frame: the one `JournalPerson` row through `@Query` — nothing else.
/// The entries are fetched behind `.task`, after `Task.yield()`, by
/// `ids.contains($0.id)` bounded to the row's own ids (the proven shape), with
/// suppressed entries (`EbbSuppressionStore`) and quiet entries
/// (`JournalQuietWords`) dropped before anything renders.
///
/// Every correction is here in the toolbar menu — Rename, Merge into…,
/// Split, Not a person, This is me — and every one of them edits the ROW.
/// No entry is ever touched by any of it. There is no "delete this person":
/// *Not a person* is the honest verb.
///
/// The summary card and "Ask about <Name>" are build 63 (§5) and are
/// deliberately absent, not stubbed: a disabled pill labelled for a later
/// build is a promise on a screen, and this page makes none.
struct PersonView: View {
    let personID: UUID

    @Query private var rows: [JournalPerson]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    private let suppressionSignal = EbbSuppressionSignal.shared

    /// The timeline, newest first, already filtered. Empty until the task
    /// lands; `timelineRead` keeps the page from flashing an empty foot.
    @State private var blocks: [TimelineBlock] = []
    @State private var mentions: [UUID: String] = [:]
    @State private var timelineRead = false
    /// The entry a tapped card is opening -- `JournalListView`'s shape.
    @State private var openEntryID: UUID?
    /// Identities, not Bools, for every sheet presented from the view that
    /// hosts the lock gate (`ComposeSession`'s lesson).
    @State private var pickerSession: PickerSession?
    @State private var mergeSession: MergeSession?
    /// The winner picked in the Merge sheet, acted on once the sheet is gone.
    @State private var pendingMergeWinnerID: UUID?
    @State private var splitSession: SplitSession?
    @State private var renamePrompt = false
    @State private var renameDraft = ""
    @State private var notPersonPrompt = false
    @State private var thisIsMePrompt = false

    init(personID: UUID) {
        self.personID = personID
        let id = personID
        _rows = Query(filter: #Predicate<JournalPerson> { $0.id == id })
    }

    private var person: JournalPerson? { rows.first }

    var body: some View {
        JournalLocked(autoPromptsWhenTopmost: pickerSession == nil && mergeSession == nil && splitSession == nil) {
            Group {
                if let person {
                    page(person)
                } else {
                    gone
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let person {
                ToolbarItem(placement: .topBarTrailing) {
                    correctionMenu(person)
                }
            }
        }
        // Out here beside the sheets, for the reason `JournalListView`
        // records: a destination inside the gate's subtree is lost on relock.
        .navigationDestination(item: $openEntryID) { entryID in
            if let match = blocks.lazy.flatMap(\.entries).first(where: { $0.id == entryID }) {
                JournalEntryDetailView(entry: match)
            }
        }
        .sheet(item: $pickerSession) { _ in
            PersonContactPicker(onPick: { pick in
                pickerSession = nil
                link(pick)
            }, onCancel: {
                pickerSession = nil
            })
            .ignoresSafeArea()
        }
        // The merge runs AFTER the sheet is gone (`onDismiss`), never from
        // inside its button: the sheet used to hold the row it was about to
        // delete and re-render on the save that deleted it -- the Amal trap
        // (a persisted getter on an invalidated model in `body`). The sheet
        // now holds two values, and the pop happens from here, after the
        // dismiss animation, so the stack never has a presenter popping under
        // a live sheet.
        .sheet(item: $mergeSession, onDismiss: {
            guard let winnerID = pendingMergeWinnerID, let person else { return }
            pendingMergeWinnerID = nil
            if let winner = mergeWinner(id: winnerID), winner.id != person.id {
                merge(person, into: winner)
            }
        }) { _ in
            if let person {
                MergeSheet(loserID: person.id, loserName: person.name) { winnerID in
                    pendingMergeWinnerID = winnerID
                    mergeSession = nil
                }
            }
        }
        .sheet(item: $splitSession) { _ in
            if let person {
                SplitSheet(person: person) { alias in
                    splitSession = nil
                    if let alias { split(person, alias: alias) }
                }
            }
        }
        .alert("Rename", isPresented: $renamePrompt) {
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) { }
            Button("Rename") { rename() }
        } message: {
            Text("Changes how this page is titled. The other names it answers to stay as they are.")
        }
        .alert("Not a person?", isPresented: $notPersonPrompt) {
            Button("Cancel", role: .cancel) { }
            Button("Not a person", role: .destructive) { markNotPerson() }
        } message: {
            Text("This page goes and the name is never listed again. Nothing in your journal changes.")
        }
        .alert("This is you?", isPresented: $thisIsMePrompt) {
            Button("Cancel", role: .cancel) { }
            Button("This is me") { markSelf() }
        } message: {
            Text("Your own name is kept off the list. Nothing in your journal changes.")
        }
    }

    // MARK: - The page

    private func page(_ person: JournalPerson) -> some View {
        List {
            Section {
                header(person)
                    .listRowInsets(EdgeInsets(top: 8, leading: CobuxSpacing.screenMargin,
                                              bottom: JournalFeedRhythm.betweenDays,
                                              trailing: CobuxSpacing.screenMargin))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            ForEach(blocks) { block in
                switch block.kind {
                case let .era(month, year):
                    Section {
                        eraDivider(month: month, year: year)
                            .listRowInsets(EdgeInsets(top: JournalFeedRhythm.betweenDays,
                                                      leading: CobuxSpacing.screenMargin,
                                                      bottom: JournalFeedRhythm.betweenDays,
                                                      trailing: CobuxSpacing.screenMargin))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                case let .day(day):
                    Section {
                        ForEach(block.entries) { entry in
                            timelineRow(entry, person: person, day: day)
                                .listRowInsets(EdgeInsets(top: 0,
                                                          leading: CobuxSpacing.screenMargin,
                                                          bottom: JournalFeedRhythm.betweenCards,
                                                          trailing: CobuxSpacing.screenMargin))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        dayHeader(day)
                            .listRowInsets(EdgeInsets(
                                top: JournalFeedRhythm.betweenDays - JournalFeedRhythm.betweenCards,
                                leading: CobuxSpacing.screenMargin,
                                bottom: JournalFeedRhythm.headerToCard,
                                trailing: CobuxSpacing.screenMargin))
                    }
                }
            }

            if timelineRead, blocks.isEmpty {
                Section {
                    // Every entry that named them is quiet or silenced; the
                    // page says only that there is nothing to show here.
                    Text("Nothing to show here.")
                        .font(CobuxTypography.cobuxCaption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets(top: 24, leading: CobuxSpacing.screenMargin,
                                                  bottom: 24, trailing: CobuxSpacing.screenMargin))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background { JournalGround() }
        .task(id: TimelineKey(ids: person.entryIDs,
                              forms: person.allForms,
                              revision: suppressionSignal.revision)) {
            await loadTimeline(for: person)
        }
    }

    /// Photo or initials at 72pt, the name as a title, the span as a kicker
    /// in the first-seen hue, one count as a caption, one quiet chip.
    private func header(_ person: JournalPerson) -> some View {
        VStack(spacing: 10) {
            PersonAvatarView(person: person, size: 72)
                .padding(.bottom, 2)
            Text(person.name)
                .font(CobuxTypography.display(colorScheme, size: 28))
                .foregroundStyle(Color.cobuxInk)
                .multilineTextAlignment(.center)
            if let kicker = Self.spanKicker(first: person.firstSeen, last: person.lastSeen) {
                Text(kicker)
                    .cobuxKicker(tint: hue(for: person), scale: .screen)
                    .multilineTextAlignment(.center)
            }
            Text(Self.countLine(countedIDs(of: person).count))
                .font(CobuxTypography.cobuxCaption)
                .foregroundStyle(.secondary)
            Button {
                pickerSession = PickerSession()
            } label: {
                Label(person.contactIdentifier == nil ? "Link to a contact" : "Change photo",
                      systemImage: person.contactIdentifier == nil ? "person.crop.circle.badge.plus" : "photo")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.cobuxCrimson)
            .cobuxQuietChip(tint: .cobuxCrimson)
            .padding(.top, 4)
            .accessibilityHint("Opens the contact picker. Cobux never reads your address book.")
        }
        .frame(maxWidth: .infinity)
    }

    private func timelineRow(_ entry: PersonalWritingEntry, person: JournalPerson, day: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                openEntryID = entry.id
            } label: {
                let excerpt = JournalListView.preview(for: entry)
                JournalEntryCard(entry: entry, preview: excerpt.text, sessions: excerpt.sessions)
            }
            .buttonStyle(.plain)
            // The one addition: the sentence that names them, verbatim, in
            // the passage face, indented from a thread in the month hue --
            // the echo card's citation grammar, so a quote reads as a quote.
            if let line = mentions[entry.id] {
                HStack(alignment: .top, spacing: 10) {
                    Capsule()
                        .fill(Color.cobuxMonthHue(Calendar.current.component(.month, from: day),
                                                  dark: colorScheme == .dark).opacity(0.6))
                        .frame(width: 2)
                        .padding(.vertical, 2)
                    Text("\u{201C}\(line)\u{201D}")
                        .font(CobuxTypography.passage(size: 15))
                        .foregroundStyle(Color.cobuxInk)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CobuxSpacing.sm)
                .accessibilityLabel("From this entry: \(line)")
            }
        }
    }

    /// The feed's own day header: the numeral in the month hue, the rest
    /// small beside it (`JournalListView`'s header, reused by its helpers).
    private func dayHeader(_ day: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(JournalListView.dayNumeral(day))
                .font(CobuxTypography.display(colorScheme, size: 18, weight: .semibold))
                .foregroundStyle(Color.cobuxMonthHue(Calendar.current.component(.month, from: day),
                                                     dark: colorScheme == .dark))
                .monospacedDigit()
            Text(JournalListView.weekdayAndMonth(day))
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.8)
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
    }

    /// Between eras: the month and its year, ink for the type and the hue
    /// for the spine -- Ebb's era divider one scale down. Dating only: no
    /// count beside a thinner month, no monument.
    private func eraDivider(month: Int, year: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Calendar.current.monthSymbols[max(0, min(11, month - 1))])
                .font(CobuxTypography.display(colorScheme, size: 22, weight: .semibold))
                .foregroundStyle(Color.cobuxInk)
            Text(String(year))
                .font(CobuxTypography.display(colorScheme, size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.leading, CobuxSpacing.md)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(Color.cobuxMonthHue(month, dark: colorScheme == .dark))
                .frame(width: 3)
        }
    }

    /// The row is gone (merged away, or marked Not a person) while the page
    /// was still up. The page says so and nothing else.
    private var gone: some View {
        CobuxEmptyStateView(
            icon: "person",
            title: "No page here",
            message: "This name is no longer listed. Your journal is exactly as it was.",
            tint: .cobuxCrimson
        )
        .background { JournalGround() }
    }

    // MARK: - Toolbar

    private func correctionMenu(_ person: JournalPerson) -> some View {
        Menu {
            Button {
                renameDraft = person.name
                renamePrompt = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                mergeSession = MergeSession()
            } label: {
                Label("Merge into…", systemImage: "arrow.triangle.merge")
            }
            Button {
                splitSession = SplitSession()
            } label: {
                Label("Split", systemImage: "arrow.triangle.branch")
            }
            .disabled(person.aliases.isEmpty)
            Divider()
            Button {
                thisIsMePrompt = true
            } label: {
                Label("This is me", systemImage: "person.crop.circle")
            }
            Button(role: .destructive) {
                notPersonPrompt = true
            } label: {
                Label("Not a person", systemImage: "person.crop.circle.badge.xmark")
            }
            if person.contactIdentifier != nil {
                Divider()
                Button {
                    unlink(person)
                } label: {
                    Label("Unlink contact", systemImage: "person.crop.circle.badge.minus")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Corrections")
    }

    // MARK: - Loading

    /// Fetches the entries this row points at, bounded to its own ids, off
    /// the first frame; drops suppressed and quiet entries; groups by day
    /// with an era divider wherever the month changes; and finds each
    /// entry's mention sentence off-main from a text snapshot.
    private func loadTimeline(for person: JournalPerson) async {
        await Task.yield()
        let ids = countedIDs(of: person)
        guard !ids.isEmpty else {
            blocks = []
            mentions = [:]
            timelineRead = true
            return
        }
        var descriptor = FetchDescriptor<PersonalWritingEntry>(
            predicate: #Predicate { ids.contains($0.id) })
        descriptor.fetchLimit = ids.count
        let fetched = (try? modelContext.fetch(descriptor)) ?? []
        let entries = fetched
            .filter { !JournalQuietWords.isQuiet($0.text) }
            .sorted { Self.date($0) > Self.date($1) }

        // Snapshot the text on the main actor; the search runs off it.
        let forms = person.allForms
        let snapshot = entries.map { ($0.id, $0.text) }
        let found = await Task.detached(priority: .userInitiated) {
            var lines: [UUID: String] = [:]
            for (id, text) in snapshot {
                if let line = PersonMentionLine.first(naming: forms, in: text) {
                    lines[id] = line
                }
            }
            return lines
        }.value

        var built: [TimelineBlock] = []
        let calendar = Calendar.current
        var lastEra: (Int, Int)?
        var currentDay: Date?
        var currentEntries: [PersonalWritingEntry] = []
        func flushDay() {
            if let currentDay, !currentEntries.isEmpty {
                built.append(TimelineBlock(kind: .day(currentDay), entries: currentEntries))
            }
            currentEntries = []
        }
        for entry in entries {
            let date = Self.date(entry)
            let era = (calendar.component(.month, from: date), calendar.component(.year, from: date))
            let day = calendar.startOfDay(for: date)
            if lastEra.map({ $0 != era }) ?? true {
                flushDay()
                currentDay = nil
                built.append(TimelineBlock(kind: .era(month: era.0, year: era.1), entries: []))
                lastEra = era
            }
            if currentDay != day {
                flushDay()
                currentDay = day
            }
            currentEntries.append(entry)
        }
        flushDay()

        if reduceMotion {
            blocks = built
            mentions = found
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                blocks = built
                mentions = found
            }
        }
        timelineRead = true
    }

    private func countedIDs(of person: JournalPerson) -> [UUID] {
        let suppressed = EbbSuppressionStore.suppressedIDs()
        return person.entryIDs.filter { !suppressed.contains($0) }
    }

    private static func date(_ entry: PersonalWritingEntry) -> Date {
        entry.modifiedDate ?? entry.dateImported
    }

    // MARK: - Corrections (row edits only; entries are never touched)

    private func rename() {
        guard let person else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != person.name else { return }
        person.name = trimmed
        person.confirmedAt = .now
        person.updatedAt = .now
        try? modelContext.save()
    }

    /// One row by primary key, on the sheet's dismissal -- not in `body`.
    private func mergeWinner(id: UUID) -> JournalPerson? {
        var descriptor = FetchDescriptor<JournalPerson>(predicate: #Predicate<JournalPerson> { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func merge(_ loser: JournalPerson, into winner: JournalPerson) {
        winner.merge(loser)
        PeopleThumbnailStore.remove(for: loser.id)
        modelContext.delete(loser)
        try? modelContext.save()
        reindex()
        dismiss()
    }

    private func split(_ person: JournalPerson, alias: String) {
        guard person.split(alias: alias) else { return }
        try? modelContext.save()
        reindex()
    }

    private func markNotPerson() {
        guard let person else { return }
        person.kind = .notPerson
        person.updatedAt = .now
        PeopleThumbnailStore.remove(for: person.id)
        try? modelContext.save()
        reindex()
        dismiss()
    }

    private func markSelf() {
        guard let person else { return }
        person.kind = .isSelf
        person.confirmedAt = .now
        person.updatedAt = .now
        PeopleSelfPrompt.markAsked()
        try? modelContext.save()
        reindex()
        dismiss()
    }

    /// Stores the identifier on the row and a small copy of the photo in
    /// `PeopleThumbnailStore`. Nothing is written to Contacts, ever.
    private func link(_ pick: PersonContactPicker.Pick) {
        guard let person else { return }
        let id = person.id
        Task {
            await Task.detached(priority: .userInitiated) {
                if let photo = pick.photo {
                    _ = try? PeopleThumbnailStore.save(imageData: photo, for: id)
                } else {
                    PeopleThumbnailStore.remove(for: id)
                }
            }.value
            person.contactIdentifier = pick.identifier
            person.contactLinkedDate = .now
            person.updatedAt = .now
            try? modelContext.save()
        }
    }

    private func unlink(_ person: JournalPerson) {
        PeopleThumbnailStore.remove(for: person.id)
        person.contactIdentifier = nil
        person.contactLinkedDate = nil
        person.updatedAt = .now
        try? modelContext.save()
    }

    /// The next pass folds a merge or a split through: aliases re-cluster,
    /// a split alias gets its own row back. Off-main, bounded, never in
    /// front of the tap.
    private func reindex() {
        JournalPeopleIndexer.schedule(container: modelContext.container)
    }

    // MARK: - Text

    private func hue(for person: JournalPerson) -> Color {
        Color.cobuxMonthHue(Calendar.current.component(.month, from: person.firstSeen ?? person.createdAt),
                            dark: colorScheme == .dark)
    }

    /// "FIRST WRITTEN · 12 MARCH 2024 — LAST · 3 AUGUST 2026". The kicker
    /// uppercases; the dates come from the shared long-day formatter.
    static func spanKicker(first: Date?, last: Date?) -> String? {
        guard let first else { return nil }
        let a = PeopleDates.longDay.string(from: first)
        guard let last, !Calendar.current.isDate(first, inSameDayAs: last) else {
            return "Written · \(a)"
        }
        return "First written · \(a) — Last · \(PeopleDates.longDay.string(from: last))"
    }

    static func countLine(_ count: Int) -> String {
        count == 1 ? "Mentioned in one entry." : "Mentioned in \(count) entries."
    }
}

// MARK: - Timeline shapes

/// A run of the timeline: an era divider, or one day's entries.
struct TimelineBlock: Identifiable {
    enum Kind {
        case era(month: Int, year: Int)
        case day(Date)
    }
    let kind: Kind
    let entries: [PersonalWritingEntry]

    var id: String {
        switch kind {
        case let .era(month, year): "era-\(year)-\(month)"
        case let .day(day): "day-\(day.timeIntervalSinceReferenceDate)"
        }
    }
}

/// What the timeline depends on: the row's ids and forms, and the
/// suppression revision -- a "Never show this again" anywhere re-runs it.
/// The fields are read by `Hashable`: this value IS the `.task(id:)`
/// identity, and a change to any field is what re-runs the load.
private struct TimelineKey: Hashable { // lint-ok: unread-struct-field -- hashed as the task identity, nothing renders it
    let ids: [UUID]
    let forms: [String]
    let revision: Int
}

private struct PickerSession: Identifiable { let id = UUID() }
private struct MergeSession: Identifiable { let id = UUID() }
private struct SplitSession: Identifiable { let id = UUID() }

// MARK: - Merge into…

/// Pick the person this one folds into. Every other listed person, in the
/// same order as the list; nothing pre-chosen.
private struct MergeSheet: View {
    /// Values, not the row: this sheet outlives the save that deletes the loser.
    let loserID: UUID
    let loserName: String
    let onChoose: (UUID?) -> Void
    @Query(sort: [SortDescriptor(\JournalPerson.lastSeen, order: .reverse)])
    private var people: [JournalPerson]

    private var candidates: [JournalPerson] {
        people.filter { $0.id != loserID && $0.kind == .person
            && !$0.allForms.contains(where: JournalQuietWords.isQuiet) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates) { winner in
                        Button {
                            onChoose(winner.id)
                        } label: {
                            HStack(spacing: 14) {
                                PersonAvatarView(person: winner, size: 36)
                                Text(winner.name)
                                    .font(CobuxTypography.cobuxRowLabel)
                                    .foregroundStyle(Color.cobuxInk)
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("\(loserName) becomes another name for the person you choose, and their pages join. Your entries are untouched; Split reverses it.")
                        .font(CobuxTypography.cobuxCaption)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background { JournalGround() }
            .navigationTitle("Merge into…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onChoose(nil) }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Split

/// Remove one alias so the next pass gives it its own row again.
private struct SplitSheet: View {
    let person: JournalPerson
    let onChoose: (String?) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(person.aliases, id: \.self) { alias in
                        Button {
                            onChoose(alias)
                        } label: {
                            HStack {
                                Text(alias)
                                    .font(CobuxTypography.cobuxRowLabel)
                                    .foregroundStyle(Color.cobuxInk)
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Names folded into \(person.name)")
                        .textCase(nil)
                } footer: {
                    Text("Choosing one lets it stand on its own again. Your entries are untouched.")
                        .font(CobuxTypography.cobuxCaption)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background { JournalGround() }
            .navigationTitle("Split")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onChoose(nil) }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
