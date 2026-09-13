import AVFoundation
import SwiftUI
import SwiftData

/// Opens read-only -- `JournalListView`'s row only ever shows a two-line
/// snippet, and until this view existed there was no way to read the rest of
/// it back at all, imported or composed. Editing is a deliberate second step
/// (the toolbar button below), not automatic: viewing an old entry shouldn't
/// itself put a fresh timestamp on it.
///
/// Redesigned (2.5.13): a first photo, if any, gets a hero treatment (the
/// screen's full width inside the reading margin, rounded to the card radius)
/// instead of sitting in a small uniform grid with every other photo. The
/// "gradient scrim" this line used to promise was never built -- there is no
/// gradient anywhere in this file -- and a comment describing a thing that
/// does not exist is how the next reader ends up building around it.
/// Body text sets in `CobuxTypography.passage()` -- the design system's book
/// face, serif in both themes, and the token whose whole purpose is his own
/// writing. It used to be `display()`, which is serif only in light mode; the
/// feed card that opens this page now uses the same token at list scale, so
/// tapping a card never changes the voice of what he wrote.
struct JournalEntryDetailView: View {
    // Plain `let`, not `@Bindable` -- nothing here binds one of `entry`'s own
    // fields directly; `JournalEntryComposeView.save()` mutates the model
    // object itself, and SwiftData's own change tracking re-renders this
    // view's `entry.title`/`entry.text` reads once that lands, same as any
    // other view reading a `@Model` class's properties.
    let entry: PersonalWritingEntry
    @State private var showingContinue = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var keepContext
    @State private var showingKeepPrompt = false
    @State private var keepQuestion = ""
    @State private var keepPassage = ""
    @Environment(\.openURL) private var openURL

    // Same minimal, read-only lock check as `JournalListView`'s own copy --
    // hides the "Continue Entry" affordance while locked, consistent with the
    // list hiding its own compose button, rather than letting the button open
    // a sheet that immediately shows nothing but a lock gate.
    @AppStorage(JournalLockStatus.enabledKey) private var lockEnabled = true
    @State private var lockStatus = JournalLockStatus.shared
    private var isLocked: Bool { lockEnabled && !lockStatus.isUnlocked }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }()

    /// Picks the passage to keep the same way every other surface picks one, so
    /// what he keeps is what he would have been shown.
    private func prepareKeep() {
        let body = JournalHighlightSelector.stripStamp(entry.text)
        let standalone = Set(body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) })
        keepPassage = JournalHighlightSelector.best(
            from: JournalHighlightSelector.candidates(in: entry.text),
            standaloneLines: standalone) ?? String(body.prefix(220))
        keepQuestion = ""
        showingKeepPrompt = true
    }

    private func commitKeep() {
        guard !keepPassage.isEmpty else { return }
        let question = keepQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        keepContext.insert(JournalKeep(
            entryID: entry.id,
            passage: keepPassage,
            sourceDate: entry.modifiedDate ?? entry.dateImported,
            question: question.isEmpty ? nil : question))
    }

    /// The entry this one answers, resolved once on navigation. Nil either
    /// because this entry answers nothing, or because the link dangles
    /// (post-restore) -- the render distinguishes via `answersEntryDate`.
    @State private var answeredOriginal: PersonalWritingEntry?
    /// Later entries that answer THIS one, ascending. Reference-shaped lines
    /// only (date + pointer), so they need no quiet-words gating.
    @State private var laterAnswers: [PersonalWritingEntry] = []
    /// Write Back from here.
    @State private var writeBackSession = false
    /// Per voice note: what the transcription service knows about it. Read
    /// through the service's own actor (a fresh context, so a transcript
    /// written on a background context after this page opened is seen), not
    /// off the model object -- and re-read whenever the service's `revision`
    /// moves, which is how "Transcribing…" becomes the words without a
    /// re-navigation.
    @State private var transcripts: [UUID: VoiceTranscriptionService.Snapshot] = [:]
    /// Seconds per voice note, for the colophon. `durationSeconds` on the row
    /// when the note was saved by a build that wrote it; otherwise the file's
    /// own length, read once off-main.
    @State private var voiceDurations: [UUID: TimeInterval] = [:]
    @State private var transcription = VoiceTranscriptionService.shared

    var body: some View {
        // Pushed on top of `JournalListView`, so backgrounding while reading
        // an entry used to leave its full text visible on return -- nothing
        // here checked the lock at all. `autoPromptsWhenTopmost` mirrors the
        // list's own reasoning: while THIS view's own "Continue Entry" sheet
        // OR its "Write back" sheet is up, that sheet is topmost, not this
        // detail screen underneath it. Write Back was missing from the
        // predicate, so backgrounding mid-reply made this gate and the
        // sheet's gate both call `authenticate()` -- two concurrent
        // `LAContext` evaluations, the exact hazard `JournalLocked`'s own doc
        // comment warns about.
        JournalLocked(autoPromptsWhenTopmost: !showingContinue && !writeBackSession) {
            entryContent
        }
        .navigationTitle("Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isLocked {
                // Keeping is HIS act, never the app's. The app cannot decide
                // that a passage is a principle worth returning to -- that is
                // the inference the whole journal surface refuses to make -- so
                // the only way anything joins the ladder is that he put it
                // there. See `JournalKeep`.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { prepareKeep() } label: {
                        Label("Keep this", systemImage: "bookmark")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingContinue = true
                    } label: {
                        Label("Continue Entry", systemImage: "square.and.pencil.circle")
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
        }
        .alert("Keep this", isPresented: $showingKeepPrompt) {
            // The question is optional and is HIS. The app never writes one,
            // never checks whether he answered it, and never marks one done.
            TextField("Ask your future self something (optional)", text: $keepQuestion)
            Button("Cancel", role: .cancel) { }
            Button("Keep") { commitKeep() }
        } message: {
            Text("Cobux will bring this passage back to you now and then — after a week, then longer. Nothing is scored, and you can stop it any time.")
        }
        .sheet(isPresented: $writeBackSession) {
            JournalEntryComposeView(answering: .init(
                entryID: entry.id,
                date: entry.modifiedDate ?? entry.dateImported,
                dateIsCertain: entry.modifiedDate != nil,
                body: entry.text,
                month: Calendar.current.component(
                    .month, from: entry.modifiedDate ?? entry.dateImported)))
        }
        .task(id: entry.id) {
            // Both resolutions are single, navigation-triggered fetches --
            // nothing per-frame, nothing that scales with the corpus.
            if let target = entry.answersEntryID {
                var descriptor = FetchDescriptor<PersonalWritingEntry>(
                    predicate: #Predicate { $0.id == target })
                descriptor.fetchLimit = 1
                answeredOriginal = (try? keepContext.fetch(descriptor))?.first
            }
            let myID = entry.id
            let answers = FetchDescriptor<PersonalWritingEntry>(
                predicate: #Predicate { $0.answersEntryID == myID },
                sortBy: [SortDescriptor(\.dateImported)])
            laterAnswers = (try? keepContext.fetch(answers)) ?? []

            // Voice notes: what the transcript service knows, and how long
            // each is. Ids snapshotted here on the main actor; every read
            // below is off it. A note this build has never transcribed -- one
            // recorded before transcripts existed, or one whose permission
            // was declined and since granted -- is handed to the service now,
            // bounded to this entry's own notes.
            let voiceIDs = voiceNoteAttachments.map(\.id)
            guard !voiceIDs.isEmpty else { return }
            let known = Dictionary(uniqueKeysWithValues: voiceNoteAttachments.compactMap { attachment in
                attachment.durationSeconds.map { (attachment.id, $0) }
            })
            let container = keepContext.container
            let missing = voiceIDs.filter { known[$0] == nil }
            let measured = await Task.detached(priority: .userInitiated) { () -> [UUID: TimeInterval] in
                var lengths: [UUID: TimeInterval] = [:]
                for id in missing {
                    guard let url = JournalAttachmentStore.existingFileURL(for: id),
                          let file = try? AVAudioFile(forReading: url),
                          file.processingFormat.sampleRate > 0 else { continue }
                    lengths[id] = Double(file.length) / file.processingFormat.sampleRate
                }
                return lengths
            }.value
            voiceDurations = known.merging(measured) { current, _ in current }
            transcription.transcribeIfNeeded(attachmentIDs: voiceIDs, container: container)
        }
        .task(id: transcription.revision) {
            let voiceIDs = voiceNoteAttachments.map(\.id)
            guard !voiceIDs.isEmpty else { return }
            transcripts = await transcription.snapshots(for: voiceIDs, container: keepContext.container)
        }
        .sheet(isPresented: $showingContinue) {
            // Same underlying compose view as a brand-new entry -- passing
            // `existingEntry` is what makes it append a fresh timestamp to
            // THIS entry's own text and save back to the same row, instead of
            // creating a second one for what's really one continuous journal.
            JournalEntryComposeView(existingEntry: entry)
        }
    }

    private var entryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Split audio out BEFORE picking a hero. Voice notes were
                // falling through the photo path, so an audio-only entry got a
                // blank grey hero and its recording was unreachable.
                if let hero = photoAttachments.first {
                    heroPhoto(attachmentID: hero.id)
                }

                VStack(alignment: .leading, spacing: 18) {
                    // The same diary-margin date the feed uses, so tapping a
                    // card lands somewhere that clearly belongs to it. The feed
                    // became the best screen in the section; this is where he
                    // actually re-reads his life, and it must not be a
                    // downgrade on tap.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Self.dayNumeral(entryDate))
                            .font(CobuxTypography.display(colorScheme, size: 26, weight: .semibold))
                            .foregroundStyle(Color.cobuxMonthHue(
                                Calendar.current.component(.month, from: entryDate),
                                dark: colorScheme == .dark))
                            .monospacedDigit()
                        Text(Self.weekdayMonthYear(entryDate))
                            .font(.system(size: 12, weight: .semibold))
                            .textCase(.uppercase)
                            .kerning(0.8)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        JournalSourcePill(family: JournalSourceFamily(source: entry.source))
                    }

                    correspondenceHeader

                    if !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(entry.title)
                            .font(CobuxTypography.display(colorScheme, size: 24, weight: .bold))
                    }

                    // 17pt, iOS's own body size, in the section's serif. This
                    // was 19 with 7pt leading -- "the most generous setting in
                    // the app" -- and generous read as loud: "unnecessarily too
                    // big dont like that too big font look ugly ... how old
                    // peole have their font all large on their phones and when
                    // us kids see that it looks so ugly". A reading surface is
                    // not a large-print surface; the serif and the leading are
                    // what make it a page, not the point size.
                    //
                    // The SIZE is the part he signed off -- *"when I click on a
                    // journal entry, the font is perfect -- the font size I
                    // mean"* -- and 17 is untouched. The FACE moves from
                    // `display` to `passage`, which changes nothing whatever in
                    // light mode (`display` already resolves to serif there) and
                    // in dark mode stops this page setting his own prose in SF
                    // while the archive card, Ebb and Flow's echo all quote the
                    // same writing in the book face. `passage`'s own doc comment
                    // says it outright: the serif is for his writing in BOTH
                    // themes, because his writing is content, not chrome. The
                    // date numeral and the title above stay `display` -- those
                    // are the page's furniture.
                    Text(entry.text)
                        .font(CobuxTypography.passage(size: 17))
                        .lineSpacing(6)
                        .textSelection(.enabled)

                    laterAnswerLines

                    // At the BOTTOM of the body -- after the words, before the
                    // production line and the action row. Build 58, Rajan:
                    // "The voice note should be at the bottom; the Write back
                    // / Reflect on this / chat buttons should maintain their
                    // positions." The rows used to sit BELOW the action row,
                    // which put the page's two doors between his writing and
                    // his voice. The action row's own position and order are
                    // untouched.
                    if !voiceNoteAttachments.isEmpty {
                        voiceNotesSection
                    }

                    colophon
                    actionRow

                    if photoAttachments.count > 1 {
                        remainingPhotosGrid
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The same ground as the feed this page opens from -- see
        // `JournalGround` for why dark mode gets a crimson wash and light mode
        // is left exactly as it is. A page that dropped the tint the moment he
        // tapped a card would have answered half his report and created the
        // other half.
        .background { JournalGround() }
    }

    /// The per-entry stats Apple's own Journal shows when reading an entry
    /// back -- his ask verbatim: *"a bar displayed when later clicking back on
    /// a specific journal item that displays stuff like total writing time and
    /// etc. also the Apple officials journal app features like total words."*
    ///
    /// Words and reading time are derived from the text itself, so every
    /// entry has them, imported ones included. Writing time reads
    /// `writingSeconds`, which only compose sessions accumulate -- entries
    /// from before the field existed (and imports, whose writing time is
    /// genuinely unknown) simply don't show that segment rather than showing
    /// a fake zero.
    /// A colophon, not a stats bar.
    ///
    /// It used to sit boxed ABOVE the writing, which put a word count between
    /// him and his own words. A book puts its production details at the end,
    /// quietly, in one line -- and this is his book. Apple Journal shows
    /// nothing per entry at all, so this is one of the places Cobux can simply
    /// be better rather than matching.
    private var entryDate: Date { entry.modifiedDate ?? entry.dateImported }

    private static let dayNumeralFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d"; return f
    }()
    private static let weekdayMonthYearFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE · MMMM yyyy"; return f
    }()
    static func dayNumeral(_ date: Date) -> String { dayNumeralFormatter.string(from: date) }
    static func weekdayMonthYear(_ date: Date) -> String { weekdayMonthYearFormatter.string(from: date) }

    private var colophon: some View {
        let words = entry.text.split(whereSeparator: \.isWhitespace).count
        // A spoken entry has no word count worth printing. Build 58, Rajan:
        // "the number of words for a voice recording is kinda stupid." When
        // the text is empty or only the session stamp and the entry carries
        // voice notes, the production line says how long he spoke instead --
        // "2 min voice note" -- and no reading time (there is nothing to
        // read). When there are real words too, the words stay and the
        // duration follows them. Still a fact about the object, never a
        // score.
        let spoken = voiceDurations.values.reduce(0, +)
        let hasVoice = !voiceNoteAttachments.isEmpty
        let textIsOnlyStamp = JournalHighlightSelector.stripStamp(entry.text)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var parts: [String] = []
        if hasVoice && textIsOnlyStamp {
            if spoken > 0 { parts.append(Self.voiceDurationLabel(seconds: spoken, notes: voiceNoteAttachments.count)) }
        } else {
            parts.append("\(words) word\(words == 1 ? "" : "s")")
            if hasVoice, spoken > 0 {
                parts.append(Self.voiceDurationLabel(seconds: spoken, notes: voiceNoteAttachments.count))
            }
        }
        if let seconds = entry.writingSeconds, seconds > 0 {
            parts.append(writingTimeLabel(seconds: seconds))
        }
        // 200 wpm -- the same ballpark reading-time convention everywhere.
        if !(hasVoice && textIsOnlyStamp) {
            parts.append("\(max(1, Int((Double(words) / 200).rounded()))) min read")
        }
        // Where it was written, quietly, when known. A fact in the colophon,
        // never a badge.
        if let locality = entry.locality, !locality.isEmpty {
            parts.append(locality)
        }

        return Text(parts.joined(separator: " · "))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 28)
    }

    /// "45s voice note" under a minute, "2 min voice note" beyond; "of voice
    /// notes" when there is more than one. Rounded to the nearest minute the
    /// way `writingTimeLabel` is -- a production detail, not a stopwatch.
    static func voiceDurationLabel(seconds: TimeInterval, notes: Int) -> String {
        let noun = notes > 1 ? "of voice notes" : "voice note"
        if seconds < 60 { return "\(Int(seconds.rounded())) s \(noun)" }
        return "\(max(1, Int((seconds / 60).rounded()))) min \(noun)"
    }

    /// The recordings, then under each the words it said. The transcript
    /// sets in the passage face like the rest of his writing -- it IS his
    /// writing, spoken -- under a quiet "Transcript" kicker. Three states and
    /// two of them are silent: `pending` shows one line, `done` shows the
    /// words (or nothing, for a silent note), and `failed`/`unavailable`/
    /// unknown show nothing at all. No error copy: a missing transcript is
    /// not something he can act on from this page.
    private var voiceNotesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(voiceNoteAttachments) { attachment in
                VStack(alignment: .leading, spacing: 8) {
                    JournalVoiceNoteRow(attachmentID: attachment.id)
                    if let snapshot = transcripts[attachment.id] {
                        switch snapshot.state {
                        case .pending:
                            Text("Transcribing…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                        case .done:
                            if let words = snapshot.transcript, !words.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Transcript")
                                        .font(.caption2.weight(.semibold))
                                        .textCase(.uppercase)
                                        .kerning(0.7)
                                        .foregroundStyle(.secondary)
                                    Text(words)
                                        .font(CobuxTypography.passage(size: 15))
                                        .lineSpacing(4)
                                        .textSelection(.enabled)
                                }
                                .padding(.horizontal, 4)
                            }
                        case .failed, .unavailable:
                            EmptyView()
                        }
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    /// Two acts, kept legible side by side: CONTINUE (toolbar) appends to
    /// this page; WRITE BACK answers it from today. The Correspondence's
    /// visible door lives here, ungated beyond the journal lock -- he
    /// navigated to this entry; answering it is pull.
    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                // The tip that explains this door retires the first time the
                // door is used, from either place it can be opened.
                CobuxTip.writeBack.markUsed()
                writeBackSession = true
            } label: {
                Label("Write back", systemImage: "arrowshape.turn.up.left")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.cobuxAccent.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            // The one thing Apple Journal structurally cannot do: this app
            // has a brain attached to the same library the entry sits beside.
            Button {
                openURL(CobuxDeepLink.journalChatURL(prefill: Self.reflectionPassage(for: entry)))
            } label: {
                Label("Reflect on this in Chat", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.cobuxAccent.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    /// What "Reflect on this in Chat" carries across.
    ///
    /// THE BUG THIS FIXES: the button's entire action was
    /// `openURL(URL(string: "cobux://chat")!)`. It named no entry, carried no
    /// text and set no thread -- it switched to the Chat tab with an empty
    /// composer and the entry left behind. His report was exact: *"a journal
    /// entryies reflect onthis in chat is not workng toatlly broken."* There
    /// was nothing wrong with the plumbing because there was no plumbing.
    ///
    /// It now uses the route that already existed and that three other
    /// surfaces already use -- Ebb, `JournalHighlightCard`, and Flow's cards
    /// all call `CobuxDeepLink.journalChatURL(prefill:)`. That route opens the
    /// JOURNAL thread (`ChatPromptBuilder.journalThreadID`) and pre-fills the
    /// composer. Deliberately not a second mechanism: the journal thread's
    /// prompt is already grounded in his entries through
    /// `SearchService.buildJournalContext`, so the model reaches the real,
    /// whole entry through the path it always uses, and this quote is the
    /// human-visible pointer saying WHICH entry he means. Nothing is written
    /// into the chat store, and no entry is duplicated as a message -- the
    /// composer is pre-filled and not sent, so he can edit or delete it before
    /// anything is billed. `ChatView`'s prefill rule holds: a non-empty
    /// composer is never overwritten.
    ///
    /// The session stamp is stripped for the same reason
    /// `JournalHighlightSelector.stripStamp` exists -- quoting "9:01 AM" back
    /// at himself is quoting the machinery, not the writing.
    ///
    /// Capped, and it SAYS it is capped. A day's writing can run for pages, and
    /// a composer opened with pages in it is not something anyone edits; the
    /// ellipsis plus the trailing line make clear that this is an excerpt and
    /// that the rest is not lost.
    private static let reflectionPassageLimit = 1_200

    static func reflectionPassage(for entry: PersonalWritingEntry) -> String {
        let body = JournalHighlightSelector.stripStamp(entry.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count > reflectionPassageLimit else { return body }
        // Cut on a word boundary so the excerpt does not end mid-word.
        let head = body.prefix(reflectionPassageLimit)
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespacesAndNewlines)
            + "…\n\n(Excerpt — the rest is in your journal.)"
    }

    /// The quoted original above a reply. Three honest states:
    /// resolvable-and-surfaceable (kicker + excerpt + door), resolvable but
    /// quieted/suppressed (kicker + door -- POINTS instead of quoting: he
    /// opened the reply, not the original, and re-quoting quieted material
    /// here would be the one surface that walks him back into it), and
    /// dangling post-restore (kicker from the stored date alone -- quieter,
    /// never a lie).
    @ViewBuilder
    private var correspondenceHeader: some View {
        if let linkDate = entry.answersEntryDate, entry.answersEntryID != nil {
            let month = Calendar.current.component(.month, from: linkDate)
            let hue = Color.cobuxMonthHue(month, dark: colorScheme == .dark)
            VStack(alignment: .leading, spacing: 8) {
                Text(JournalEntryComposeView.answeringKicker(
                    date: linkDate,
                    certain: answeredOriginal?.modifiedDate != nil || answeredOriginal == nil))
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .kerning(0.7)
                    .foregroundStyle(hue)
                if let original = answeredOriginal,
                   JournalHighlightSelector.maySurface(original.text),
                   !EbbSuppressionStore.suppressedIDs().contains(original.id) {
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(hue.opacity(0.3))
                        .frame(width: 40, height: 1)
                    Text(JournalHighlightSelector.stripStamp(original.text))
                        .font(CobuxTypography.passage(size: 15))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                        .lineLimit(6)
                }
                if let original = answeredOriginal {
                    NavigationLink(destination: JournalEntryDetailView(entry: original)) {
                        Label("Read the entry", systemImage: "chevron.right")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(hue)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 4)
        }
    }

    /// Later answers to THIS entry, as quiet dated footnote rows. Zero
    /// answers renders nothing; the feed never marks answered-ness at all --
    /// an entry reveals its correspondence only when opened.
    @ViewBuilder
    private var laterAnswerLines: some View {
        if !laterAnswers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(laterAnswers) { answer in
                    let date = answer.modifiedDate ?? answer.dateImported
                    let hue = Color.cobuxMonthHue(
                        Calendar.current.component(.month, from: date),
                        dark: colorScheme == .dark)
                    NavigationLink(destination: JournalEntryDetailView(entry: answer)) {
                        HStack(spacing: 6) {
                            Text("You answered this · \(Self.answerLineDate(date))")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(hue)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
    }

    /// Built once, not per call. `answerLineDate` is called from inside the
    /// `ForEach` over `laterAnswers` above, so a fresh `DateFormatter` here was
    /// one construction -- locale, calendar and date symbols -- per answer row
    /// per body evaluation.
    ///
    /// Safe to share: nothing mutates it after construction (the documented
    /// condition for `DateFormatter` reuse), and every caller is on the main
    /// actor -- the same pair of conditions `ChatView`'s time-mark formatters
    /// are documented under.
    private static let answerLineFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    private static func answerLineDate(_ date: Date) -> String {
        answerLineFormatter.string(from: date)
    }


    /// "45s" under a minute, "12 min" under an hour, "1h 20m" beyond --
    /// short at every scale, never "0 min" for a real quick note.
    private func writingTimeLabel(seconds: Int) -> String {
        switch seconds {
        case ..<60: return "\(seconds)s writing"
        case ..<3600: return "\(seconds / 60) min writing"
        default: return "\(seconds / 3600)h \((seconds % 3600) / 60)m writing"
        }
    }

    /// The first photo, the full width of the reading column and rounded to
    /// the card radius, so an entry with a photo opens on it the way Apple's
    /// own Journal leads with an entry's lead image. (Not full-bleed, and no
    /// scrim: it keeps the same horizontal margin the text does, and there is
    /// no gradient over it. The type's doc comment used to claim both.)
    ///
    /// No aspect ratio is imposed on the loaded photo. It used to sit in a
    /// fixed 4:3 box while `JournalHeroImage` filled that box -- so a portrait
    /// or panoramic photo had everything outside the centre 4:3 thrown away,
    /// which he reported twice: "It should display like the whole image." The
    /// 4:3 now belongs to the placeholder alone (see `JournalHeroImage`), which
    /// still needs a shape before there is a photo to take one from.
    private func heroPhoto(attachmentID: UUID) -> some View {
        JournalHeroImage(attachmentID: attachmentID)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: CobuxRadius.card))
            .padding(.horizontal)
    }

    /// Read-only -- deleting/adding photos is an editing action, which this
    /// screen deliberately doesn't do (see the type's own doc comment: viewing
    /// never puts a fresh timestamp on an entry, and by the same reasoning it
    /// shouldn't silently mutate its attachments either). "Continue Entry" is
    /// the one path that can actually change them. Skips the first photo --
    /// that one already got the hero treatment above, this grid is only the
    /// rest.
    /// Attachments are stored in one list regardless of kind, and
    /// `JournalAttachment` carries no kind field -- the file extension on disk
    /// is the only signal. `isVoiceNote(id:)` existed for exactly this and was
    /// called from nowhere, which is how voice notes ended up rendering as
    /// blank photo tiles.
    private var voiceNoteAttachments: [JournalAttachment] {
        entry.attachments.filter { JournalAttachmentStore.isVoiceNote(id: $0.id) }
    }

    private var photoAttachments: [JournalAttachment] {
        entry.attachments.filter { !JournalAttachmentStore.isVoiceNote(id: $0.id) }
    }

    /// Each tile is the list's own `JournalThumbnailImage` -- the 900px tier,
    /// loaded once per attachment id off the main thread and cached in that
    /// view's own state. This used to call `JournalAttachmentStore.image(for:)`
    /// inline in the body: a disk read plus a 1600px JPEG decode per photo,
    /// re-run for every photo on EVERY body re-evaluation. The 1600px tier
    /// is the hero's alone.
    private var remainingPhotosGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(photoAttachments.dropFirst()) { attachment in
                // `JournalThumbnailImage` fills and crops on its own now; the
                // `.aspectRatio(.fill)` that used to sit here was applied to
                // the WRAPPER, which does nothing to the image inside it, and
                // the image had no ratio of its own -- so a portrait photo
                // was squashed into this 100pt tile. See the thumbnail's doc
                // comment for his report.
                JournalThumbnailImage(attachmentID: attachment.id)
                    .frame(height: 100)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: CobuxRadius.card))
            }
        }
    }
}

/// Loads the full-size image for the hero photo -- unlike the list's
/// `JournalThumbnailImage`, this screen genuinely wants full resolution
/// since it's the one large, prominent rendering of this photo. Off the
/// main thread: a 1600px JPEG decode is milliseconds of work that has no
/// business on the thread drawing the transition into this screen.
private struct JournalHeroImage: View {
    let attachmentID: UUID
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                // `.fit`, not `.fill`: the whole photo, top and bottom
                // included. `.fill` inside the fixed 4:3 frame this used to
                // sit in is what cropped every photo that was not 4:3. With
                // no frame imposed, a `.fit` resizable image takes the width
                // it is offered and derives its own height, so the entry
                // opens on the photo he actually took.
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // The 4:3 lives here now. A placeholder has no intrinsic size
                // to derive a height from, and without a ratio it would
                // collapse to nothing and then jolt the whole screen open when
                // the decode landed.
                Color.cobuxSurface2
                    .aspectRatio(4 / 3, contentMode: .fit)
            }
        }
        .task(id: attachmentID) {
            let id = attachmentID
            image = await Task.detached(priority: .userInitiated) {
                JournalAttachmentStore.image(for: id)
            }.value
        }
    }
}
