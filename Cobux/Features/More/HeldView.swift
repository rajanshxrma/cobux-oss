import SwiftUI
import SwiftData

/// What he is holding — every unreleased keep, in one quiet place.
///
/// A collection, so it lives under Saved beside Liked and Volumes. Read-only
/// by nature: keeps are created only where his words return to him, and the
/// shelf just shows what he chose. Nothing here is due, counted, or graded —
/// the ladder's timing stays the deck's business; this page answers only
/// "what am I holding?"
///
/// Deliberately NOT gated by quiet words: this is him opening his own held
/// list — his deliberate act on his own record, the same reason the journal
/// feed is never censored. The lock applies (journal content), the quiet
/// list does not.
struct HeldView: View {
    @Query(filter: #Predicate<JournalKeep> { $0.releasedDate == nil },
           sort: \JournalKeep.createdDate, order: .reverse)
    private var keeps: [JournalKeep]
    @Environment(\.colorScheme) private var colorScheme
    /// The keep he tapped, resolved to its entry by one bounded fetch on the
    /// way in. This screen used to `@Query` the whole journal -- every row's
    /// full text -- to back a `NavigationLink` inside a context menu, which
    /// iOS renders as a menu item that never pushes; the row itself did
    /// nothing at all.
    @State private var openEntryID: UUID?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    var body: some View {
        JournalLocked {
            Group {
                if keeps.isEmpty {
                    CobuxEmptyStateView(
                        icon: "bookmark",
                        title: "Nothing held yet",
                        message: "When a passage of your own writing comes back to you, you can keep it — and it will live here while you hold it."
                    )
                } else {
                    List {
                        ForEach(keeps) { keep in
                            row(for: keep)
                        }
                    }
                }
            }
        }
        .navigationTitle("Held")
        // On the gate's own view, not inside it: a lock transition swaps the
        // content subtree, and a destination declared there goes with it.
        // The entry screen wraps itself in the gate, so it is covered either way.
        .navigationDestination(item: $openEntryID) { entryID in
            HeldEntryDestination(entryID: entryID)
        }
    }

    @ViewBuilder
    private func row(for keep: JournalKeep) -> some View {
        let hue = Color.cobuxMonthHue(
            Calendar.current.component(.month, from: keep.sourceDate),
            dark: colorScheme == .dark)
        Button {
            openEntryID = keep.entryID
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text("You kept this · \(Self.dateFormatter.string(from: keep.sourceDate))")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .kerning(0.7)
                    .foregroundStyle(hue)
                Text(keep.passage)
                    .font(CobuxTypography.passage(size: 16))
                    .lineSpacing(4)
                    .lineLimit(4)
                if let question = keep.question, !question.isEmpty {
                    Text(question)
                        .font(CobuxTypography.passage(size: 14))
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                openEntryID = keep.entryID
            } label: {
                Label("Open entry", systemImage: "chevron.up")
            }
            // Marking, never deleting -- the record that he once held this
            // is itself his. Same rule as everywhere keeps appear.
            Button {
                keep.releasedDate = .now
            } label: {
                Label("Release this keep", systemImage: "hands.sparkles")
            }
        }
    }
}

/// Resolves a keep's entry with one indexed fetch and opens it -- or says
/// so plainly when there is nothing to open (a restore can leave a keep
/// pointing at an entry that is not in this store), rather than pushing a
/// blank screen. The detail view gates itself behind the lock.
private struct HeldEntryDestination: View {
    let entryID: UUID
    @Environment(\.modelContext) private var modelContext
    @State private var entry: PersonalWritingEntry?
    @State private var resolved = false

    var body: some View {
        Group {
            if let entry {
                JournalEntryDetailView(entry: entry)
            } else if resolved {
                CobuxEmptyStateView(
                    icon: "bookmark.slash",
                    title: "Nothing to open",
                    message: "The entry this keep came from isn't in your journal right now. The passage you kept is still here."
                )
            } else {
                ProgressView()
            }
        }
        .task(id: entryID) {
            // One row by id, never the table.
            let id = entryID
            var descriptor = FetchDescriptor<PersonalWritingEntry>(
                predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            entry = (try? modelContext.fetch(descriptor))?.first
            resolved = true
        }
    }
}
