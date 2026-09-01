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
    /// Set by Cancel so the auto-save below knows the dismissal was a deliberate
    /// discard rather than the user simply leaving.
    @State private var didCancel = false
    @Environment(\.scenePhase) private var scenePhase
    /// Today's mindful minutes / last night's sleep, loaded once when compose
    /// opens. `nil` until loaded AND whenever Health has nothing readable, so
    /// the row simply never appears rather than flashing an empty state.
    @State private var healthContext: HealthContext?

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

    /// "January 1, 2026" -- the date half of a session stamp, in exactly the
    /// format Rajan specified. Separate from `timeFormatter` so the same-day
    /// rule below can drop the date alone while keeping the time.
    private static let stampDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    /// The line a writing session opens with. His rule: the automatic time
    /// should also carry the date ("January 1, 2026" style) -- EXCEPT when
    /// it would just repeat a date the entry already establishes, where the
    /// bare time is enough. A brand-new entry's first session and a
    /// "Continue Entry" happening on a later day both get the full stamp; a
    /// same-day continuation gets time only.
    private static func sessionStamp(at date: Date, previousSessionDate: Date?) -> String {
        let time = timeFormatter.string(from: date)
        if let previousSessionDate, Calendar.current.isDate(previousSessionDate, inSameDayAs: date) {
            return time
        }
        return stampDateFormatter.string(from: date) + " · " + time
    }

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

    /// When this writing session opened -- the delta to Save is what
    /// accumulates into `PersonalWritingEntry.writingSeconds` for the detail
    /// view's stats bar.
    private let sessionStart = Date.now

    init(existingEntry: PersonalWritingEntry? = nil) {
        self.existingEntry = existingEntry
        if let existingEntry {
            // A blank line separates this session from whatever came before it
            // -- reads as a new dated addition, not text spliced mid-paragraph
            // into the last thing that was written. The stamp carries the date
            // only when this continuation lands on a DIFFERENT day than the
            // entry's last session -- same-day additions read as times within
            // one day, exactly like a paper journal.
            let stamp = Self.sessionStamp(
                at: .now,
                previousSessionDate: existingEntry.modifiedDate ?? existingEntry.dateImported
            )
            _title = State(initialValue: existingEntry.title)
            let seeded = existingEntry.text + "\n\n" + stamp + "\n"
            self.seededText = seeded
            // A surviving draft means the last session DIED mid-write (Save
            // and Cancel both clear it) -- pick the text back up rather than
            // seeding fresh over it. Only when the draft still extends THIS
            // entry's current text: if the entry changed since (saved from
            // another path), the draft is stale and silently dropped.
            // `seededText` stays the fresh seed either way, so recovered
            // text counts as a real change and Save lights up immediately.
            if let draft = JournalDraftStore.load(entryID: existingEntry.id),
               draft.text.hasPrefix(existingEntry.text),
               draft.text.count > seeded.count {
                _text = State(initialValue: draft.text)
                if !draft.title.isEmpty { _title = State(initialValue: draft.title) }
            } else {
                _text = State(initialValue: seeded)
            }
        } else {
            // First session of a brand-new entry: nothing above it establishes
            // the date, so the stamp always carries it.
            let stamp = Self.sessionStamp(at: .now, previousSessionDate: nil)
            _title = State(initialValue: "")
            let seeded = stamp + "\n"
            self.seededText = seeded
            // Same recovery for a brand-new entry that never got saved --
            // the exact shape of the 26 Aug loss. Any draft meaningfully
            // longer than a bare stamp line is real writing.
            if let draft = JournalDraftStore.load(entryID: nil),
               draft.text.trimmingCharacters(in: .whitespacesAndNewlines).count > seeded.trimmingCharacters(in: .whitespacesAndNewlines).count {
                _text = State(initialValue: draft.text)
                if !draft.title.isEmpty { _title = State(initialValue: draft.title) }
            } else {
                _text = State(initialValue: seeded)
            }
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
                    Button("Cancel") {
                        // An explicit Cancel is an intentional discard -- the
                        // draft must die with it, or the next compose open
                        // would resurrect text the user just chose to throw
                        // away. (A crash clears nothing; that's the one path
                        // that leaves a draft behind, by design.)
                        didCancel = true
                        JournalDraftStore.clear(entryID: existingEntry?.id)
                        dismiss()
                    }
                }
                // Photos join an entry from the toolbar, the way Apple's own
                // Journal offers media -- keeping the writing page itself
                // free of chrome. The strip of already-attached photos only
                // appears once there's at least one to show.
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 10, matching: .images) {
                        Image(systemName: "photo.badge.plus")
                    }
                    .disabled(isLocked)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(didSave || isLocked || !hasRealChanges)
                }
            }
        }
        .sensoryFeedback(.success, trigger: didSave)
        // Leaving the screen SAVES, the way Notes does -- his ask: "even if you
        // close the Notes app the note is still saved... I have to hit the Save
        // button up on top for it to get saved."
        //
        // A draft already survived a crash, but a draft is not an entry: it only
        // reappears if you open compose again, so swiping the sheet away still
        // lost the writing. Committing on the way out makes Save a convenience
        // rather than the only thing standing between him and losing an entry.
        //
        // Cancel is untouched and still discards -- that is an explicit "throw
        // this away", and auto-saving over it would be worse than the bug.
        .onDisappear {
            guard !didCancel, !didSave, hasRealChanges, !isLocked else { return }
            save()
        }
        // Backgrounding is the other way writing disappears: the sheet stays
        // presented, so onDisappear never fires, and iOS can terminate the app
        // while suspended without any further warning.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background, !didCancel, !didSave, hasRealChanges, !isLocked else { return }
            save()
        }
    }

    /// One page, one scroll view -- the Apple Notes shape. The entry editor
    /// fills everything below a fixed header and owns ALL scrolling itself.
    ///
    /// This used to be a `Form`: the `UITextView` (itself a scroll view) sat
    /// inside the Form's `List` (another scroll view) behind a
    /// `.frame(minHeight:)`, so every keystroke near the bottom had three
    /// systems adjusting offsets for the same caret -- the row re-measuring,
    /// SwiftUI keyboard avoidance moving the OUTER list, and the text view
    /// scrolling its own content. That tug-of-war is the up-and-down judder
    /// he reported three times ("it moves up and down and sometimes the
    /// keyboard hides it") and it's structural -- no amount of tuning the
    /// scroll calls fixes nested scroll views. Notes never judders because
    /// its text view IS the page; this now matches. The keyboard shrinks the
    /// editor's frame exactly once when it appears, and after that nothing
    /// outside the text view moves while typing.
    private var composeForm: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("What's on your mind?", text: $title)
                    .font(.title3.weight(.semibold))
                // How the body was doing while this was written. Read-only
                // context beside your own words, never a prompt or a score --
                // see `HealthContextService` for why it's HealthKit and not
                // the WHOOP numbers on the Mac. Absent entirely when Health
                // has nothing to say or permission was declined.
                if let line = healthContext?.summaryLine {
                    Label(line, systemImage: "heart.text.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            // Attached photos, only once there are any -- adding the first
            // one happens from the toolbar, so an entry with no photos gives
            // its whole page to the writing.
            if !visibleExistingAttachments.isEmpty || !pendingAttachments.isEmpty {
                photoStrip
                    .padding(.vertical, 6)
                Divider()
            }

            CursorEndTextEditor(text: $text, font: composeFont)
        }
        .background(Color.cobuxBackground)
        .task {
            // Fire-and-forget: a slow or unavailable HealthKit must never delay
            // the compose screen appearing.
            if healthContext == nil, HealthContextService.isAvailable, HealthContextService.isEnabled {
                healthContext = await HealthContextService.currentContext()
            }
        }
        .task {
            guard let existingEntry else { return }
            for attachment in existingEntry.attachments {
                existingAttachmentImages[attachment.id] = JournalAttachmentStore.image(for: attachment.id)
            }
        }
        // The crash-safe mirror: every edit lands in the draft file (throttled
        // inside the store), so the app dying mid-write costs seconds, not the
        // session. See `JournalDraftStore`'s own doc comment for the two real
        // losses this exists because of.
        .onChange(of: text) { _, newText in
            JournalDraftStore.save(entryID: existingEntry?.id, title: title, text: newText)
        }
        .onChange(of: title) { _, newTitle in
            JournalDraftStore.save(entryID: existingEntry?.id, title: newTitle, text: text)
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
        // How long this sheet was open, credited to the entry's lifetime
        // writing time (the detail view's stats bar). Sheet-open time IS the
        // honest measure here -- pauses to think are part of writing --
        // capped at 3 hours so a sheet forgotten open overnight can't turn
        // the stat into nonsense.
        let sessionSeconds = min(Int(Date.now.timeIntervalSince(sessionStart)), 3 * 60 * 60)
        let entry: PersonalWritingEntry
        if let existingEntry {
            existingEntry.title = trimmedTitle
            existingEntry.text = finalText
            existingEntry.modifiedDate = .now
            existingEntry.writingSeconds = (existingEntry.writingSeconds ?? 0) + sessionSeconds
            existingEntry.embedding = EmbeddingService.embed(finalText)
            entry = existingEntry
        } else {
            let newEntry = PersonalWritingEntry(
                source: "journal",
                title: trimmedTitle,
                text: finalText,
                modifiedDate: .now
            )
            newEntry.writingSeconds = sessionSeconds
            newEntry.embedding = EmbeddingService.embed(finalText)
            modelContext.insert(newEntry)
            entry = newEntry
        }
        // Committed -- the crash-safe mirror has served its purpose.
        JournalDraftStore.clear(entryID: existingEntry?.id)

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
        // Distinct from `recordActivityToday` -- that counts ANY engagement
        // (a quiz, a highlight, opening Flow), while the Journal widget needs
        // "did they actually write today," which is a narrower thing.
        StreakTracker.markJournalEntryWritten()
        StreakCelebrationCenter.shared.checkForPendingMilestone()
        // Push the entry out to iCloud NOW, not on the next opportunistic sweep.
        // An entry he wrote an hour ago being unreachable is the actual
        // complaint; every other trigger is a timer, and a timer is what made
        // it feel broken next to Reminders.
        JournalAutoExportService.exportAfterWrite(modelContext: modelContext)
        WatchSyncService.sync(books: books)
        WidgetCenter.shared.reloadAllTimelines()

        didSave = true
        dismiss()
    }
}
