import SwiftData
import SwiftUI

/// Situations, as a destination rather than a section someone scrolls past.
///
/// It first shipped inside the thread picker, between the journal row and the
/// book categories — which Rajan read correctly as unfindable: *"it's hidden up
/// in the chat really simply... I don't think a user is gonna ever find it."*
/// A feature nobody discovers is not a feature, which is the same lesson Flow
/// taught: it became something people use once it was one obvious tap away.
///
/// The privacy posture is unchanged and load-bearing (see `SituationThread`):
/// nothing here is auto-created, nothing is extracted from messages, and the
/// only things stored are the transcript and a note the user writes. Deleting a
/// situation deletes its conversation with it — journal entries are permanent
/// because they are his own writing; a situation is the opposite, because it is
/// about somebody else.
struct SituationsView: View {
    @Binding var selectedBookID: UUID?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \SituationThread.lastActivityDate, order: .reverse)
    private var situations: [SituationThread]
    @State private var showingNew = false
    @State private var newName = ""

    private let accent = Color.cobuxSituation

    var body: some View {
        NavigationStack {
            Group {
                if situations.isEmpty { emptyState } else { list }
            }
            .navigationTitle("Situations")
            .navigationBarTitleDisplayMode(.inline)
            .background(Color.cobuxBackground)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newName = ""; showingNew = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New situation")
                }
            }
            .alert("New situation", isPresented: $showingNew) {
                // A nickname is offered on purpose: the app must never require
                // a real person's real name to be typed into it.
                TextField("A name, a nickname, 'the situationship'", text: $newName)
                Button("Cancel", role: .cancel) { }
                Button("Create") { create() }
            } message: {
                Text("A thread of its own, so the context stays together. Nothing is saved about anyone — only what you write here.")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 42))
                .foregroundStyle(accent)
                .symbolRenderingMode(.hierarchical)
            Text("Something you're working through")
                .font(CobuxTypography.display(colorScheme, size: 22, weight: .semibold))
                .multilineTextAlignment(.center)
            Text("Give an ongoing thing with someone its own thread, so the whole story stays in one place instead of scattering between book questions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { newName = ""; showingNew = true } label: {
                Label("New situation", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(CobuxSpacing.screenMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(situations) { situation in
                Button {
                    selectedBookID = situation.id
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(situation.name)
                                .font(CobuxTypography.display(colorScheme, size: 17, weight: .medium))
                                .foregroundStyle(.primary)
                            if let note = situation.note, !note.isEmpty {
                                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            // Date only, never an excerpt: transcripts about
                            // real people carry nothing into a list; the name
                            // he chose is already the identity. Same rule
                            // `ThreadResume` proves in the harness.
                            Text(situation.lastActivityDate.formatted(.relative(presentation: .named)))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if selectedBookID == situation.id {
                            Image(systemName: "checkmark").foregroundStyle(accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in offsets.forEach { delete(situations[$0]) } }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let thread = SituationThread(name: name)
        modelContext.insert(thread)
        selectedBookID = thread.id
        dismiss()
    }

    /// Deleting a situation deletes its conversation too. Leaving the messages
    /// behind would keep a record of a real person after he chose to end it,
    /// which is exactly what this feature promises not to do.
    private func delete(_ situation: SituationThread) {
        let threadID = situation.id
        // Before the rows go, not after: the photos live on disk, and once the
        // messages that reference them are deleted there is nothing left to
        // find them by. Deleting the conversation but leaving the pictures is
        // the same broken promise as leaving the messages.
        ChatImageStore.removeImages(inThread: threadID, context: modelContext)
        try? modelContext.delete(model: ChatMessage.self,
                                 where: #Predicate { $0.bookID == threadID })
        if selectedBookID == threadID { selectedBookID = nil }
        modelContext.delete(situation)
    }
}
