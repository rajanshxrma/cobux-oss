import SwiftUI
import SwiftData
import WidgetKit
import PhotosUI

/// Writing a new entry, or continuing an existing one, in-app, on the same
/// day it happened. Apple's own Journal app has no read API for a third-party
/// app at all -- nothing can sync from it in either direction -- so the only
/// way Cobux ever gets a journal to reason about is if the entry is written
/// here in the first place. Saves straight into `PersonalWritingEntry`, the
/// exact model chat already draws lived examples from
/// (`SearchService.personalWritingContextBlock`) -- a journal written here is
/// immediately as useful to chat as an entry imported from Notes, with no
/// separate pipeline.
///
/// Every session -- a brand-new entry or picking an old one back up -- starts
/// from a fresh timestamp with the cursor already on the line under it,
/// rather than a blank page (new) or the cursor wherever the text last
/// happened to end (continuing). Rajan's own framing: opening a journal
/// should always show *when this writing session started*, the same way a
/// physical notebook entry starts with today's date whether the page is
/// otherwise empty or already half full.
struct JournalEntryComposeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Query private var books: [Book]

    /// `nil` composes a brand-new entry. Non-nil continues an existing one --
    /// appends a fresh timestamp and saves back to the SAME row, rather than
    /// creating a second entry for what's really one continuous journal.
    let existingEntry: PersonalWritingEntry?

    @State private var title: String
    @State private var text: String
    @State private var didSave = false

    /// Captured at `init` time -- comparing against this (not against an
    /// empty string) is what "did the user actually write anything" means
    /// here, since `text` is never truly empty: it always starts seeded with
    /// a timestamp. Without this, tapping Save the instant the sheet opens
    /// created a real, embedded, chat-visible entry whose entire body was a
    /// bare time (e.g. "9:41 PM"), and "Continue Entry" -> Save with no
    /// actual addition silently rewrote a real entry's `modifiedDate` for
    /// nothing.
    private let seededText: String

    // Minimal, read-only lock check -- same "cheap duplication for one local
    // decision" pattern as `JournalListView`'s own copy, not the full gate
    // mechanism (that's `JournalLocked` below). Needed here specifically so
    // Save can't be tapped while the lock gate is covering the form: if
    // locked, `text`/`title` are exactly whatever `init` seeded (the editor
    // itself isn't even rendered), and without this guard a relock mid-type
    // followed by an accidental Save would commit that seeded placeholder.
    @AppStorage(JournalLockStatus.enabledKey) private var lockEnabled = true
    @State private var lockStatus = JournalLockStatus.shared
    private var isLocked: Bool { lockEnabled && !lockStatus.isUnlocked }

    /// Every attachment change here is staged in local state, not applied to
    /// `modelContext` directly, so Cancel stays a true no-op -- the same
    /// "nothing commits until Save" discipline `title`/`text` already follow
    /// as plain `@State`, just extended to photos. `save()` is where
    /// `pendingAttachments` become real `JournalAttachment` rows and
    /// `removedAttachmentIDs` actually get deleted.
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var removedAttachmentIDs: Set<UUID> = []
    /// Decoded once per existing attachment (`.task` below), not inline in
    /// the view body -- `JournalAttachmentStore.image(for:)` is a real disk
    /// read + JPEG decode, and a body property re-evaluates on every render.
    @State private var existingAttachmentImages: [UUID: UIImage] = [:]

    private struct PendingAttachment: Identifiable {
        let id = UUID()
        let image: UIImage
        let data: Data
    }

    /// Existing attachments still visible -- filters out anything the user
    /// tapped delete on this session, without touching `modelContext` yet.
    private var visibleExistingAttachments: [JournalAttachment] {
        (existingEntry?.attachments ?? []).filter { !removedAttachmentIDs.contains($0.id) }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    /// A blank title is fine -- browsing falls back to the entry's date
    /// (`JournalListView.displayTitle`), the same convention a plain daily
    /// journal already reads by.
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Matches `CobuxTypography.display()`'s own light-mode serif / dark-mode
    /// default split, bridged into `UIFont` for `CursorEndTextEditor` -- an
    /// entry reads in the same editorial type while being written as it does
    /// afterward in `JournalEntryDetailView`.
    private var composeFont: UIFont {
        let bodyDescriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
        guard colorScheme != .dark, let serifDescriptor = bodyDescriptor.withDesign(.serif) else {
            return UIFont(descriptor: bodyDescriptor, size: 0)
        }
        return UIFont(descriptor: serifDescriptor, size: 0)
    }

    /// Whether there's actually something new to save -- see `seededText`'s
    /// doc comment for why a bare non-empty `text` isn't enough on its own.
    /// Also true for a photo added or removed with the seeded text otherwise
    /// untouched -- without this, attaching a photo to an unchanged
    /// "Continue Entry" session would leave Save disabled with no way to
    /// actually commit the photo.
    private var hasRealChanges: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) != seededText.trimmingCharacters(in: .whitespacesAndNewlines)
            || !pendingAttachments.isEmpty
            || !removedAttachmentIDs.isEmpty
    }

    init(existingEntry: PersonalWritingEntry? = nil) {
        self.existingEntry = existingEntry
        let timestamp = Self.timeFormatter.string(from: .now)
        if let existingEntry {
            // A blank line separates this session from whatever came before it
            // -- reads as a new dated addition, not text spliced mid-paragraph
            // into the last thing that was written.
            _title = State(initialValue: existingEntry.title)
            let seeded = existingEntry.text + "\n\n" + timestamp + "\n"
            _text = State(initialValue: seeded)
            self.seededText = seeded
        } else {
            _title = State(initialValue: "")
            let seeded = timestamp + "\n"
            _text = State(initialValue: seeded)
            self.seededText = seeded
        }
    }

    var body: some View {
        NavigationStack {
            // The lock check sits INSIDE the `NavigationStack`, not wrapping
            // it, so Cancel stays reachable (an escape hatch) even if a
            // relock lands while this sheet happens to be open with nothing
            // typed yet -- unlike `JournalListView`/`JournalEntryDetailView`,
            // there's no "Continue Entry"-style nested sheet here for this
            // view's own `JournalLocked` to yield to, so
            // `autoPromptsWhenTopmost` stays at its default `true`: nothing
            // is ever presented on top of this compose sheet.
            JournalLocked {
                composeForm
            }
            .navigationTitle(existingEntry == nil ? "New Journal Entry" : "Continue Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(didSave || isLocked || !hasRealChanges)
                }
            }
        }
        .sensoryFeedback(.success, trigger: didSave)
    }

    private var composeForm: some View {
        Form {
            Section("Title (Optional)") {
                TextField("What's on your mind?", text: $title)
            }

            Section("Entry") {
                CursorEndTextEditor(text: $text, font: composeFont)
                    .frame(minHeight: 280)
            }

            Section("Photos") {
                photoStrip
            }
        }
        .task {
            guard let existingEntry else { return }
            for attachment in existingEntry.attachments {
                existingAttachmentImages[attachment.id] = JournalAttachmentStore.image(for: attachment.id)
            }
        }
        .onChange(of: selectedPhotoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            let itemsToLoad = newItems
            selectedPhotoItems = []
            Task {
                for item in itemsToLoad {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { continue }
                    pendingAttachments.append(PendingAttachment(image: image, data: data))
                }
            }
        }
    }

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(visibleExistingAttachments) { attachment in
                    attachmentThumbnail(image: existingAttachmentImages[attachment.id]) {
                        removedAttachmentIDs.insert(attachment.id)
                    }
                }
                ForEach(pendingAttachments) { pending in
                    attachmentThumbnail(image: pending.image) {
                        pendingAttachments.removeAll { $0.id == pending.id }
                    }
                }
                PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 10, matching: .images) {
                    VStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.title2)
                        Text("Add")
                            .font(.caption2)
                    }
                    .frame(width: 72, height: 72)
                    .foregroundStyle(Color.cobuxAccent)
                    .background(Color.cobuxSurface2)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.vertical, 4)
        }
        .listRowInsets(EdgeInsets())
        .padding(.horizontal, 16)
    }

    private func attachmentThumbnail(image: UIImage?, onDelete: @escaping () -> Void) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.cobuxSurface2
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .padding(4)
        }
    }

    private func save() {
        // Same double-tap guard `AddHighlightView`/`AddChapterView`/
        // `AddBookView` already use -- a fast second tap in the moment
        // before the sheet dismisses would otherwise append a duplicate.
        guard !didSave else { return }

        let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry: PersonalWritingEntry
        if let existingEntry {
            existingEntry.title = trimmedTitle
            existingEntry.text = finalText
            existingEntry.modifiedDate = .now
            existingEntry.embedding = EmbeddingService.embed(finalText)
            entry = existingEntry
        } else {
            let newEntry = PersonalWritingEntry(
                source: "journal",
                title: trimmedTitle,
                text: finalText,
                modifiedDate: .now
            )
            newEntry.embedding = EmbeddingService.embed(finalText)
            modelContext.insert(newEntry)
            entry = newEntry
        }

        // Attachment deletes/adds both apply here, at the same moment the
        // rest of the entry actually commits -- see the `@State` properties'
        // own doc comment for why Cancel must not have touched any of this.
        for attachment in entry.attachments where removedAttachmentIDs.contains(attachment.id) {
            JournalAttachmentStore.delete(id: attachment.id)
            modelContext.delete(attachment)
        }
        for pending in pendingAttachments {
            let attachment = JournalAttachment(entry: entry)
            modelContext.insert(attachment)
            JournalAttachmentStore.save(pending.data, id: attachment.id)
        }

        try? modelContext.save()

        // Writing an entry is exactly the "showed up today" activity the
        // streak already exists to reward -- same call `AddHighlightView`'s
        // save path makes, so a journal-only day keeps the streak alive
        // exactly like a highlight-only or quiz-only day already does.
        StreakTracker.recordActivityToday()
        StreakCelebrationCenter.shared.checkForPendingMilestone()
        WatchSyncService.sync(books: books)
        WidgetCenter.shared.reloadAllTimelines()

        didSave = true
        dismiss()
    }
}
