import SwiftData
import SwiftUI

/// The chat thread picker, presented as a sheet rather than a `Menu`.
///
/// The old toolbar `Menu` listed "General" + every book as inline `Button`s.
/// That works fine for a handful of items, but with the library at 15+ books
/// a flat `Menu`'s native dropdown scroll becomes unreliable on real
/// devices — confirmed live by Rajan ("the scroll of this dropdown is
/// cooked"). A `List` inside a sheet uses the same scrolling machinery as
/// every other list in the app (Library, Quiz Home) instead of `Menu`'s
/// separate, less-tested-at-scale scroll path, and gets a free search field
/// for finding one book in a long library.
struct BookThreadPickerView: View {
    @Query(sort: \SituationThread.lastActivityDate, order: .reverse)
    private var situations: [SituationThread]
    @Environment(\.modelContext) private var modelContext
    @State private var showingNewSituation = false
    @State private var newSituationName = ""

    let books: [Book]
    @Binding var selectedBookID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var sortedBooks: [Book] {
        books.sorted { $0.title < $1.title }
    }

    private var filteredBooks: [Book] {
        guard !searchText.isEmpty else { return sortedBooks }
        return sortedBooks.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    /// Situations are destinations in this picker exactly as books are, and
    /// search used to filter the books alone -- so typing anything at all made
    /// every situation thread vanish, including the one whose name was being
    /// typed. Naming a situation and then searching for that name returned
    /// nothing, which is the one search a situation's name is for.
    private var filteredSituations: [SituationThread] {
        guard !searchText.isEmpty else { return situations }
        return situations.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// The general thread is the third destination search could hide; it is
    /// matched on the same substring rule as everything else here.
    private var generalMatchesSearch: Bool {
        "General".localizedCaseInsensitiveContains(searchText)
    }

    private var journalMatchesSearch: Bool {
        "My Journal".localizedCaseInsensitiveContains(searchText)
    }

    /// Whether a search matched no destination at all -- the state this sheet
    /// used to render as a blank list.
    private var searchFoundNothing: Bool {
        !searchText.isEmpty && !generalMatchesSearch && !journalMatchesSearch
            && filteredSituations.isEmpty && filteredBooks.isEmpty
    }

    /// Books grouped by `category` for the browsing (non-search) layout —
    /// each section's books sorted by title, sections sorted alphabetically
    /// by category name, with any `category == nil` books collected into a
    /// trailing "Other" section rather than dropped. Only used when
    /// `searchText` is empty; search results stay a flat filtered list (see
    /// `filteredBooks`) since grouping only helps browsing, not searching.
    private var groupedBooks: [(category: String, books: [Book])] {
        let grouped = Dictionary(grouping: sortedBooks) { $0.category ?? "Other" }
        return grouped
            .sorted { lhs, rhs in
                if lhs.key == "Other" { return false }
                if rhs.key == "Other" { return true }
                return lhs.key < rhs.key
            }
            .map { (category: $0.key, books: $0.value.sorted { $0.title < $1.title }) }
    }

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty {
                    row(title: "General", isSelected: selectedBookID == nil) {
                        selectedBookID = nil
                        dismiss()
                    }
                    // Pinned above the book sections: the journal thread is a
                    // surface of its own, not a book in a category. Selecting
                    // it while the journal is Face-ID locked is fine -- the
                    // lock is enforced where the content shows (`ChatView`
                    // wraps this thread in `JournalLocked`, which auto-prompts
                    // on arrival), so this row stays a plain selection.
                    row(title: "My Journal", isSelected: selectedBookID == ChatPromptBuilder.journalThreadID,
                        // The journal id is passed so this row keys to a line
                        // that NEVER exists -- without it the nil default
                        // would key to the general thread and print the
                        // general chat's last line on the journal row.
                        threadID: ChatPromptBuilder.journalThreadID) {
                        selectedBookID = ChatPromptBuilder.journalThreadID
                        dismiss()
                    }
                    // Situations sit between the journal and the library: they
                    // are threads about his own life, like the journal, rather
                    // than about a book. Creation is always a deliberate tap --
                    // nothing here is ever auto-created from a conversation.
                    Section {
                        ForEach(situations) { situation in
                            row(title: situation.name,
                                isSelected: selectedBookID == situation.id,
                                threadID: situation.id) {
                                selectedBookID = situation.id
                                dismiss()
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { delete(situations[index]) }
                        }
                        Button {
                            newSituationName = ""
                            showingNewSituation = true
                        } label: {
                            Label("New situation", systemImage: "plus")
                                .font(.subheadline)
                        }
                        .buttonStyle(.plain)
                    } header: {
                        Text("Situations")
                            .font(CobuxTypography.cobuxSectionHeader)
                    }

                    ForEach(groupedBooks, id: \.category) { group in
                        Section {
                            ForEach(group.books) { book in
                                row(title: book.title, isSelected: selectedBookID == book.id,
                                    threadID: book.id) {
                                    selectedBookID = book.id
                                    dismiss()
                                }
                            }
                        } header: {
                            Text(group.category)
                                .font(CobuxTypography.cobuxSectionHeader)
                        }
                    }
                } else if searchFoundNothing {
                    // This sheet used to render an empty `List` -- a blank
                    // sheet that looks broken rather than answered.
                    CobuxEmptyStateView(
                        icon: "magnifyingglass",
                        title: "Nothing by that name",
                        message: "No thread here matches \u{201C}\(searchText)\u{201D}. Try part of a book's title, or the name you gave a situation."
                    )
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    // Search results keep the browsing order -- general,
                    // journal, situations, books -- so a filtered list reads
                    // as the same sheet with rows removed rather than a
                    // different one.
                    if generalMatchesSearch {
                        row(title: "General", isSelected: selectedBookID == nil) {
                            selectedBookID = nil
                            dismiss()
                        }
                    }
                    // The pinned journal row stays findable under search too --
                    // same substring rule the books get.
                    if journalMatchesSearch {
                        row(title: "My Journal", isSelected: selectedBookID == ChatPromptBuilder.journalThreadID,
                        // The journal id is passed so this row keys to a line
                        // that NEVER exists -- without it the nil default
                        // would key to the general thread and print the
                        // general chat's last line on the journal row.
                        threadID: ChatPromptBuilder.journalThreadID) {
                            selectedBookID = ChatPromptBuilder.journalThreadID
                            dismiss()
                        }
                    }
                    ForEach(filteredSituations) { situation in
                        row(title: situation.name,
                            isSelected: selectedBookID == situation.id,
                            threadID: situation.id) {
                            selectedBookID = situation.id
                            dismiss()
                        }
                    }
                    ForEach(filteredBooks) { book in
                        row(title: book.title, isSelected: selectedBookID == book.id,
                            threadID: book.id) {
                            selectedBookID = book.id
                            dismiss()
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.cobuxBackground)
            .task { loadResumeLines() }
            .alert("New situation", isPresented: $showingNewSituation) {
                // Placeholder offers a nickname on purpose: the app must never
                // require a real person's real name to be typed into it.
                TextField("A name, a nickname, 'the situationship'", text: $newSituationName)
                Button("Cancel", role: .cancel) { }
                Button("Create") {
                    let name = newSituationName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    let thread = SituationThread(name: name)
                    modelContext.insert(thread)
                    selectedBookID = thread.id
                    dismiss()
                }
            } message: {
                Text("A thread of its own, so the context stays together. Nothing is saved about anyone — only what you write here.")
            }
            // "Find a book" described one of the four kinds of destination on
            // this sheet, and search now really does cover all of them.
            .searchable(text: $searchText, prompt: "Find a thread")
            .navigationTitle("Chat Thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(title: String, isSelected: Bool, threadID: UUID? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    BookTitleText(title: title, font: .body, weight: isSelected ? .semibold : .regular, color: .primary)
                    // Where we left off: relative date + the last line, so he
                    // can tell which thread holds which conversation before
                    // entering it. Quote-and-date, never a summary; the rules
                    // (journal contributes nothing, situations date-only)
                    // live in `ThreadResume` where the harness proves them.
                    if let line = resumeLines[threadID] {
                        Text(resumeText(for: line))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.cobuxAccent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.cobuxSurface)
    }

    @State private var resumeLines: [UUID?: ThreadResume.Line] = [:]

    private func resumeText(for line: ThreadResume.Line) -> String {
        let date = line.date.formatted(.relative(presentation: .named))
        guard let excerpt = line.excerpt, !excerpt.isEmpty else { return date }
        return "\(date) · \u{201C}\(excerpt)\u{201D}"
    }

    /// One bounded fetch when the sheet opens -- a sheet, never the chat
    /// scroll path.
    private func loadResumeLines() {
        var descriptor = FetchDescriptor<ChatMessage>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = 800
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        let stubs = rows.map {
            ThreadResume.MessageStub(content: $0.content, bookID: $0.bookID,
                                     timestamp: $0.timestamp)
        }
        resumeLines = ThreadResume.resumeLines(
            messages: stubs,
            journalThreadID: ChatPromptBuilder.journalThreadID,
            situationIDs: Set(situations.map(\.id)))
    }

    /// Deleting a situation deletes its conversation too.
    ///
    /// Leaving the messages behind would keep a record of a real person after
    /// he chose to end it — which is exactly the thing this feature promises
    /// not to do. Journal entries are permanent by design; a situation thread
    /// is the opposite by design, and the difference is that one is his writing
    /// and the other is about somebody else.
    private func delete(_ situation: SituationThread) {
        let threadID = situation.id
        // Before the rows go, not after — see the same call in `SituationsView`.
        // The JPEGs are only reachable through the messages' `imageIDs`.
        ChatImageStore.removeImages(inThread: threadID, context: modelContext)
        try? modelContext.delete(model: ChatMessage.self,
                                 where: #Predicate { $0.bookID == threadID })
        if selectedBookID == threadID { selectedBookID = nil }
        modelContext.delete(situation)
    }
}
