import SwiftUI
import SwiftData

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
    @Environment(\.modelContext) private var modelContext
    @Query private var entries: [PersonalWritingEntry]
    @State private var showingCompose = false
    @State private var searchText = ""
    // A minimal, read-only echo of `JournalLocked`'s own lock check --
    // deliberately NOT the whole gate/auto-prompt mechanism (that stays
    // de-duplicated in `JournalLocked`), just enough to decide whether the
    // compose button should even be reachable. Hidden while locked: composing
    // a new entry wouldn't itself expose anything already written, but a
    // half-locked screen (content hidden, yet still able to add to it) reads
    // as broken rather than protected.
    @AppStorage(JournalLockStatus.enabledKey) private var lockEnabled = true
    @State private var lockStatus = JournalLockStatus.shared
    private var isLocked: Bool { lockEnabled && !lockStatus.isUnlocked }

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

    private var filteredEntries: [PersonalWritingEntry] {
        guard !searchText.isEmpty else { return sortedEntries }
        return sortedEntries.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.text.localizedCaseInsensitiveContains(searchText)
        }
    }

    private struct DateSection: Identifiable {
        let id: Date
        let label: String
        let entries: [PersonalWritingEntry]
    }

    /// Newest section first, entries within a section newest first -- same
    /// `Dictionary(grouping:)` -> sort -> map shape `BookThreadPickerView`
    /// already establishes for its own category sections, just keyed by day
    /// instead of category.
    private var dateSections: [DateSection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredEntries) { entry in
            calendar.startOfDay(for: entry.modifiedDate ?? entry.dateImported)
        }
        return grouped
            .sorted { $0.key > $1.key }
            .map { day, entries in
                DateSection(id: day, label: Self.sectionLabel(for: day, calendar: calendar), entries: entries)
            }
    }

    /// Today / Yesterday / weekday name (this week) / month name (this year)
    /// / "Month Year" (older) -- the same calendar-browsing shape Apple's own
    /// Journal groups by, without building a full calendar-picker surface.
    private static func sectionLabel(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let daysAgo = calendar.dateComponents([.day], from: day, to: .now).day ?? 0
        if daysAgo < 7 {
            return day.formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(day, equalTo: .now, toGranularity: .year) {
            return day.formatted(.dateTime.month(.wide))
        }
        return day.formatted(.dateTime.month(.wide).year())
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
        // `autoPromptsWhenTopmost: !showingCompose` -- while the compose
        // sheet is up, IT is the topmost visible screen, not this list
        // underneath it. Without this, backgrounding mid-compose would
        // relock and this list's own auto-prompt would pop a Face ID dialog
        // over the still-open compose sheet the user is actively typing in.
        JournalLocked(autoPromptsWhenTopmost: !showingCompose) {
            journalContent
                // Bottom-right, not the top-right toolbar -- reported live
                // as an awkward one-handed reach on a real phone. A plain
                // filled circle floating over the list, not a toolbar item,
                // is what actually lands in easy thumb range regardless of
                // device size.
                .overlay(alignment: .bottomTrailing) {
                    if !isLocked {
                        Button {
                            showingCompose = true
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
        .sheet(isPresented: $showingCompose) {
            JournalEntryComposeView()
        }
    }

    @ViewBuilder
    private var journalContent: some View {
        if entries.isEmpty {
            CobuxEmptyStateView(
                icon: "book.closed",
                title: "Nothing here yet",
                message: "Write your first entry, or import past writing from Settings."
            ) {
                CobuxEmptyStateButton("New Entry", systemImage: "square.and.pencil") {
                    showingCompose = true
                }
            }
        } else {
            List {
                if journalStreak > 0 {
                    Section {
                        streakChip
                            .padding(.horizontal, CobuxSpacing.screenMargin)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                ForEach(dateSections) { section in
                    Section(section.label) {
                        ForEach(section.entries) { entry in
                            NavigationLink(destination: JournalEntryDetailView(entry: entry)) {
                                JournalEntryRow(entry: entry)
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: CobuxSpacing.screenMargin, bottom: 6, trailing: CobuxSpacing.screenMargin))
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    delete(entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Search your journal")
            .overlay {
                if !searchText.isEmpty && filteredEntries.isEmpty {
                    CobuxEmptyStateView(icon: "magnifyingglass", title: "No matches", message: "Try a different search.")
                }
            }
        }
    }

    /// Same flame/`.cobuxWarning`/`.cobuxGlassChip` convention
    /// `QuizHomeView.streakChip` already established for
    /// `StreakTracker.currentStreak` -- reusing it here reads as "the same
    /// kind of streak," just scoped to journaling, rather than inventing a
    /// second, differently-styled counter.
    private var streakChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
                .foregroundStyle(Color.cobuxWarning)
            Text("\(journalStreak) day\(journalStreak == 1 ? "" : "s") journaling")
                .cobuxNumeralStyle(size: 14)
                .foregroundStyle(Color.cobuxInk)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.3), value: journalStreak)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .cobuxGlassChip(tintColor: Color.cobuxWarning)
    }

    private func delete(_ entry: PersonalWritingEntry) {
        // SwiftData's cascade delete (`PersonalWritingEntry.attachments`)
        // only removes the `JournalAttachment` rows -- the actual JPEGs on
        // disk are `JournalAttachmentStore`'s to clean up, same pairing
        // `JournalEntryComposeView.save()`'s own attachment-removal already
        // follows. Must happen before `modelContext.delete(entry)` while
        // `entry.attachments` is still populated.
        for attachment in entry.attachments {
            JournalAttachmentStore.delete(id: attachment.id)
        }
        modelContext.delete(entry)
        try? modelContext.save()
    }
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

    private var firstAttachmentID: UUID? { entry.attachments.first?.id }

    var body: some View {
        if let attachmentID = firstAttachmentID {
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
                Text(entry.text)
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
            Text(entry.text)
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
private struct JournalThumbnailImage: View {
    let attachmentID: UUID
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
            } else {
                Color.cobuxSurface2
            }
        }
        .task(id: attachmentID) {
            image = JournalAttachmentStore.thumbnail(for: attachmentID)
        }
    }
}
