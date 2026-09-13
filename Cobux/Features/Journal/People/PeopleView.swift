import SwiftUI
import SwiftData

/// The People section: who keeps appearing in his writing, one row each,
/// in the order his writing put them — never a rank.
///
/// Sits one level below the journal list beside Volumes and, like
/// `VolumesView`, self-wraps in `JournalLocked`: a pushed surface does not
/// inherit the gate, and nothing on a person page is readable without Face
/// ID (`docs/people-in-the-journal.md` §3, §6; his decision Q2).
///
/// The first frame reads `JournalPerson` rows through `@Query` — a dozen
/// rows, one blob each — and faults nothing else: no entry is fetched here,
/// no photo is decoded in `body`. Thumbnails load behind each row's own
/// `.task` (`PersonAvatarView`).
///
/// What it never does: rank (no "most written about", no sort control), say
/// a name he quieted (`JournalQuietWords`), count a suppressed entry
/// (`EbbSuppressionStore`), or state a gap ("you haven't written about X").
struct PeopleView: View {
    /// Every row, newest `lastSeen` first — the order his writing produced.
    /// `nil` dates sort last. Filtering by kind and tier happens in Swift
    /// because the rows are few and the rules (quiet words, suppression,
    /// a confirmed row outranking the count) are not predicate-shaped.
    @Query(sort: [SortDescriptor(\JournalPerson.lastSeen, order: .reverse)])
    private var people: [JournalPerson]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("cobux.user.displayName") private var displayName: String = ""

    /// Identity, not a Bool -- `ComposeSession`'s lesson, for a sheet
    /// presented from the view that hosts the lock gate.
    @State private var selfPrompt: SelfPromptSession?
    /// The person a tapped row is opening; resolved by id on the page so the
    /// destination is a value the stack can hold (`HeldView`'s shape).
    @State private var openPersonID: UUID?
    /// A name from the "Also noticed" line he tapped: Add / Not a person.
    @State private var noticedPick: JournalPerson?
    /// Whether the indexer has ever completed a pass. Read once behind the
    /// first frame; drives the one line the empty state adds when the
    /// journal has not been read for names yet.
    @State private var indexHasRun = true

    var body: some View {
        JournalLocked(autoPromptsWhenTopmost: selfPrompt == nil) {
            Group {
                if listed.isEmpty, noticed.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .task {
                await Task.yield()
                indexHasRun = PeopleIndexReport.read() != nil
                offerSelfPromptIfNeeded()
            }
        }
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.large)
        // Declared out here on the gate's own view, beside the sheet, for the
        // reason `JournalListView` records: a destination declared inside
        // the gate's subtree is lost mid-push on a relock.
        .navigationDestination(item: $openPersonID) { personID in
            PersonView(personID: personID)
        }
        .sheet(item: $selfPrompt) { _ in
            SelfPromptSheet(people: listed) { chosen in
                if let chosen {
                    chosen.kind = .isSelf
                    chosen.confirmedAt = .now
                    chosen.updatedAt = .now
                    try? modelContext.save()
                }
                PeopleSelfPrompt.markAsked()
                selfPrompt = nil
            }
        }
        // A small decision opens in the middle of the screen (the Sigil
        // ruling), two verbs, no third.
        .alert(noticedPick?.name ?? "", isPresented: .init(
            get: { noticedPick != nil }, set: { if !$0 { noticedPick = nil } }),
               presenting: noticedPick) { person in
            Button("Add") {
                // A confirmed row outranks the count: it is listed from now
                // on and the shape rules never drop it again.
                person.confirmedAt = .now
                person.updatedAt = .now
                try? modelContext.save()
            }
            Button("Not a person", role: .destructive) {
                person.kind = .notPerson
                person.updatedAt = .now
                try? modelContext.save()
            }
            Button("Cancel", role: .cancel) { }
        } message: { person in
            Text(Self.noticedMessage(for: person))
        }
    }

    // MARK: - Tiers

    /// Rows that may be shown at all: a person (not him, not "not a
    /// person"), whose name is not one he quieted. Suppressed entries are
    /// taken out of the count below, not here — a person is still a person
    /// when one entry about them is silenced.
    private var visible: [JournalPerson] {
        people.filter { person in
            person.kind == .person
                && !person.allForms.contains(where: JournalQuietWords.isQuiet)
        }
    }

    /// Listed: three or more entries after suppression, or a row he
    /// confirmed (Add, Rename, Merge, This is me). These get pages.
    private var listed: [JournalPerson] {
        let suppressed = EbbSuppressionStore.suppressedIDs()
        return visible.filter { person in
            person.confirmedAt != nil
                || countedIDs(of: person, suppressed: suppressed).count >= PeopleTier.listed
        }
    }

    /// Noticed: exactly two entries. Names on one quiet line at the foot,
    /// no pages, one tap from Add or Not a person.
    private var noticed: [JournalPerson] {
        let suppressed = EbbSuppressionStore.suppressedIDs()
        return visible.filter { person in
            person.confirmedAt == nil
                && countedIDs(of: person, suppressed: suppressed).count == PeopleTier.noticed
        }
    }

    private func countedIDs(of person: JournalPerson, suppressed: Set<UUID>) -> [UUID] {
        person.entryIDs.filter { !suppressed.contains($0) }
    }

    // MARK: - The list

    private var list: some View {
        List {
            Section {
                ForEach(listed) { person in
                    Button {
                        openPersonID = person.id
                    } label: {
                        PersonRow(person: person,
                                  count: countedIDs(of: person,
                                                    suppressed: EbbSuppressionStore.suppressedIDs()).count)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 8, leading: CobuxSpacing.screenMargin,
                                              bottom: 8, trailing: CobuxSpacing.screenMargin))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityHint("Opens the entries that mention \(person.name)")
                }
            }

            if !noticed.isEmpty {
                Section {
                    alsoNoticed
                        .listRowInsets(EdgeInsets(top: 12, leading: CobuxSpacing.screenMargin,
                                                  bottom: 24, trailing: CobuxSpacing.screenMargin))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background { JournalGround() }
        .refreshable {
            // On demand: the same pass launch and a save run, off-main, now.
            // The list re-reads its rows when they change; the spinner
            // holds until the pass returns.
            _ = await JournalPeopleIndexer.runNow(container: modelContext.container)
            indexHasRun = PeopleIndexReport.read() != nil
        }
    }

    /// Foot of the list, `.caption2`, tertiary: the names, tappable, and
    /// nothing else — no count beside them, no "add" glyph.
    private var alsoNoticed: some View {
        PeopleWrapLayout(spacing: 4) {
            Text("Also noticed:")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(Array(noticed.enumerated()), id: \.element.id) { index, person in
                Button {
                    noticedPick = person
                } label: {
                    Text(person.name + (index == noticed.count - 1 ? "." : ","))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(person.name)
                .accessibilityHint("Add as a person, or mark as not a person")
            }
        }
    }

    // MARK: - Empty

    /// `CobuxEmptyStateView`'s grammar, the journal's tint. One extra line
    /// when the journal has not been read for names yet, so the emptiness
    /// is explained rather than asserted.
    private var emptyState: some View {
        CobuxEmptyStateView(
            icon: "person.2",
            title: "Nobody yet",
            message: indexHasRun
                ? "When a name appears in three or more entries, it will be here."
                : "When a name appears in three or more entries, it will be here. Your journal hasn't been read for names yet.",
            tint: .cobuxCrimson
        ) {
            if !indexHasRun {
                CobuxEmptyStateButton("Read it now", systemImage: "text.magnifyingglass", tint: .cobuxCrimson) {
                    let container = modelContext.container
                    Task {
                        _ = await JournalPeopleIndexer.runNow(container: container)
                        indexHasRun = PeopleIndexReport.read() != nil
                    }
                }
            }
        }
        .background { JournalGround() }
    }

    // MARK: - "Which of these is you?"

    /// Once, before he ever sees a page. When his name is set in Settings the
    /// indexer already excludes it, so the question is only asked when a
    /// listed name could still be his: no display name, or a listed name
    /// that equals its first token.
    private func offerSelfPromptIfNeeded() {
        guard !PeopleSelfPrompt.asked, !listed.isEmpty else { return }
        let firstToken = displayName
            .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if !firstToken.isEmpty,
           !listed.contains(where: { $0.matches(form: firstToken) }) {
            PeopleSelfPrompt.markAsked()
            return
        }
        selfPrompt = SelfPromptSession()
    }

    private static func noticedMessage(for person: JournalPerson) -> String {
        "Seen in two entries. Add gives \(person.name) a page; Not a person keeps this name off the list."
    }
}

// MARK: - Tiers and flags

/// The measured tiers (`docs/people-in-the-journal.md` §2): tunable constants
/// in one place.
enum PeopleTier {
    static let listed = 3
    static let noticed = 2
}

/// The one-time "Which of these is you?" flag. `UserDefaults.standard`, never
/// the app group — nothing about People reaches the extensions.
enum PeopleSelfPrompt {
    static let key = "cobux.people.askedSelf"
    static var asked: Bool { UserDefaults.standard.bool(forKey: key) }
    static func markAsked() { UserDefaults.standard.set(true, forKey: key) }
    static func reset() { UserDefaults.standard.removeObject(forKey: key) }
}

private struct SelfPromptSession: Identifiable {
    let id = UUID()
}

// MARK: - Row

/// One person: photo or initials in the month hue of `firstSeen`, the name,
/// and one caption stating a span and a count as facts.
private struct PersonRow: View {
    let person: JournalPerson
    let count: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 14) {
            PersonAvatarView(person: person, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(person.name)
                    .font(CobuxTypography.cobuxRowLabel)
                    .foregroundStyle(Color.cobuxInk)
                    .lineLimit(1)
                Text(PeopleDates.spanAndCount(first: person.firstSeen, last: person.lastSeen, count: count))
                    .font(CobuxTypography.cobuxCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

// MARK: - Avatar

/// The contact photo when linked, otherwise initials set in the month hue of
/// `firstSeen` — the hue is content: the month he first wrote them down.
/// The photo decodes behind `.task`, never in `body`; the initials draw at
/// once, so a row is never blank for a frame.
struct PersonAvatarView: View {
    let person: JournalPerson
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var photo: UIImage?

    var body: some View {
        ZStack {
            Circle()
                .fill(hue.opacity(colorScheme == .dark ? 0.28 : 0.16))
            Text(initials)
                .font(CobuxTypography.passage(size: size * 0.4, weight: .semibold))
                .foregroundStyle(Color.cobuxInk)
                .minimumScaleFactor(0.6)
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(hue.opacity(0.35), lineWidth: 1))
        .accessibilityLabel(person.name)
        // Keyed on the link, so Unlink or Change photo reloads without a
        // view identity change.
        .task(id: person.contactLinkedDate) {
            guard person.contactIdentifier != nil else { photo = nil; return }
            let id = person.id
            let loaded = await Task.detached(priority: .utility) {
                PeopleThumbnailStore.image(for: id)
            }.value
            if reduceMotion { photo = loaded } else { withAnimation(.easeOut(duration: 0.2)) { photo = loaded } }
        }
    }

    private var hue: Color {
        Color.cobuxMonthHue(Calendar.current.component(.month, from: person.firstSeen ?? person.createdAt),
                            dark: colorScheme == .dark)
    }

    private var initials: String {
        let parts = person.name.split(whereSeparator: \.isWhitespace).prefix(2)
        return parts.compactMap { $0.first }.map { String($0).uppercased() }.joined()
    }
}

// MARK: - The self sheet

/// "Which of these is you?" — one tap, stored as `kind = "self"`, never
/// listed. Asked once. "None of these" is always available, so the answer is
/// never forced.
private struct SelfPromptSheet: View {
    let people: [JournalPerson]
    let onChoose: (JournalPerson?) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(people) { person in
                        Button {
                            onChoose(person)
                        } label: {
                            HStack(spacing: 14) {
                                PersonAvatarView(person: person, size: 36)
                                Text(person.name)
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
                    Text("Which of these is you?")
                        .font(CobuxTypography.display(colorScheme, size: 22, weight: .semibold))
                        .foregroundStyle(Color.cobuxInk)
                        .textCase(nil)
                        .padding(.bottom, 6)
                } footer: {
                    Text("Your own name comes up when you write about yourself. Choosing it keeps you off the list; nothing else changes.")
                        .font(CobuxTypography.cobuxCaption)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background { JournalGround() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("None of these") { onChoose(nil) }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }
}

// MARK: - Dates

/// Formatters built once. `find_per_render_formatters` is the reason these
/// are `static let` and not locals in a row.
enum PeopleDates {
    static let monthYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()

    static let longDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    /// "March 2024 – August 2026 · in 47 entries." A span and a count, stated
    /// as facts, once, small, as part of a sentence.
    static func spanAndCount(first: Date?, last: Date?, count: Int) -> String {
        let entries = count == 1 ? "in 1 entry" : "in \(count) entries"
        guard let first, let last else { return entries + "." }
        let a = monthYear.string(from: first)
        let b = monthYear.string(from: last)
        return (a == b ? a : "\(a) – \(b)") + " · " + entries + "."
    }
}

// MARK: - Wrap layout

/// Names on the "Also noticed" line wrap like prose rather than scrolling
/// sideways (a horizontal ScrollView inside a List is the scroll-in-scroll
/// class). The chat transcript's `FlowLayout`, made local.
struct PeopleWrapLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                totalHeight += rowHeight
                widestRow = max(widestRow, x - spacing)
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        widestRow = max(widestRow, x - spacing)
        return CGSize(width: maxWidth.isFinite ? maxWidth : max(0, widestRow), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowHeight
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
