import SwiftUI

/// One journal entry, as a card on paper.
///
/// The organizing idea, from Fable: **the journal is the book Rajan is writing,
/// and Cobux gives it the same reverence it gives the books he reads.**
///
/// This is the second pass. The first fixed a real inversion — his writing was
/// rendered grey while the timestamp above it was bold — but he said twice the
/// screen was still dull, and he was right. Four things compounded: every card
/// opened with the SAME uppercase accent caption, so twenty cards were twenty
/// identical openings announcing the least important fact; a six-word note and
/// a 484-word essay got the same rectangle, so the feed had no rhythm; and 5pt
/// gaps made a table rather than a page.
///
/// Three changes answer it, none of them decoration:
///
/// 1. **The words lead.** The caption leaves the top and returns as a quiet
///    lowercase footer. A card now opens with what he wrote.
/// 2. **The first-line device.** The opening sentence is set semibold and the
///    rest regular, so every card gets an individual headline drawn from his own
///    text — twenty different openings because he wrote twenty different
///    things, at zero chrome cost.
/// 3. **Three shapes by length.** A one-liner is set whole and italic, treated
///    as an aphorism rather than a half-empty box; a long entry gets an extra
///    line and a read time, so it looks long.
struct JournalEntryCard: View {
    let entry: PersonalWritingEntry
    /// Body text with the session stamp stripped, supplied by the caller so the
    /// stripping rule lives in one place.
    let preview: String
    /// How many writing sessions the entry holds. One for almost everything;
    /// more whenever "Continue Entry" has appended a later sitting under its own
    /// time stamp. `preview` carries only the FIRST of them, so this is what
    /// tells the card there is more behind it (`JournalListView.preview(for:)`).
    var sessions: Int = 1

    @Environment(\.colorScheme) private var colorScheme
    /// width / height of the loaded thumbnail, reported by
    /// `JournalThumbnailImage` once its decode lands. Drives the photo box.
    @State private var photoRatio: CGFloat?

    // The feed was typeset at reading size. `JournalEntryDetailView` reads at
    // 19pt serif and the card body sat at 17 -- two points below the full
    // reading view -- with a SEMIBOLD 17pt lead on top and a 20pt title above
    // that. Every card was an open book, three to a screen, all of it heavy.
    // Rajan on build 49: "this font look too big in the journals and kinda ugly".
    // A feed excerpt should read as clearly subordinate to the view it opens.
    //
    // `@ScaledMetric` rather than fixed points, which is also a fix in itself:
    // these sizes never responded to Dynamic Type before.
    //
    // Second pass, build 53, because he said it again -- "the spacing here
    // bewten saved jounals entries and the font and overall looks ugly and not
    // claen and simple and sleak" -- and the numbers say why he was right twice.
    // The detail view came down 19 -> 17 for exactly this complaint ("how old
    // peole have their font all large on their phones"), which left the card's
    // title at 17 EQUAL to the page it opens and its short-entry face at 16, one
    // point under. Each went a clear step below: title 15, body 14, note 15.
    //
    // Third pass, build 56, and this one went one step too far: *"in the list of
    // the Journal section where the journals are displayed the font is a little
    // too small in my opinion. It should be a little bit bigger. I think it was
    // bigger in the beginning."* He is remembering correctly -- 1683e4e, the
    // commit that first set the feed in his own type, ran title 17 / body 15,
    // and 176bbbe took it to 15 / 14 answering a complaint that named SPACING
    // first and the font second. One point back on each, which is as far as the
    // caps below allow anyway: 16 / 15 / 16.
    @ScaledMetric(relativeTo: .subheadline) private var titleSize: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var bodySize: CGFloat = 15
    @ScaledMetric(relativeTo: .subheadline) private var noteSize: CGFloat = 16

    /// The size the page behind this card reads at (`JournalEntryDetailView`'s
    /// entry body), as a FIXED point size -- it is written `size: 17` there, so
    /// it does not grow with Dynamic Type.
    ///
    /// These three do, and that asymmetry was a real inversion rather than a
    /// nicety: at any text size above the default, `@ScaledMetric` pushed a
    /// 15pt card title past a 17pt page, so the excerpt was literally SET LARGER
    /// than the entry it opens. Scaling still happens -- an accessibility size
    /// still enlarges the feed -- it just cannot climb past the page.
    private static let detailBodySize: CGFloat = 17
    /// A card's title/aphorism face: one point under the page, at most.
    private var headSize: CGFloat { min(titleSize, Self.detailBodySize - 1) }
    /// A card's running body: two points under the page, at most.
    private var readSize: CGFloat { min(bodySize, Self.detailBodySize - 2) }
    private var aphorismSize: CGFloat { min(noteSize, Self.detailBodySize - 1) }

    private static let answersFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private var date: Date { entry.modifiedDate ?? entry.dateImported }

    /// A note is short enough to show whole; a long-read earns extra lines and a
    /// reading time. The middle case is the ordinary entry.
    private enum Shape { case note, entry, longRead }

    /// Everything about this card that costs something to work out, resolved
    /// ONCE when the card is constructed rather than repeatedly while it draws.
    ///
    /// These four were computed properties, and Swift re-runs a computed
    /// property on every single access. `shape` reads `wordCount` on two
    /// separate lines, and `shape` is itself read three times -- from
    /// `content`, from `bodyLines` and from `footer` -- with two more direct
    /// reads of `wordCount` beside them. That is up to eight passes over the
    /// excerpt's characters per card, per body evaluation, inside a `ForEach`.
    /// The previous fix here removed the *allocation* in that loop but not the
    /// number of times it ran.
    ///
    /// `photoAttachment` and `hasVoiceNote` were worse in kind, not just in
    /// degree: two independent faults of the entry's `attachments`
    /// relationship -- a query each -- scanned separately, and read up to four
    /// times between `body` and `footer`. One pass answers both now.
    ///
    /// Every input is fixed for the life of the view value (`entry`, `preview`
    /// and `sessions` are all set at init), so nothing here could have changed
    /// between those repeated reads. Same values, one traversal each.
    private struct RowFacts {
        var photo: JournalAttachment?
        var hasVoiceNote = false
        var wordCount = 0
        var shape: Shape = .entry
    }

    private let facts: RowFacts

    init(entry: PersonalWritingEntry, preview: String, sessions: Int = 1) {
        self.entry = entry
        self.preview = preview
        self.sessions = sessions
        self.facts = Self.makeFacts(entry: entry, preview: preview, sessions: sessions)
    }

    /// Main-actor by inheritance from the view's own init -- it reads a
    /// `@Model` relationship, which never leaves that actor in this codebase.
    @MainActor
    private static func makeFacts(entry: PersonalWritingEntry,
                                  preview: String,
                                  sessions: Int) -> RowFacts {
        var facts = RowFacts()

        // ONE fault of the relationship, one scan. `photo` keeps
        // `first { !isVoiceNote }`'s exact meaning -- the first non-voice
        // attachment in the array's own order -- and `hasVoiceNote` keeps
        // `contains { isVoiceNote }`'s. The scan no longer short-circuits on
        // the photo, which is the price of answering both questions in one
        // pass, and it is a scan of one entry's attachments rather than a
        // second trip to the store.
        for attachment in entry.attachments {
            if JournalAttachmentStore.isVoiceNote(id: attachment.id) {
                facts.hasVoiceNote = true
            } else if facts.photo == nil {
                facts.photo = attachment
            }
        }

        // Counted, not split. This was
        // `preview.split(whereSeparator: \.isWhitespace).count` -- an array of
        // `Substring`s allocated to produce one integer. The loop allocates
        // nothing and counts the same runs `split` would have produced (which
        // also omits empty ones).
        var count = 0
        var inWord = false
        for character in preview {
            if character.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        facts.wordCount = count

        // `wordCount` measures the EXCERPT, which is one sitting. A day picked
        // back up in the evening is never an aphorism however short its first
        // sitting was, so the note shape is off the table the moment there is
        // more than one.
        if count < 25, sessions == 1 {
            facts.shape = .note
        } else if count > 150 {
            facts.shape = .longRead
        } else {
            facts.shape = .entry
        }

        return facts
    }

    // Stored reads now, not recomputation. Kept under their original names so
    // every call site below reads exactly as it did.
    private var wordCount: Int { facts.wordCount }
    private var photoAttachment: JournalAttachment? { facts.photo }
    private var hasVoiceNote: Bool { facts.hasVoiceNote }
    private var shape: Shape { facts.shape }

    private var title: String { entry.title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Splits the preview at its first sentence break so the opening can be set
    /// heavier than the rest. Falls back to the whole string when there is no
    /// clean break, which is common in his fastest entries.
    private var split: (lead: String, rest: String) {
        let body = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if let newline = body.firstIndex(of: "\n") {
            let lead = String(body[..<newline]).trimmingCharacters(in: .whitespaces)
            if lead.count >= 12 {
                return (lead, String(body[newline...]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if let range = Self.sentenceBreak(in: body),
           body.distance(from: body.startIndex, to: range.lowerBound) >= 12 {
            return (String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespaces),
                    String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        return (body, "")
    }

    /// The first whitespace that follows a sentence-ending mark.
    ///
    /// Compiled ONCE. This was `body.range(of: #"(?<=[.!?])\s"#, options:
    /// .regularExpression)` -- and that call compiles a fresh ICU regex on
    /// every invocation, from inside a card body inside the journal feed's
    /// `ForEach`. Exactly the shape `JournalSessionStamp.isStampLine` was just
    /// fixed for, on the same screen.
    ///
    /// Optional rather than `try!` for the same reason as there: a pattern that
    /// somehow failed to compile must not take a journal card down. The
    /// fallback is `nil`, which `split` already handles -- the lead sentence is
    /// simply not set heavier, and no writing is lost or hidden.
    private nonisolated(unsafe) static let sentenceBreakMatcher: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"(?<=[.!?])\s"#)

    private static func sentenceBreak(in text: String) -> Range<String.Index>? {
        guard let matcher = sentenceBreakMatcher else { return nil }
        let full = NSRange(text.startIndex..., in: text)
        guard let match = matcher.firstMatch(in: text, range: full) else { return nil }
        return Range(match.range, in: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let photo = photoAttachment {
                // The photo at its own proportions. This was a bare resizable
                // image in a `maxHeight: 320` frame, and with no aspect ratio
                // of its own the image took whatever box the frame left -- his
                // portrait shots came out squashed. Rajan, build 57: "it kind
                // of compresses the dimensions and it kinda looks weird ...
                // makes it square or whatever ... I really want the thumbnail
                // ... to still remain the same dimensions of the image ... crop
                // is fine if the cropping is not too bad."
                //
                // So the container takes the LOADED image's ratio and the
                // image fills it: a landscape or 3:4 photo shows entire, and
                // anything taller than 3:4 (a 9:16 screenshot) is held at 3:4
                // and cropped mildly at the edges -- the "not too bad" crop,
                // chosen over a card that would otherwise be taller than the
                // screen. Nothing is ever stretched. 4:3 until the decode
                // lands, so the card has a shape before it has a photo.
                Color.clear
                    .aspectRatio(max(photoRatio ?? 4 / 3, 0.75), contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        JournalThumbnailImage(attachmentID: photo.id) { size in
                            guard size.height > 0 else { return }
                            photoRatio = size.width / size.height
                        }
                    }
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 10) {
                content
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Color.cobuxSurface)
        .clipShape(RoundedRectangle(cornerRadius: CobuxRadius.card, style: .continuous))
        // Dark mode only: elevation is carried by a lighter card plus one
        // hairline. No shadow in either theme -- many small soft shadows across
        // a scrolling feed read as smudge rather than depth.
        .overlay {
            if colorScheme == .dark {
                RoundedRectangle(cornerRadius: CobuxRadius.card, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            }
        }
        .accessibilityElement(children: .combine)
        // Time first for VoiceOver even though it is visually last.
        .accessibilityLabel("\(Self.timeFormatter.string(from: date)), \(wordCount) words.\(sessions > 1 ? " Written in \(sessions) sittings." : "")\(entry.answersEntryDate.map { " Answers your entry from \(Self.answersFormatter.string(from: $0))." } ?? "") \(preview)")
    }

    /// The face for everything on this card that HE wrote.
    ///
    /// `CobuxTypography.passage`, not `display`, and this is the other half of
    /// his report -- he could not name which half: *"I think it's a little too
    /// small, or maybe it's not small, I don't know, but something, the font
    /// style maybe is kind of making it look weird."*
    ///
    /// `display` is theme-dependent BY DESIGN: serif in light, plain SF in dark
    /// (the split is documented at the top of `CobuxTypography`, and it governs
    /// CHROME -- wordmarks, numerals, the instrument panel). So on his dark-mode
    /// phone the archive card at the top of this very screen quoted his writing
    /// in the serif book face while every entry card under it set the same
    /// writing in SF. One screen, one voice, two faces, six inches apart. That
    /// is a face difference, not a size one, and it is exactly the "weird" a
    /// person notices without being able to name.
    ///
    /// `passage` is serif in BOTH themes and its own doc comment already claims
    /// this surface -- "the book face, in both themes, everywhere his writing is
    /// quoted". A feed excerpt is his writing quoted. In light mode this changes
    /// nothing at all (`display` already resolves to serif there); in dark mode
    /// the feed stops being the one place in the journal that speaks in a
    /// different voice. The footer stays `.system` -- that is chrome, and chrome
    /// keeps its own face.
    private func writing(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        CobuxTypography.passage(size: size, weight: weight)
    }

    @ViewBuilder
    private var content: some View {
        if !title.isEmpty {
            // A real title replaces the first-line device.
            Text(title)
                .font(writing(headSize, .semibold))
                .lineLimit(2)
            if !preview.isEmpty {
                Text(preview)
                    .font(writing(readSize))
                    .lineSpacing(4)
                    .lineLimit(bodyLines)
            }
        } else if shape == .note {
            // Short entries are aphorisms, not stubs. Set whole and italic so
            // they read as intentional objects rather than empty boxes.
            Text(preview)
                .font(writing(aphorismSize).italic())
                .lineSpacing(4)
        } else {
            let parts = split
            if parts.rest.isEmpty {
                // No clean opening line to promote. One weight for the whole
                // excerpt -- the old code set the entire body `.medium` in this
                // case, which is how a card ended up looking heavy for no reason
                // a reader could name.
                Text(parts.lead)
                    .font(writing(readSize))
                    .lineSpacing(4)
                    .lineLimit(bodyLines)
            } else {
                // A borrowed title, at BODY size.
                //
                // The device stays -- an opening sentence set heavier is what
                // gives twenty cards twenty different openings at zero chrome
                // cost. What goes is the extra point of SIZE it was carrying.
                //
                // A typed title is a separate object and keeps `headSize`. A
                // borrowed lead is not: it is the first sentence of the very
                // paragraph printed underneath it, and setting one sentence of a
                // paragraph a point larger AND heavier AND clipped to one line
                // is three signals for one idea. Reading down the card, the type
                // visibly changed size mid-thought. Same size, heavier weight,
                // one line: a headline drawn from the text without breaking the
                // text. (a286d35, the version he liked, set lead and body at the
                // same 17 for exactly this reason; the size split arrived later
                // with the shrink.)
                Text(parts.lead)
                    .font(writing(readSize, .semibold))
                    .lineLimit(1)
                Text(parts.rest)
                    .font(writing(readSize))
                    .lineSpacing(4)
                    .lineLimit(bodyLines)
            }
        }
    }

    private var bodyLines: Int { shape == .longRead ? 4 : 3 }

    /// Quiet, lowercase, and at the BOTTOM. Metadata is the least important
    /// thing on the card, and it used to be the first thing announced.
    private var footer: some View {
        HStack(spacing: 6) {
            Text(Self.timeFormatter.string(from: date).lowercased())
            // A day written in more than one sitting, said once and quietly.
            //
            // The card's excerpt is the FIRST session only, because the alternative
            // is what he was looking at: "Continue Entry" appends a fresh stamp
            // mid-body ("9:01 AM"), the excerpt ran straight through it, and one
            // entry written twice read as "one card with two entries stacked in it
            // and a timestamp floating between them". Truncating at the seam kills
            // the floating timestamp; this line is what keeps the truncation
            // honest, so a longer entry is never silently made to look short.
            if sessions > 1 {
                Text("·")
                Text("\(sessions) sittings")
            }
            // The Correspondence's one feed fact: a reply often reads
            // mid-conversation, and the date it answers is what makes it
            // legible. Read from the STORED date -- zero fetches, O(1), safe
            // on the feed's render path. The ORIGINAL is never marked here:
            // answered-ness as a visible feed state is completion-state
            // creep, the checkmark wearing a new hat.
            if let answersDate = entry.answersEntryDate {
                Text("·")
                Text("answers \(Self.answersFormatter.string(from: answersDate).lowercased())")
            }
            // An entry can legitimately have no words -- a voice note or a
            // photo is a real entry. Saying "0 words" about one described what
            // it lacked instead of what it is.
            if preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("·")
                Text(hasVoiceNote ? "Voice note" : (photoAttachment != nil ? "Photo" : "No words yet"))
            }
            // No word count. It is bookkeeping -- the card's own height already
            // says how long an entry is -- and it was the third thing competing
            // in a footer that should be quiet. A long read keeps its "N min
            // read", which is the version of that fact a browser actually uses.
            // `wordCount` stays in the accessibility label below, so VoiceOver
            // loses nothing.
            // Only for a single-sitting entry. `wordCount` is the excerpt's, so
            // on a multi-sitting entry a reading time derived from it would
            // understate the real one -- and the sittings count above is already
            // the honest length signal there.
            if shape == .longRead, sessions == 1 {
                Text("·")
                Text("\(max(1, wordCount / 200)) min read")
            }
            if hasVoiceNote {
                Text("·")
                Image(systemName: "waveform")
            }
            Spacer(minLength: 0)
            // Provenance as a quiet pill at the trailing end, so the footer has
            // two composed ends rather than one mumble. The eight raw source
            // strings collapse to the five families he actually thinks in.
            JournalSourcePill(family: JournalSourceFamily(source: entry.source))
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}
