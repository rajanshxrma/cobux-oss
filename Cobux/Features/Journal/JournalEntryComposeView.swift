import SwiftUI
import SwiftData
import WidgetKit
import PhotosUI
import CryptoKit

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
    /// Whether the journal already holds an entry -- the ONE bit `lockArmed`
    /// needs from the store. `nil` until read.
    ///
    /// This sheet used to hold `@Query pastEntries: [PersonalWritingEntry]`
    /// (every entry, its full text AND its embedding vector, materialised on
    /// the main actor every time compose opened, and re-fetched on every
    /// store save while it was up) plus `@Query books` -- and the save path
    /// read `!lockArmed`, a boolean, never the array. The boolean is now a
    /// `COUNT`, read in the synchronous prefix of the `.task` below so it
    /// lands in the same main-actor turn as the first render; the prompt
    /// chips get their own bounded read (`loadPromptChips`).
    @State private var hasPastEntries: Bool?
    /// His own past writing, for the prompt chips. Apple Journal's "moments"
    /// are generated from photos and workouts; Cobux has three years of what
    /// he actually wrote, which is the thing Apple structurally cannot copy.
    /// Built once, in `.task`, never in `body` (`loadPromptChips`).
    @State private var promptChips: [(label: String, insert: String)] = []
    @State private var dismissedPrompts = false

    /// `nil` composes a brand-new entry. Non-nil continues an existing one --
    /// appends a fresh timestamp and saves back to the SAME row, rather than
    /// creating a second entry for what's really one continuous journal.
    let existingEntry: PersonalWritingEntry?

    @State private var title: String
    @State private var text: String
    @State private var didSave = false
    /// Flips only when an entry actually COMMITTED -- the success haptic's
    /// trigger. `didSave` also latches on the no-changes path (Done on an
    /// untouched sheet), and a success buzz for "nothing was written" would
    /// be a small lie every time.
    @State private var didCommit = false
    /// Set by Cancel so the auto-save below knows the dismissal was a deliberate
    /// discard rather than the user simply leaving.
    @State private var didCancel = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    /// Today's mindful minutes / last night's sleep, loaded once when compose
    /// opens. `nil` until loaded AND whenever Health has nothing readable, so
    /// the row simply never appears rather than flashing an empty state.
    @State private var healthContext: HealthContext?
    /// True while the weather stamp is on and location has never been asked;
    /// read once when the sheet appears (see the offer line in the header).
    @State private var showsWeatherOffer = false

    /// Captured at `init` time -- comparing against this (not against an
    /// empty string) is what "did the user actually write anything" means
    /// here, since `text` is never truly empty: it always starts seeded with
    /// a timestamp. Without this, tapping Done the instant the sheet opens
    /// created a real, chat-visible entry whose entire body was a bare
    /// stamp, and "Continue Entry" -> Done with no actual addition silently
    /// rewrote a real entry's `modifiedDate` for nothing. `save()` guards on
    /// `hasRealChanges` for exactly this; every path into it goes through
    /// that guard.
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
    /// The lock is armed by CONTENT, not by install -- `JournalLocked`'s
    /// `armed`. A journal with nothing in it has nothing to protect, so the
    /// very first entry is written without a Face ID demand at the door;
    /// continuing or answering an entry means one already exists. Unarmed
    /// until the count is read -- which is the same turn as the first frame,
    /// so nothing is ever shown unlocked that should not be; and on the one
    /// path where the count could fail to read, `hasPastEntries` is set TRUE,
    /// the safe direction.
    private var lockArmed: Bool { existingEntry != nil || answering != nil || (hasPastEntries ?? false) }
    private var isLocked: Bool { lockEnabled && lockArmed && !lockStatus.isUnlocked }

    /// Every attachment change here is staged in local state, not applied to
    /// `modelContext` directly, so Cancel stays a true no-op -- the same
    /// "nothing commits until Save" discipline `title`/`text` already follow
    /// as plain `@State`, just extended to photos. `save()` is where
    /// `pendingAttachments` become real `JournalAttachment` rows and
    /// `removedAttachmentIDs` actually get deleted.
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    /// How many picks are currently loading -- drives placeholder tiles so
    /// the strip never looks dead while iCloud originals download.
    @State private var photosLoading = 0
    /// Set when a pick produced nothing readable, so the failure is visible
    /// instead of the photo simply never appearing.
    @State private var photoLoadFailed = false
    @State private var recorder = JournalVoiceRecorder()
    /// The recorder could not start for a reason other than permission.
    @State private var recordingFailed = false
    /// Recording ids captured this session, promoted to real attachments on save
    /// -- same staged shape as `pendingAttachments`, so Cancel discards them.
    @State private var pendingVoiceNoteIDs: [UUID] = []
    /// The notes that have FINISHED recording this session, in order, with
    /// the length the recorder measured -- what the staged rows under the
    /// header card draw. Build 58, Rajan: "whenever I stop recording, the
    /// display does not show anything that would confirm there is a
    /// recording now saved; at the end when I hit Done it does get saved and
    /// I can play it." The recording existed on disk and in
    /// `pendingVoiceNoteIDs`; nothing on the page said so until the detail
    /// view. A note that is still recording is in `pendingVoiceNoteIDs` and
    /// not here; one that failed the length check is in neither.
    @State private var stagedVoiceNotes: [StagedVoiceNote] = []
    /// The one line of explanation before the phone asks about speech
    /// recognition -- `R-2026-09-location-asked-before-it-is-explained`'s
    /// rule applied to the transcript. Set when the first note is staged and
    /// only while the transcript path on this OS needs the permission and it
    /// has never been asked (`VoiceTranscriptionService.needsAuthorizationPrompt`);
    /// the ask itself happens in `save()`, after this line has been on screen.
    @State private var showsTranscriptExplanation = false
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var removedAttachmentIDs: Set<UUID> = []
    /// Decoded once per existing attachment (`.task` below), not inline in
    /// the view body -- a disk read + JPEG decode re-run on every render is
    /// what an inline read would be. From the 900px THUMBNAIL tier, off the
    /// main thread: the strip draws 72pt tiles, and the 1600px `image(for:)`
    /// decode was paying for a hero-sized bitmap per photo to draw a stamp.
    @State private var existingAttachmentImages: [UUID: UIImage] = [:]

    /// A finished, unsaved recording: its staging id (the file is already at
    /// `JournalAttachmentStore.audioURL(for: id)`) and its measured length.
    private struct StagedVoiceNote: Identifiable {
        let id: UUID
        let duration: TimeInterval
    }

    private struct PendingAttachment: Identifiable {
        let id = UUID()
        /// Display only -- a ~300px preview `PhotoLoader` decoded off-main
        /// with ImageIO, at the size the strip draws. This used to be
        /// `UIImage(data:)` of the raw picker bytes, retained until save: a
        /// 48MP HEIC inflates to ~190 MB, so ten picks was ~1.9 GB of
        /// full-resolution bitmaps, decoded on the main thread, to draw ten
        /// 72×72 tiles.
        let preview: UIImage?
        /// The original bytes. This, not the preview, is what
        /// `JournalAttachmentStore.save` downsamples and writes on save --
        /// only the DISPLAY path changed.
        let data: Data
    }

    /// Existing attachments still visible -- filters out anything the user
    /// tapped delete on this session, without touching `modelContext` yet.
    private var visibleExistingAttachments: [JournalAttachment] {
        (existingEntry?.attachments ?? []).filter { !removedAttachmentIDs.contains($0.id) }
    }

    private static func elapsedLabel(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// What the navigation bar is called -- and, for a new entry, nothing.
    ///
    /// It was "New Journal Entry", which truncated to "New Journa..." on his
    /// phone with the trailing controls in the bar, and would truncate at some
    /// text size no matter how the trailing side is trimmed. Rajan: "the top
    /// portion wehre it is the new jour and then dot dot dot looks congetsted".
    ///
    /// A title survives here on exactly the same rule this section already
    /// applies to the year in a feed header (`JournalListView.weekdayAndMonth`):
    /// it appears when it carries information, and not otherwise. On a new
    /// entry it carries none -- the page underneath is an empty editor already
    /// stamped with today's date, and naming that "New Journal Entry" is the bar
    /// telling the user what they can see. Continuing an entry and answering one
    /// both look like a page with writing already on it, and WHICH of those it
    /// is, is not visible; so those keep a name, at one short word each so
    /// nothing can truncate at any Dynamic Type size.
    private static func barTitle(answering: Bool, continuing: Bool) -> String {
        if answering { return "Write Back" }
        return continuing ? "Continue" : ""
    }

    /// The composer's two media doors: a photo, and a voice note.
    ///
    /// They were `.topBarTrailing` toolbar items until build 53, alongside Done
    /// -- three controls and a title in one bar, which is the congestion he
    /// named.
    ///
    /// NOT `.keyboard` placement, which is the obvious home for a composer's
    /// media controls and is wrong here: this sheet does not guarantee a
    /// keyboard. `CursorEndTextEditor.attemptFocus` takes focus exactly once and
    /// latches (`hasFocused`), and its own comment says why -- so it is "not a
    /// fight for focus on every re-render once it's already worked (or once the
    /// user has intentionally tapped elsewhere)". Once the keyboard is down it
    /// does not come back on its own, and a control that vanishes with it is a
    /// feature the user has to guess how to reach.
    ///
    /// This card is the first thing on the page and never scrolls -- the editor
    /// owns every pixel of scrolling, see `composeForm` -- so the row is present
    /// in every state the sheet has.
    ///
    /// Behaviour is byte-for-byte what the toolbar had: the same
    /// `$selectedPhotoItems` binding and `maxSelectionCount: 10`, the same
    /// `isLocked || photosLoading > 0` guard (a second pick during a slow iCloud
    /// download appended BOTH batches), the same `toggleRecording()`, the same
    /// accessibility labels. What is new is that both now say what they are
    /// instead of being bare glyphs, and both carry a real 44pt target.
    private var mediaRow: some View {
        HStack(spacing: CobuxSpacing.sm) {
            // NEVER SILENTLY DISABLED. This was `.disabled(isLocked || ...)`,
            // and so was the voice button below. `isLocked` is true whenever
            // the journal has content, the lock is on, and Face ID has not
            // been passed in THIS foreground session -- which is the state the
            // sheet opens in from the widget, from Messages, from a deep link,
            // and after any backgrounding (`relock()` runs on every
            // background). A disabled quiet chip looks exactly like an enabled
            // one at a glance, so tapping it did nothing and said nothing.
            // That is the whole of "the add picture not working ... NEVER"
            // -- reported three times, "fixed" twice in the photo loader,
            // which was never the part that was broken. Same for "the voice
            // is not getting recorded, when I click the button nothing
            // happens". Both controls now ask for Face ID on tap, the way the
            // rest of the journal already does, and then proceed.
            if isLocked {
                Button {
                    Task { await lockStatus.authenticate() }
                } label: {
                    Label("Photo", systemImage: "photo.badge.plus")
                        .foregroundStyle(Color.cobuxAccent)
                        .cobuxQuietChip(tint: Color.cobuxAccent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a photo, unlocks the journal first")
            } else {
                PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 10, matching: .images) {
                    Label("Photo", systemImage: "photo.badge.plus")
                        .foregroundStyle(Color.cobuxAccent)
                        .cobuxQuietChip(tint: Color.cobuxAccent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(photosLoading > 0)
                .accessibilityLabel("Add a photo")
            }

            // Voice note, where Dictate used to be. He asked for the swap
            // directly: the keyboard already dictates, but nothing kept how he
            // actually sounded saying something -- which is the part a journal
            // has a real use for. `elapsed` was published by the recorder and
            // read by nobody, so a recording in progress used to look identical
            // to one that had not started; the chip now says it in words.
            Button {
                Task { await toggleRecording() }
            } label: {
                Label(recorder.isRecording ? Self.elapsedLabel(recorder.elapsed) : "Voice note",
                      systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.circle")
                    .monospacedDigit()
                    .foregroundStyle(recorder.isRecording ? Color.cobuxWarning : Color.cobuxAccent)
                    .cobuxQuietChip(tint: recorder.isRecording ? Color.cobuxWarning : Color.cobuxAccent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Not `.disabled(isLocked)` -- see the photo control above. The
            // lock is honoured inside `toggleRecording`, which asks for Face
            // ID and proceeds, instead of a dead chip that explains nothing.
            .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Record a voice note")

            Spacer(minLength: 0)
        }
        // Same clamp the prompt chips carry: a row of two capsules is the one
        // shape an accessibility text size turns into three lines of rubble.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    /// The recorder owns `permissionDenied`; this turns it into something an
    /// `.alert` can bind to and clear.
    private var micDeniedBinding: Binding<Bool> {
        Binding(get: { recorder.permissionDenied },
                set: { if !$0 { recorder.clearPermissionDenied() } })
    }

    /// How long after leaving an entry it is still the SAME sitting.
    ///
    /// His rule, verbatim: *"if a journal entry is getting edited under 10
    /// misnutes od leaving the last jounal entry time no new time at the edit
    /// time shold be dipslayed. it should sjust start the cursor at the end of
    /// the last cursor end postion simply."*
    ///
    /// A session stamp marks a genuinely new sitting. Stepping away for a
    /// minute and coming back is not one, and stamping it wrote a bare
    /// `9:01 AM` into the middle of his own paragraph -- the run-on card
    /// `JournalListView.preview(for:)` was written to paper over. This removes
    /// the cause instead: inside the window nothing is appended at all, and
    /// `CursorEndTextEditor` already opens with the caret at
    /// `endOfDocument`, so he simply carries on from where he stopped.
    static let sameSittingWindow: TimeInterval = 10 * 60

    /// Whether this open continues the sitting that `lastLeft` ended.
    ///
    /// Fails OPEN -- a negative interval means the clock moved (a timezone
    /// change, a manual set, a restored backup) and the honest answer is "I do
    /// not know". Writing the stamp is the safe direction there: a stamp too
    /// many is a line he can delete, while a missing sitting boundary silently
    /// merges two sittings into one and the "N sittings" footer under-reports
    /// his own record.
    private static func isSameSitting(as lastLeft: Date) -> Bool {
        let elapsed = Date.now.timeIntervalSince(lastLeft)
        return elapsed >= 0 && elapsed < sameSittingWindow
    }

    /// Delegates to the shared implementation so the composer, the Siri
    /// intent and the Messages extension cannot drift apart on formatting.
    private static func sessionStamp(at date: Date, previousSessionDate: Date?) -> String {
        JournalSessionStamp.text(at: date, previousSessionDate: previousSessionDate,
                                 ambient: AmbientContext.cached())
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
            || !pendingVoiceNoteIDs.isEmpty
            || !removedAttachmentIDs.isEmpty
    }

    /// When this writing session opened -- the delta to Save is what
    /// accumulates into `PersonalWritingEntry.writingSeconds` for the detail
    /// view's stats bar.
    private let sessionStart = Date.now

    /// Snapshot of the entry being answered, when this sheet is Write Back.
    /// A snapshot, not the model: everything the surface needs, captured once
    /// at the door -- the sheet never holds a live model beyond `existingEntry`.
    struct AnsweringContext {
        let entryID: UUID
        let date: Date
        let dateIsCertain: Bool
        let body: String
        let month: Int
    }

    /// Write Back: this new entry answers his own past writing. Meaningful
    /// only for a NEW entry -- answer mode never edits the original, by
    /// construction (the save path's creation branch is the only one that
    /// reads it).
    let answering: AnsweringContext?
    /// Link recovered from a crashed write-back draft. The reopened sheet
    /// cannot rebuild the quote box (no model at init), but the LINK survives
    /// -- the reply still answers what it was answering, which is the part
    /// that matters to the record.
    private let recoveredAnswersID: UUID?
    private let recoveredAnswersDate: Date?

    /// Which draft file this sheet mirrors into -- one draft per TARGET. An
    /// existing entry drafts under its own id, a plain new entry under the
    /// store's `"new"` slot (`nil`), and a Write Back under a key derived
    /// from the entry it answers (`writeBackDraftKey`). Before this, every
    /// new-entry draft shared the one slot whatever it was answering, so a
    /// draft written while answering entry X could be recovered into a plain
    /// New Entry -- and saved as an answer to X, or a plain draft recovered
    /// into a Write Back and given a link it never had -- without him ever
    /// seeing it. Now a sheet only ever loads, writes and clears its own key;
    /// a draft for a different door stays on disk until that door is opened.
    private let draftKey: UUID?

    /// A stable key for a Write Back draft, derived from the answered entry's
    /// id so the same door always finds the same draft. Deliberately NOT the
    /// entry's own id -- that slot belongs to "Continue Entry" on that entry,
    /// and the two are different writing (a continuation extends X's text; a
    /// reply is a new entry). Version-5-shaped over a fixed namespace:
    /// deterministic, and practically incapable of colliding with a real
    /// row's random UUID.
    static func writeBackDraftKey(answering entryID: UUID) -> UUID {
        let digest = SHA256.hash(data: Data("cobux.journal.write-back:\(entryID.uuidString)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// One-time tidy for a draft written by a build that filed EVERY
    /// new-entry draft under the shared `"new"` slot: a write-back draft
    /// found there is re-filed under its own target key, and the slot is
    /// cleared only once the re-filed copy is confirmed on disk. A plain New
    /// Entry then never sees it, and the Write Back for that entry still
    /// does. Nothing is discarded here -- moved, only.
    private static func migrateLegacyWriteBackDraft() {
        guard let legacy = JournalDraftStore.load(entryID: nil),
              let target = legacy.answersEntryID else { return }
        let key = writeBackDraftKey(answering: target)
        if JournalDraftStore.load(entryID: key) == nil {
            JournalDraftStore.save(entryID: key, title: legacy.title, text: legacy.text,
                                   answersEntryID: legacy.answersEntryID,
                                   answersEntryDate: legacy.answersEntryDate)
        }
        if JournalDraftStore.load(entryID: key) != nil {
            JournalDraftStore.clear(entryID: nil)
        }
    }

    init(existingEntry: PersonalWritingEntry? = nil,
         answering: AnsweringContext? = nil) {
        assert(existingEntry == nil || answering == nil,
               "answer mode is defined only for a brand-new entry")
        self.answering = answering
        self.existingEntry = existingEntry
        if let existingEntry {
            self.draftKey = existingEntry.id
            // A blank line separates this session from whatever came before it
            // -- reads as a new dated addition, not text spliced mid-paragraph
            // into the last thing that was written. The stamp carries the date
            // only when this continuation lands on a DIFFERENT day than the
            // entry's last session -- same-day additions read as times within
            // one day, exactly like a paper journal.
            //
            // ...unless he never really left. See `sameSittingWindow`.
            _title = State(initialValue: existingEntry.title)
            let lastLeft = existingEntry.modifiedDate ?? existingEntry.dateImported
            let seeded = Self.isSameSitting(as: lastLeft)
                ? existingEntry.text
                : existingEntry.text + "\n\n"
                    + Self.sessionStamp(at: .now, previousSessionDate: lastLeft) + "\n"
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
            recoveredAnswersID = nil
            recoveredAnswersDate = nil
        } else {
            // First session of a brand-new entry: nothing above it establishes
            // the date, so the stamp always carries it.
            let stamp = Self.sessionStamp(at: .now, previousSessionDate: nil)
            _title = State(initialValue: "")
            let seeded = stamp + "\n"
            self.seededText = seeded
            // The link is fixed by the door this sheet was opened through,
            // never by whatever a draft on disk says: a recovered draft can
            // restore TEXT, not rewrite what the entry answers.
            recoveredAnswersID = answering?.entryID
            recoveredAnswersDate = answering?.date
            let key = answering.map { Self.writeBackDraftKey(answering: $0.entryID) }
            self.draftKey = key
            Self.migrateLegacyWriteBackDraft()
            // Same recovery for a brand-new entry that never got saved --
            // the exact shape of the 26 Aug loss. Any draft meaningfully
            // longer than a bare stamp line is real writing -- and only a
            // draft for THIS door: the key already separates them, and the
            // link check is the belt to that brace. A draft that does not
            // match is left exactly where it is.
            if let draft = JournalDraftStore.load(entryID: key),
               draft.answersEntryID == answering?.entryID,
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
            // is ever presented on top of this compose sheet. `armed` is
            // false only for the first entry of an empty journal -- see
            // `lockArmed`.
            JournalLocked(armed: lockArmed) {
                composeForm
            }
            .navigationTitle(Self.barTitle(answering: answering != nil,
                                           continuing: existingEntry != nil))
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
                        cancelPendingVoiceNotes()
                        JournalDraftStore.clear(entryID: draftKey)
                        dismiss()
                    }
                }
                // The photo and voice-note controls used to be two more
                // `.topBarTrailing` items here, which iOS 26 then grouped into
                // one glass capsule with Done -- four controls and a title in a
                // bar with room for about two. Rajan: "the top portion wehre it
                // is the new jour and then dot dot dot looks congetsted and
                // overall the top should be fixed". They now live in
                // `mediaRow`, in the composer's own header card; see there for
                // why that placement and not the keyboard bar.
                ToolbarItem(placement: .confirmationAction) {
                    // "Done", not "Save". `onDisappear` and the scenePhase
                    // handler below already commit on the way out, so writing
                    // has not depended on this button for a while -- but
                    // labelling it "Save" told the user it did, and a disabled
                    // Save reads as "your writing is not safe yet". Notes never
                    // asks you to save; this now tells the same truth the code
                    // already implements.
                    Button("Done") { save() }
                        .fontWeight(.semibold)
                        .disabled(didSave || isLocked)
                }
            }
        }
        .sensoryFeedback(.success, trigger: didCommit)
        .alert("Microphone access is off", isPresented: micDeniedBinding) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            Button("Not now", role: .cancel) { }
        } message: {
            Text("Cobux needs the microphone to record a voice note. You can turn it on in Settings.")
        }
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
        //
        // Neither guard consults the lock. They used to (`!isLocked`), and
        // that guard is exactly what defeated the background save: ContentView
        // relocks the journal on the SAME scenePhase transition, the ancestor's
        // handler runs first in practice, so by the time this one ran the
        // journal was locked, the save was skipped, and iOS terminating the
        // suspended app took three paragraphs with it. The lock governs what
        // is SHOWN; it has no say over whether writing that already exists
        // gets persisted. The seeded-placeholder case the old guard worried
        // about is covered by `hasRealChanges`.
        .onDisappear {
            guard !didCancel, !didSave, hasRealChanges else { return }
            save()
        }
        // Backgrounding is the other way writing disappears: the sheet stays
        // presented, so onDisappear never fires, and iOS can terminate the app
        // while suspended without any further warning. `.background` only,
        // deliberately: `save()` dismisses the sheet, and `.inactive` also
        // fires for Control Center, a notification banner or an incoming call
        // -- ejecting him from a half-written entry for any of those would be
        // its own bug. The draft mirror already covers the `.inactive` window.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background, !didCancel, !didSave, hasRealChanges else { return }
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
    /// At most two, and only for a brand-new entry: a blank page is where a
    /// prompt helps, and a continuation already has its own context.
    ///
    /// Two columns over every entry, not every entry. Both chips are
    /// date-matched against the WHOLE journal ("On this day" in an earlier
    /// year is, by definition, far from the newest rows), so the definition
    /// is kept exactly and the bound is put on the columns instead:
    /// `propertiesToFetch` limits the read to `id`/`modifiedDate`/
    /// `dateImported`, and only the one or two matching entries have their
    /// text faulted in (`firstLine`). Newest-imported first, as the old
    /// `@Query` was sorted, so `first(where:)` picks the same entry it did.
    ///
    /// `@MainActor` explicitly, the way `BookDetailView.loadContents` is: it
    /// reads the main context (SE-0338).
    @MainActor
    private func loadPromptChips() -> [(label: String, insert: String)] {
        var chips: [(String, String)] = []
        let calendar = Calendar.current
        let today = calendar.dateComponents([.month, .day], from: .now)

        var dates = FetchDescriptor<PersonalWritingEntry>(
            sortBy: [SortDescriptor(\PersonalWritingEntry.dateImported, order: .reverse)])
        dates.propertiesToFetch = [\.id, \.modifiedDate, \.dateImported]
        let pastEntries = (try? modelContext.fetch(dates)) ?? []

        // "On this day" -- the same calendar date in an earlier year or month.
        if let past = pastEntries.first(where: { entry in
            let date = entry.modifiedDate ?? entry.dateImported
            guard !calendar.isDateInToday(date) else { return false }
            let parts = calendar.dateComponents([.month, .day], from: date)
            return parts.month == today.month && parts.day == today.day
        }) {
            let date = past.modifiedDate ?? past.dateImported
            let year = calendar.component(.year, from: date)
            chips.append(("On this day, \(year)",
                          "On this day in \(year) I wrote: \(firstLine(of: past))"))
        }

        // "Continue yesterday" -- pick up the thread rather than start cold.
        if let yesterday = pastEntries.first(where: {
            calendar.isDateInYesterday($0.modifiedDate ?? $0.dateImported)
        }) {
            chips.append(("Continue yesterday",
                          "Yesterday I wrote: \(firstLine(of: yesterday))"))
        }
        return Array(chips.prefix(2))
    }

    /// The entry being answered, held above the page -- read-only, five
    /// lines, in the passage face. A reminder, not a reading surface: he
    /// arrived from a surface that showed him the material. A drawn box on
    /// the VStack; the editor stays the page's only scroller (the judder
    /// post-mortem's rule).
    ///
    /// VETO carried from the ruling: this text is NEVER inserted into the
    /// entry body. The link is data, not pasted prose -- pasting would
    /// duplicate the original inside the corpus, polluting embeddings,
    /// search, word counts and future selection.
    private func answeringQuoteBox(_ answering: AnsweringContext) -> some View {
        let hue = Color.cobuxMonthHue(answering.month, dark: colorScheme == .dark)
        return VStack(alignment: .leading, spacing: 6) {
            Text(Self.answeringKicker(date: answering.date,
                                      certain: answering.dateIsCertain))
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .kerning(0.7)
                .foregroundStyle(hue)
            Text(JournalHighlightSelector.stripStamp(answering.body))
                .font(CobuxTypography.passage(size: 15))
                .lineSpacing(4)
                .lineLimit(5)
                .textSelection(.enabled)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(hue.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: CobuxRadius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Answering your entry from \(Self.answeringAccessibilityDate(answering.date))")
    }

    /// Built once, not per call -- the same fix `longDateFormatter` below
    /// already carries. `answeringKicker` is read straight out of a body (the
    /// answering banner above) and out of `JournalEntryDetailView`'s body too,
    /// so a fresh `DateFormatter` here was a locale + calendar + date-symbol
    /// resolution on every evaluation of either.
    ///
    /// Safe to share: nothing mutates it after construction (the documented
    /// condition for `DateFormatter` reuse), and every caller is on the main
    /// actor -- the same pair of conditions `ChatView`'s time-mark formatters
    /// are documented under.
    private static let answeringKickerFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    static func answeringKicker(date: Date, certain: Bool) -> String {
        let formatter = answeringKickerFormatter
        return certain
            ? "Answering · \(formatter.string(from: date))"
            : "Answering · imported \(formatter.string(from: date))"
    }

    /// Built once. Was allocated fresh on every call, from a body-read
    /// accessibility label.
    private static let longDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        return formatter
    }()

    private static func answeringAccessibilityDate(_ date: Date) -> String {
        longDateFormatter.string(from: date)
    }

    private var promptRow: some View {
        // Computed ONCE. `promptChips` scans the whole journal twice (an
        // "on this day" match and a "yesterday" match, each a `first(where:)`
        // that walks to the end when nothing matches), and this row read it
        // once for `indices` and then AGAIN inside the `ForEach` for every
        // chip -- so rendering two chips ran six full scans.
        let chips = promptChips
        return HStack(spacing: 8) {
            ForEach(chips.indices, id: \.self) { index in
                let chip = chips[index]
                Button {
                    // Inserted as a quiet italic line he can delete, not as
                    // committed text -- a prompt is a nudge, not content.
                    if text.isEmpty { text = chip.insert + "\n\n" }
                    else { text = chip.insert + "\n\n" + text }
                    dismissedPrompts = true
                } label: {
                    Text(chip.label)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.cobuxAccent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Button {
                dismissedPrompts = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss writing prompts")
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func firstLine(of entry: PersonalWritingEntry) -> String {
        let body = JournalListView.previewText(for: entry)
        let line = body.split(separator: "\n").first.map(String.init) ?? body
        return line.count > 90 ? String(line.prefix(90)) + "…" : line
    }

    private var composeForm: some View {
        // Boxed again, because he preferred how it looked -- but NOT the way it
        // was boxed before. The old version got its boxes from a `Form`, which
        // put the `UITextView` (a scroll view) inside the Form's `List`
        // (another scroll view) behind a `.frame(minHeight:)`: three systems
        // adjusting offsets for the same caret, which is the up-and-down judder
        // he reported repeatedly. The boxes were never the cause; the nesting
        // was.
        //
        // So these are drawn boxes -- a surface fill and a corner radius -- on
        // a plain VStack. The editor still owns every pixel of scrolling on the
        // page, exactly as it does now. Same look, none of the structure that
        // caused the shake.
        VStack(spacing: 12) {
            if let answering {
                answeringQuoteBox(answering)
            }
            VStack(alignment: .leading, spacing: 6) {
                // Hidden in answer mode -- the quote above IS the context, and
                // a prompt chip beside it would be two voices asking at once.
                if !dismissedPrompts, existingEntry == nil, answering == nil, !promptChips.isEmpty {
                    promptRow
                }
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
                // The weather stamp he asked for on 3 Sep ("the temperature
                // right next to the time") defaults ON since 58, so no toggle
                // flip asks for location any more. This line is where the
                // system prompt comes from now: shown only while location has
                // never been asked, it explains first and asks second
                // (`R-2026-09-location-asked-before-it-is-explained`). Once
                // answered either way it never appears again; a decline just
                // leaves the stamp as the bare time.
                if showsWeatherOffer {
                    Button {
                        AmbientContextService.shared.requestAuthorization()
                        showsWeatherOffer = false
                    } label: {
                        Label("Add the weather beside the time · allow location once",
                              systemImage: "thermometer.medium")
                            .font(.caption)
                            .foregroundStyle(Color.cobuxAccent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Asks for your approximate location so entries can carry the temperature")
                }
                // Under the title field, inside the same card: what this entry
                // is (its name, how the body was doing) and what can be added to
                // it, in one place, out of the navigation bar.
                mediaRow
            }
            .padding(14)
            .background(Color.cobuxSurface,
                        in: RoundedRectangle(cornerRadius: CobuxRadius.card, style: .continuous))

            // Finished voice notes, the moment the recorder stops -- the
            // confirmation his report asked for. Each row is the same player
            // the detail view uses (same file; the store's `audioURL(for:)`
            // is where the recorder wrote it), so what he hears here is what
            // Done will save. The remove control is allowed because nothing
            // here is saved yet: it drops the staging id and the file, and a
            // SAVED entry's attachments are never deleted from this sheet.
            // Not a count, not a score -- a row per note, with its length.
            if !stagedVoiceNotes.isEmpty {
                stagedVoiceNoteRows
                    // Playing or removing a staged note swaps the audio session
                    // to playback and deactivates it on the way out -- under a
                    // LIVE recorder that truncates the recording in progress,
                    // and the failure is swallowed. Inert while recording.
                    .disabled(recorder.isRecording)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(Color.cobuxSurface,
                                in: RoundedRectangle(cornerRadius: CobuxRadius.card, style: .continuous))
            }

            // Attached photos, only once there are any -- adding the first
            // one happens from the toolbar, so an entry with no photos gives
            // its whole page to the writing. "Any" includes photos still
            // arriving: the strip shows a placeholder per pick the instant the
            // picker closes, so an iCloud download that takes 20 seconds is
            // visibly in progress rather than apparently ignored.
            if !visibleExistingAttachments.isEmpty || !pendingAttachments.isEmpty || photosLoading > 0 {
                photoStrip
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.cobuxSurface,
                                in: RoundedRectangle(cornerRadius: CobuxRadius.card, style: .continuous))
            }

            // The writing box. `CursorEndTextEditor` is still the only scroll
            // view on this page -- the box is a background behind it, not a
            // container that scrolls.
            CursorEndTextEditor(text: $text, font: composeFont)
                // Hands the keyboard to the text view. Without this, SwiftUI
                // animates this view's frame smaller as the keyboard rises,
                // and the text view's own inset compensation fights it --
                // which is the judder, in a worse form than before. The text
                // view keeps its full height; the keyboard covers the bottom
                // of it; `CaretTrackingTextView` accounts for exactly that.
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .background(Color.cobuxSurface,
                            in: RoundedRectangle(cornerRadius: CobuxRadius.card, style: .continuous))
        }
        .padding(.horizontal, CobuxSpacing.screenMargin)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Color.cobuxBackground)
        .task {
            // SYNCHRONOUS PREFIX, before any `await`: `.task` starts in the
            // same main-actor turn as the first render pass, so a `COUNT`
            // here is committed with frame one -- the lock gate is armed on
            // the frame it appears, exactly as it was when `pastEntries` was
            // a `@Query`, without materialising a single row to know it.
            // A read that fails arms the lock (the safe direction).
            if existingEntry == nil, answering == nil, hasPastEntries == nil {
                if let total = try? modelContext.fetchCount(FetchDescriptor<PersonalWritingEntry>()) {
                    hasPastEntries = total > 0
                } else {
                    hasPastEntries = true
                }
            }
            // The chips are a nicety; they wait for the frame.
            guard existingEntry == nil, answering == nil, !dismissedPrompts else { return }
            await Task.yield()
            promptChips = loadPromptChips()
        }
        .task {
            // Fire-and-forget: a slow or unavailable HealthKit must never delay
            // the compose screen appearing.
            if healthContext == nil, HealthContextService.isAvailable, HealthContextService.isEnabled {
                healthContext = await HealthContextService.currentContext()
            }
            // The weather stamp reads a cache that is only ever filled on
            // scene activation; a sheet opened ninety minutes into a session
            // found it stale and wrote a bare time. Ask for a refresh here too --
            // it is throttled to one fetch per half hour inside the service.
            AmbientContextService.shared.refreshIfNeeded()
            showsWeatherOffer = AmbientContextService.shared.needsAuthorizationPrompt
        }
        .task {
            guard let existingEntry else { return }
            // Ids snapshotted on the main actor (SwiftData models stay
            // there); the disk reads and decodes happen off it. Thumbnail
            // tier -- the 1600px tier is for the detail hero, not 72pt tiles.
            let ids = existingEntry.attachments.map(\.id)
            let images = await Task.detached(priority: .userInitiated) { () -> [UUID: UIImage] in
                var loaded: [UUID: UIImage] = [:]
                for id in ids {
                    if let image = JournalAttachmentStore.thumbnail(for: id) { loaded[id] = image }
                }
                return loaded
            }.value
            existingAttachmentImages = images
        }
        // The crash-safe mirror: every edit lands in the draft file (throttled
        // inside the store), so the app dying mid-write costs seconds, not the
        // session. See `JournalDraftStore`'s own doc comment for the two real
        // losses this exists because of. Always under THIS sheet's `draftKey`.
        .onChange(of: text) { _, newText in
            JournalDraftStore.save(entryID: draftKey, title: title, text: newText, answersEntryID: recoveredAnswersID, answersEntryDate: recoveredAnswersDate)
        }
        .onChange(of: title) { _, newTitle in
            JournalDraftStore.save(entryID: draftKey, title: newTitle, text: text, answersEntryID: recoveredAnswersID, answersEntryDate: recoveredAnswersDate)
        }
        .onChange(of: selectedPhotoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            let itemsToLoad = newItems
            // The selection is cleared AFTER the load, not before it.
            //
            // This used to reset `selectedPhotoItems` to [] synchronously here
            // and then read the captured items inside the Task. A
            // `PhotosPickerItem` is tied to the picker session it came from, so
            // clearing the binding first can invalidate the items before
            // `loadTransferable` ever runs -- every load returns nil, every
            // photo hits `continue`, and nothing is appended or reported.
            // Reported as "image addition in journals not working", which is
            // exactly the shape of a silent per-item `continue`.
            Task {
                // Concurrent, per-item-timeout loading (PhotoLoader) -- one
                // iCloud-offloaded photo that takes forever can no longer
                // wedge the batch into an eternal spinner. The preview is
                // decoded in the same off-main task group, at strip size;
                // nothing here ever inflates an original.
                //
                // "can no longer" only became true in build 53. `withTimeout`
                // raced the load against a sleep inside a `withTaskGroup` and
                // took `group.next()` -- and a task group cannot return until
                // every child has finished, so a `loadTransferable` that does
                // not check `Task.isCancelled` held the group open for its full
                // duration. The deadline expired into a wait. Measured on the
                // chat side at 3.2s against a 1s bound. Nothing in THIS file was
                // wrong; the loader it calls was, and it is shared with chat,
                // which is why he reported the same defect on both: "also still
                // not able to add pcitures in the journal as well like in chat".
                photosLoading = itemsToLoad.count
                // `defer`, not a bare assignment after the await. The photo
                // control disables itself on `photosLoading > 0`, so any path
                // that leaves this counter above zero disables the button for
                // the rest of the sheet's life -- exactly the "can't add
                // pictures" shape, arrived at from the other direction.
                defer { photosLoading = 0 }
                let (loaded, failures) = await PhotoLoader.loadWithPreviews(itemsToLoad, previewMaxPixelSize: 300)
                // Bytes ImageIO could not read into a preview are bytes
                // `JournalAttachmentStore.save` could not downsample either --
                // they fail here, visibly, not silently at save.
                let readable = loaded.filter { $0.preview != nil }
                pendingAttachments.append(contentsOf: readable.map {
                    PendingAttachment(preview: $0.preview, data: $0.data)
                })
                selectedPhotoItems = []
                if failures > 0 || readable.count < loaded.count {
                    DiagnosticLog.log("journal: \(failures + loaded.count - readable.count) photo(s) failed, unreadable or timed out loading")
                    photoLoadFailed = true
                }
            }
        }
        .alert("Couldn't start recording", isPresented: $recordingFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The microphone wasn't available just now. If another app is using it, or a call is active, try again in a moment.")
        }
        .alert("That photo couldn't be added", isPresented: $photoLoadFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Cobux couldn't read it from your library in time. If it's stored in iCloud, it may still be downloading — try again in a moment, or pick a different photo.")
        }
    }

    private var stagedVoiceNoteRows: some View {
        VStack(spacing: 8) {
            ForEach(stagedVoiceNotes) { note in
                HStack(spacing: 6) {
                    JournalVoiceNoteRow(fileURL: JournalAttachmentStore.audioURL(for: note.id),
                                        kicker: "Voice note · ready to save")
                    Button {
                        removeStagedVoiceNote(note.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove this voice note, \(Self.elapsedLabel(note.duration)) long")
                }
            }
            if showsTranscriptExplanation {
                Text("Cobux writes a transcript on the phone after you save")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// Unsaved only. The staging id has no row in the store yet, so removing
    /// it is discarding a draft, never deleting a saved attachment.
    private func removeStagedVoiceNote(_ id: UUID) {
        stagedVoiceNotes.removeAll { $0.id == id }
        pendingVoiceNoteIDs.removeAll { $0 == id }
        JournalAttachmentStore.deleteAudio(id: id)
    }

    /// Ends the live recording and either stages it (usable file) or drops
    /// its id (too short). One path for the chip and for `save()`, so the two
    /// cannot disagree about what a finished note looks like.
    private func stopRecordingAndStage() {
        let duration = recorder.elapsed
        let id = pendingVoiceNoteIDs.last
        if recorder.stop() {
            if let id {
                stagedVoiceNotes.append(StagedVoiceNote(id: id, duration: duration))
                if !showsTranscriptExplanation, VoiceTranscriptionService.needsAuthorizationPrompt() {
                    showsTranscriptExplanation = true
                }
            }
        } else if id != nil {
            // Nothing usable captured -- drop the staged id so an empty
            // recording never becomes an unplayable attachment.
            pendingVoiceNoteIDs.removeLast()
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
                    attachmentThumbnail(image: pending.preview) {
                        pendingAttachments.removeAll { $0.id == pending.id }
                    }
                }
                // One placeholder per pick still in flight. `photosLoading`
                // was written by the load and read by nothing, so the
                // "placeholder state" the picker regression record promised
                // did not exist: two iCloud photos showed NOTHING for up to
                // 20 seconds, he picked again, and both batches appended.
                ForEach(0..<photosLoading, id: \.self) { _ in
                    loadingTile
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
                .disabled(photosLoading > 0)
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal, 16)
    }

    /// The tile a photo occupies before its bytes have arrived -- same size,
    /// same corner, the surface tone with a spinner. It is the shape of the
    /// batch made visible, not a decoration.
    private var loadingTile: some View {
        ProgressView()
            .frame(width: 72, height: 72)
            .background(Color.cobuxSurface2)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Loading photo")
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

    @MainActor
    private func toggleRecording() async {
        // Locked means "prove it is you", never "do nothing". Stopping an
        // in-flight recording is always allowed; starting one asks first.
        if isLocked && !recorder.isRecording {
            guard await lockStatus.authenticate() else { return }
        }
        if recorder.isRecording {
            stopRecordingAndStage()
        } else {
            let id = UUID()
            pendingVoiceNoteIDs.append(id)
            await recorder.start(id: id)
            if !recorder.isRecording {
                pendingVoiceNoteIDs.removeLast()
                // Permission denial already has its own alert via
                // `micDeniedBinding`. Anything else that stopped the recorder
                // starting -- the audio session refusing, the recorder failing
                // to initialise -- used to be a silent `return` inside
                // `start()`, so the chip stayed grey and the user learned
                // nothing. Say so.
                if !recorder.permissionDenied { recordingFailed = true }
            }
        }
    }

    private func cancelPendingVoiceNotes() {
        if recorder.isRecording, let id = pendingVoiceNoteIDs.last { recorder.cancel(id: id) }
        for id in pendingVoiceNoteIDs {
            // Through the store, not `FileManager` directly. The store now
            // remembers which extension an id resolved to (so the journal feed
            // stops re-running a `fileExists` loop per card per body pass), and
            // a removal it does not see would leave that memory wrong. See
            // `JournalAttachmentStore.resolvedExtensions`.
            JournalAttachmentStore.deleteAudio(id: id)
        }
        pendingVoiceNoteIDs = []
        stagedVoiceNotes = []
    }

    private func save() {
        // Same double-tap guard `AddHighlightView`/`AddChapterView`/
        // `AddBookView` already use -- a fast second tap in the moment
        // before the sheet dismisses would otherwise append a duplicate.
        guard !didSave else { return }

        // Close any still-open recording FIRST. Saving moves the recorder's
        // file into the attachment store, and moving a file AVAudioRecorder is
        // still writing to yields a truncated or unplayable note. Auto-save on
        // dismiss/background reaches here too, which is exactly when a user is
        // most likely to have left one running.
        if recorder.isRecording {
            stopRecordingAndStage()
        }

        // Nothing new means nothing is written. Done on an untouched sheet
        // behaves as Cancel -- what Apple Notes does with an empty note, and
        // what anyone tapping it meant.
        //
        // This is the guard the empty-entry regression record describes, on
        // the path it names. The previous guard tested `finalText.isEmpty`,
        // but `text` is never empty here: every sheet is seeded with a session
        // stamp ("September 5, 2026 · 9:41 PM"). So Done on an untouched NEW
        // sheet still inserted a stamp-only entry, still called
        // `recordActivityToday()`/`markJournalEntryWritten()` below, still lit
        // a calendar day -- the corruption that record was written to end. On
        // an untouched Continue Entry it appended a dangling stamp and moved a
        // real entry's date to today. `hasRealChanges` compares against the
        // seed and already counts photos, voice notes and removals as content,
        // so a photo-only or voice-only entry still saves normally; editing
        // an existing entry down to empty still saves as written -- entries
        // are never deletable, and this must not become a back door to that.
        guard hasRealChanges else {
            didSave = true
            JournalDraftStore.clear(entryID: draftKey)
            dismiss()
            return
        }

        // Read BEFORE the insert below: `hasPastEntries` is a one-time read,
        // and `lockArmed` must describe the journal as it was when this sheet
        // opened, not after this save.
        let wasFirstContent = !lockArmed

        let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // How long this sheet was open, credited to the entry's lifetime
        // writing time (the detail view's stats bar). Sheet-open time IS the
        // honest measure here -- pauses to think are part of writing --
        // capped at 3 hours so a sheet forgotten open overnight can't turn
        // the stat into nonsense.
        let sessionSeconds = min(Int(Date.now.timeIntervalSince(sessionStart)), 3 * 60 * 60)

        // No embedding here, on either branch. `EmbeddingService.embed` is a
        // full NLContextualEmbedding pass over the whole entry, synchronous,
        // on the main actor, inside `inferenceLock` -- the same lock
        // SeedRunner's background backfills hold. On a long entry during a
        // first-run backfill, Done blocked on a model load plus a multi-window
        // inference plus a background-priority lock holder. The entry saves
        // with `embedding` nil and the bounded, idempotent, off-main backfill
        // (kicked below) fills it in; `PersonalWritingAutoImportService`
        // defers for exactly this reason. Retrieval reads keyword-only for
        // the few seconds in between, which nobody can see.
        let entry: PersonalWritingEntry
        if let existingEntry {
            existingEntry.title = trimmedTitle
            existingEntry.text = finalText
            existingEntry.modifiedDate = .now
            existingEntry.writingSeconds = (existingEntry.writingSeconds ?? 0) + sessionSeconds
            // The old vector described the old text; nil is what the backfill
            // looks for.
            existingEntry.embedding = nil
            entry = existingEntry
        } else {
            let newEntry = PersonalWritingEntry(
                source: "journal",
                title: trimmedTitle,
                text: finalText,
                modifiedDate: .now
            )
            newEntry.writingSeconds = sessionSeconds
            // The Correspondence: creation branch only -- the original is
            // never written, by construction.
            newEntry.answersEntryID = recoveredAnswersID
            newEntry.answersEntryDate = recoveredAnswersDate
            // Location, captured once at birth. First write wins -- a
            // continue-session from another city does not rewrite where the
            // entry began.
            newEntry.locality = AmbientContext.cached()?.locality
            modelContext.insert(newEntry)
            entry = newEntry
        }
        // Committed -- the crash-safe mirror has served its purpose.
        JournalDraftStore.clear(entryID: draftKey)

        // Attachment deletes/adds both apply here, at the same moment the
        // rest of the entry actually commits -- see the `@State` properties'
        // own doc comment for why Cancel must not have touched any of this.
        for attachment in entry.attachments where removedAttachmentIDs.contains(attachment.id) {
            JournalAttachmentStore.delete(id: attachment.id)
            modelContext.delete(attachment)
        }
        for pending in pendingAttachments {
            let attachment = JournalAttachment(entry: entry)
            // Write the file FIRST, and only insert the row if it landed.
            // The old order inserted unconditionally and discarded the
            // `@discardableResult` Bool, so a failed decode or write left a
            // persisted attachment pointing at a file that does not exist --
            // which then renders as an empty grey tile in the card, the detail
            // hero and the photo strip, with no way to remove it.
            guard JournalAttachmentStore.save(pending.data, id: attachment.id) else {
                DiagnosticLog.log("journal: attachment write failed, row not inserted")
                continue
            }
            modelContext.insert(attachment)
        }
        // Voice notes were already written to disk under their own id while
        // recording -- committing here just gives them a row, so Cancel leaves
        // nothing but an orphaned file that `cancelPendingVoiceNotes` removes.
        var savedVoiceNoteIDs: [UUID] = []
        for voiceID in pendingVoiceNoteIDs {
            let attachment = JournalAttachment(entry: entry)
            // The length the recorder measured, kept on the row so the detail
            // colophon can say "2 min voice note" without opening the file.
            attachment.durationSeconds = stagedVoiceNotes.first { $0.id == voiceID }?.duration
            // The transcript is written after this save, on the phone, by
            // `VoiceTranscriptionService`; "pending" is what the detail view
            // reads as its one quiet "Transcribing…" line meanwhile.
            attachment.transcriptState = VoiceTranscriptionService.State.pending.rawValue
            savedVoiceNoteIDs.append(attachment.id)
            modelContext.insert(attachment)
            // The file was written under a staging id while recording, because
            // the row does not exist until save. Move it onto the row's real id
            // so `JournalAttachmentStore` can find it by attachment id like a photo.
            //
            // Through the store, for the same reason as
            // `cancelPendingVoiceNotes`: this move is the exact moment a voice
            // note becomes discoverable under its row's id, and the store has
            // to be told or its resolved-kind memory is wrong for this id from
            // birth.
            JournalAttachmentStore.moveAudio(from: voiceID, to: attachment.id)
        }

        try? modelContext.save()

        // The transcript, after the save and off this actor. The first time a
        // voice note is saved on an OS whose transcript path needs the speech
        // permission, the phone asks now -- the explanation line has been on
        // the page since the note was staged. Never from a background save:
        // a permission sheet raised while the app is leaving is the one the
        // user never sees and iOS answers for them.
        if !savedVoiceNoteIDs.isEmpty {
            let transcriptionContainer = modelContext.container
            let ids = savedVoiceNoteIDs
            let mayPrompt = scenePhase == .active
            Task { @MainActor in
                if mayPrompt { await VoiceTranscriptionService.shared.requestAuthorizationIfNeeded() }
                VoiceTranscriptionService.shared.transcribe(attachmentIDs: ids, container: transcriptionContainer)
            }
        }

        // The deferred embedding, on SeedRunner's own executor: bounded (25
        // rows a batch, a real pause between batches), idempotent (a row with
        // a vector is never touched), and already what every import relies
        // on. Detached so nothing about it inherits this view's main-actor
        // context.
        let container = modelContext.container
        Task.detached(priority: .utility) {
            await CobuxApp.backfillPersonalWritingEmbeddings(container: container)
        }

        // The very first entry is written with the lock unarmed -- there was
        // nothing to protect. The moment it lands, the list behind this sheet
        // has content, the lock arms, and it would demand Face ID for the
        // entry he typed ten seconds ago. The person holding the phone wrote
        // it; this foreground session is unlocked by that fact. The next
        // backgrounding relocks exactly as always.
        if wasFirstContent, lockEnabled, !lockStatus.isUnlocked {
            lockStatus.isUnlocked = true
        }

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
        // People (build 62): this one entry, on the next debounced pass, off
        // main on its own @ModelActor -- the save itself never waits on it,
        // `exportAfterWrite`'s rule.
        JournalPeopleIndexer.schedule(container: container)
        // The context, not a `@Query books` held only to reach it.
        WatchSyncService.sync(modelContext: modelContext)
        WidgetCenter.shared.reloadAllTimelines()

        didSave = true
        didCommit = true
        dismiss()
    }
}
