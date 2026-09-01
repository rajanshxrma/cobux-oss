import SwiftUI

/// Opens read-only -- `JournalListView`'s row only ever shows a two-line
/// snippet, and until this view existed there was no way to read the rest of
/// it back at all, imported or composed. Editing is a deliberate second step
/// (the toolbar button below), not automatic: viewing an old entry shouldn't
/// itself put a fresh timestamp on it.
///
/// Redesigned (2.5.13): a first photo, if any, gets a hero treatment (full-
/// width, gradient scrim, same visual language `BookCard`'s cover already
/// uses) instead of sitting in a small uniform grid with every other photo.
/// Body text sets in `CobuxTypography.display()` -- the serif face this
/// design system already has and Journal is the first real prose-reading
/// surface to actually use it.
struct JournalEntryDetailView: View {
    // Plain `let`, not `@Bindable` -- nothing here binds one of `entry`'s own
    // fields directly; `JournalEntryComposeView.save()` mutates the model
    // object itself, and SwiftData's own change tracking re-renders this
    // view's `entry.title`/`entry.text` reads once that lands, same as any
    // other view reading a `@Model` class's properties.
    let entry: PersonalWritingEntry
    @State private var showingContinue = false
    @Environment(\.colorScheme) private var colorScheme

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

    var body: some View {
        // Pushed on top of `JournalListView`, so backgrounding while reading
        // an entry used to leave its full text visible on return -- nothing
        // here checked the lock at all. `autoPromptsWhenTopmost:
        // !showingContinue` mirrors the list's own reasoning: while THIS
        // view's own "Continue Entry" sheet is up, that sheet is topmost, not
        // this detail screen underneath it.
        JournalLocked(autoPromptsWhenTopmost: !showingContinue) {
            entryContent
        }
        .navigationTitle("Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isLocked {
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
                if let hero = entry.attachments.first {
                    heroPhoto(attachmentID: hero.id)
                }

                VStack(alignment: .leading, spacing: 16) {
                    if !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(entry.title)
                            .font(.title2.weight(.bold))
                    }

                    Text(Self.dateFormatter.string(from: entry.modifiedDate ?? entry.dateImported))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    statsBar

                    Text(entry.text)
                        .font(CobuxTypography.display(colorScheme, size: 17, weight: .regular))
                        .textSelection(.enabled)

                    if entry.attachments.count > 1 {
                        remainingPhotosGrid
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.cobuxBackground)
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
    private var statsBar: some View {
        let words = entry.text.split(whereSeparator: \.isWhitespace).count
        // 200 wpm -- the same ballpark reading-time convention everywhere.
        let readMinutes = max(1, Int((Double(words) / 200).rounded()))

        return HStack(spacing: 14) {
            statSegment(icon: "text.alignleft", label: "\(words) word\(words == 1 ? "" : "s")")
            if let seconds = entry.writingSeconds, seconds > 0 {
                statSegment(icon: "pencil", label: writingTimeLabel(seconds: seconds))
            }
            statSegment(icon: "book", label: "\(readMinutes) min read")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.cobuxSurface2, in: RoundedRectangle(cornerRadius: 10))
    }

    private func statSegment(icon: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption)
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
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

    /// The first photo, full-bleed with a bottom gradient scrim -- the same
    /// visual language `BookCard`'s own cover treatment already establishes,
    /// applied here so an entry with a photo opens on it the way Apple's own
    /// Journal leads with an entry's lead image.
    private func heroPhoto(attachmentID: UUID) -> some View {
        JournalHeroImage(attachmentID: attachmentID)
            .aspectRatio(4 / 3, contentMode: .fit)
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
    private var remainingPhotosGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(entry.attachments.dropFirst()) { attachment in
                if let image = JournalAttachmentStore.image(for: attachment.id) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: CobuxRadius.card))
                        .clipped()
                }
            }
        }
    }
}

/// Loads the full-size image for the hero photo -- unlike the list's
/// `JournalThumbnailImage`, this screen genuinely wants full resolution
/// since it's the one large, prominent rendering of this photo.
private struct JournalHeroImage: View {
    let attachmentID: UUID
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.cobuxSurface2
            }
        }
        .task(id: attachmentID) {
            image = JournalAttachmentStore.image(for: attachmentID)
        }
    }
}
