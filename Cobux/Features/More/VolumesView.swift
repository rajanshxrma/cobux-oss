import SwiftUI
import SwiftData
import PDFKit

/// The shelf of bound volumes, and the binder itself.
///
/// Self-wrapped in `JournalLocked` — a pushed surface does not inherit the
/// gate (the documented bypass), and a volume is the journal at its most
/// concentrated. Everything here is pull: the shelf waits to be looked for,
/// volumes leave the device only through his explicit share tap.
struct VolumesView: View {
    @State private var volumes: [VolumeStore.BoundVolume] = []
    /// Identity, not a Bool -- `ComposeSession`'s lesson: a Bool presented
    /// from inside the subtree the lock gate swaps latches `true` after the
    /// dropped presentation, and every later tap is a silent no-op.
    @State private var binderSession: BinderSession?
    @State private var removing: VolumeStore.BoundVolume?
    /// Whether the shelf has actually been read off disk yet. Load-bearing:
    /// `volumes` starts empty and is filled in `.task`, so without this a full
    /// shelf would flash "you have nothing" on every single visit -- the one
    /// sentence an empty state must never say to someone who does have books.
    @State private var shelfRead = false
    /// Page count per volume, read once when the shelf loads.
    ///
    /// The subtitle used to open a `PDFDocument` per row -- inside `body`, from
    /// a `ForEach` -- purely to read `pageCount`. That is opening and parsing
    /// every bound volume on the shelf on every body evaluation, and it built a
    /// fresh `DateFormatter` for each one on the way past. A volume is a
    /// rendering on disk; its page count cannot change while the shelf is open,
    /// so it is read with the shelf and never again.
    @State private var pageCounts: [URL: Int] = [:]

    var body: some View {
        // The sheet and the dialog hang off THIS view, not off the content
        // inside the gate, the way `JournalListView` presents its own -- a
        // lock transition swaps that subtree and would drop them mid-flight.
        // While the binder is up it is the topmost screen, so the gate
        // underneath must not throw Face ID over it.
        JournalLocked(autoPromptsWhenTopmost: binderSession == nil) {
            Group {
                if shelfRead, volumes.isEmpty { emptyShelf } else { shelf }
            }
            // On the Group, not on the List: the empty branch has no List to
            // hang it from, and the read must happen in both.
            .task {
                volumes = VolumeStore.all()
                shelfRead = true
                // After the shelf itself is on screen. The names and dates are
                // already drawn; each page count lands into a row that is
                // already laid out, the way Diagnostics' integrity numbers do.
                await readPageCounts()
            }
        }
        .navigationTitle("Volumes")
        .sheet(item: $binderSession) { _ in
            BindVolumeSheet { reloadShelf() }
        }
        .confirmationDialog("Remove this volume", isPresented: .init(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove this volume", role: .destructive) {
                if let volume = removing { VolumeStore.remove(volume) }
                removing = nil
                reloadShelf()
            }
        } message: {
            // A volume is a rendering, not the record.
            Text("The writing itself stays in your journal.")
        }
    }

    /// The shelf before anything is on it.
    ///
    /// It used to be one row reading "Bind a volume" and then nothing, which
    /// tells a first-time reader the name of a control and not one thing about
    /// what a volume IS. Rajan, on this exact screen: *"will help user know
    /// what it about more if its there first time liek its beautifully done in
    /// sitaution."* So this is the Situations shape, not a new one: the glyph,
    /// one sentence saying what the thing is FOR, and the action that already
    /// existed promoted to the primary button. Nothing invented to fill space.
    private var emptyShelf: some View {
        CobuxEmptyStateView(
            icon: "books.vertical",
            title: "A season of your journal",
            // True to what the binder actually makes (docs/bound-volumes.md):
            // a range of months of his own passages, set in the serif face
            // into a PDF that stays on this shelf. Deliberately not "export"
            // or "back up" -- a volume is a rendering, not the record, which
            // is the same fact the removal dialog states.
            message: "Bind a stretch of months into a private book — your own passages set in print, kept on this shelf, so a season reads start to finish instead of scrolling the feed backwards."
        ) {
            CobuxEmptyStateButton("Bind a volume", systemImage: "books.vertical") {
                binderSession = BinderSession()
            }
        }
    }

    /// The shelf with something on it: the binder first, then what he's bound.
    private var shelf: some View {
        List {
            Section {
                Button { binderSession = BinderSession() } label: {
                    Label("Bind a volume", systemImage: "books.vertical")
                }
            }
            if !volumes.isEmpty {
                Section {
                    ForEach(volumes) { volume in
                        NavigationLink(destination: VolumePDFView(volume: volume)) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(volume.name)
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)
                                Text(Self.subtitle(for: volume, pages: pageCounts[volume.id]))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) { removing = volume } label: {
                                Label("Remove this volume", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    /// `static let`, not one built per row: a `DateFormatter` is expensive to
    /// construct, and this one was being constructed once per volume per body
    /// evaluation. `HeldView` already holds its formatter this way.
    private static let boundDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        return formatter
    }()

    /// The bound date always; the page count only once it is known. Never a
    /// guessed number -- a volume with no count yet simply says when it was
    /// bound, which is the whole subtitle a volume whose PDF cannot be opened
    /// has always shown.
    private static func subtitle(for volume: VolumeStore.BoundVolume, pages: Int?) -> String {
        let date = "Bound \(boundDateFormatter.string(from: volume.boundDate))"
        guard let pages else { return date }
        return "\(date) · \(pages) page\(pages == 1 ? "" : "s")"
    }

    /// Opens each volume once, off the main actor, and publishes the counts
    /// together. `PDFDocument(url:)` parses the file, so this is real IO -- it
    /// belongs to no actor, so `Task.detached` is the right tool, exactly as
    /// `DiagnosticsView` uses it for the log file.
    private func readPageCounts() async {
        let urls = volumes.map(\.url)
        guard !urls.isEmpty else { return }
        pageCounts = await Task.detached(priority: .utility) { () -> [URL: Int] in
            var counts: [URL: Int] = [:]
            for url in urls {
                guard let document = PDFDocument(url: url) else { continue }
                counts[url] = document.pageCount
            }
            return counts
        }.value
    }

    /// Re-reads the shelf and the counts together, so a volume bound or removed
    /// never leaves a stale page count behind under a new name.
    private func reloadShelf() {
        volumes = VolumeStore.all()
        Task { await readPageCounts() }
    }
}

/// A single "bind a volume" request -- exists so the binder is driven by
/// `.sheet(item:)`, for exactly `ComposeSession`'s reason.
private struct BinderSession: Identifiable {
    let id = UUID()
}

/// In-app reader for a bound volume, with the one exit: his share tap.
struct VolumePDFView: View {
    let volume: VolumeStore.BoundVolume

    var body: some View {
        // Self-wrapped. This is pushed from inside the shelf's gate, and a
        // pushed surface inherits nothing: the lock re-engages on every
        // backgrounding, the shelf underneath swaps to its gate, and this
        // reader -- a season of his journal, in full -- stayed on top of the
        // stack, readable, with no Face ID. The title and the share tap live
        // INSIDE the gate so the bar shows neither while locked.
        JournalLocked {
            PDFKitView(url: volume.url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(volume.name)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: volume.url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        view.backgroundColor = .systemBackground
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}

/// The binder: two month pickers and one act.
struct BindVolumeSheet: View {
    var onBound: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var from: Date
    @State private var through = Date.now
    @State private var binding = false
    @State private var cameUpShort = false

    init(onBound: @escaping () -> Void) {
        self.onBound = onBound
        // Default: the last three calendar months including this one.
        _from = State(initialValue: Calendar.current.date(
            byAdding: .month, value: -2, to: .now) ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $from, displayedComponents: .date)
                DatePicker("Through", selection: $through, displayedComponents: .date)
                Section {
                    Button {
                        bind()
                    } label: {
                        if binding {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Binding…")
                            }
                        } else {
                            Text("Bind")
                        }
                    }
                    .disabled(binding)
                }
                if cameUpShort {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Not enough here yet")
                                .font(.headline)
                            Text("This stretch doesn't have enough writing to fill a volume. Try a longer season.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Bind a Volume")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func bind() {
        binding = true
        cameUpShort = false
        let calendar = Calendar.current
        let fromComponents = calendar.dateComponents([.year, .month], from: from)
        let throughComponents = calendar.dateComponents([.year, .month], from: through)
        // An inverted range names no season; the same "not enough" answer the
        // empty selection gave it before.
        guard let range = VolumeBinder.range(from: fromComponents, through: throughComponents) else {
            binding = false
            cameUpShort = true
            return
        }

        // Nothing SwiftData-shaped crosses this line. Every read -- the
        // season's entries, the library sample -- happens on the binder's own
        // `@ModelActor` (SeedRunner's shape), and everything heavy runs
        // detached: selection, pairing, pagination, and the PDF draw itself.
        // The tap's only main-actor work is reading these four values.
        let container = modelContext.container
        // NEVER traverse a book relationship while the seed/upgrade merge is
        // in flight -- the same guard every pairing surface carries. No
        // pairing is a volume without resonant lines, which is its ordinary
        // state anyway.
        let pairingAllowed = !SeedingStatus.shared.isSeeding
        let suppressed = EbbSuppressionStore.suppressedIDs()
        let volumeNumber = VolumeStore.nextNumber

        Task.detached(priority: .userInitiated) {
            let inputs = VolumeBinderInputs(modelContainer: container)
            let snapshots = await inputs.entries(in: range)
            var passages = VolumeBinder.select(entries: snapshots,
                                               from: fromComponents,
                                               through: throughComponents,
                                               suppressed: suppressed)
            guard passages.count >= VolumeBinder.minimumPassages else {
                await MainActor.run { binding = false; cameUpShort = true }
                return
            }
            // Resonant lines: stamps stripped before embedding (the ebb-doc
            // veto holds here verbatim), fresh vectors on both sides, and the
            // pair finder's relative bar decides. Most passages ride alone --
            // the library annotates; it never talks over him.
            let librarySample = pairingAllowed ? await inputs.librarySample() : []
            if !librarySample.isEmpty {
                let candidates: [(snapshot: JournalPairFinder.HighlightSnapshot, vector: [Float])] =
                    librarySample.compactMap { snapshot in
                        EmbeddingService.embed(snapshot.text).map { (snapshot, $0) }
                    }
                if candidates.count >= 8 {
                    passages = passages.map { passage in
                        var passage = passage
                        if let vector = EmbeddingService.embed(passage.text),
                           let pairing = JournalPairFinder.bestPairing(
                               passage: passage.text, passageVector: vector,
                               candidates: candidates,
                               similarity: EmbeddingService.cosineSimilarity) {
                            passage.pairedLine = pairing.highlightText
                            passage.pairedBookTitle = pairing.bookTitle
                        }
                        return passage
                    }
                }
            }
            let title = VolumeBinder.title(from: fromComponents, through: throughComponents)
            // Measured, not estimated: the renderer asks its text engine what
            // each passage needs and the binder breaks pages on that number.
            let pages = VolumeRenderer.paginate(passages: passages)
            let paired = passages.filter { $0.pairedLine != nil }.count
            let pdf = VolumeRenderer.render(
                passages: passages, pages: pages,
                metadata: .init(title: title, volumeNumber: volumeNumber,
                                boundDate: .now, passageCount: passages.count,
                                pairedLineCount: paired))
            _ = try? VolumeStore.save(pdf: pdf, title: title, volumeNumber: volumeNumber)
            await MainActor.run {
                binding = false
                onBound()
                dismiss()
            }
        }
    }
}

/// The binder's reads, on their own executor.
///
/// `SeedRunner`'s shape: a `@ModelActor` owns a context confined to it, so
/// nothing here touches the main context or the main thread -- the Build-5
/// crash class is impossible by construction, not by discipline. The sheet
/// used to `@Query` every highlight, and the shelf every entry, then filter,
/// sort and stride all of it on the main actor inside the Bind tap.
@ModelActor
actor VolumeBinderInputs {
    /// Every entry whose date falls inside the season, as snapshots. Bounded
    /// by the predicate rather than the table: an entry's date is
    /// `modifiedDate` when it is known and `dateImported` when it is not,
    /// the same rule every surface reads, and `??` is the one optional form
    /// SwiftData translates.
    func entries(in range: Range<Date>) -> [VolumeBinder.EntrySnapshot] {
        let start = range.lowerBound
        let end = range.upperBound
        let descriptor = FetchDescriptor<PersonalWritingEntry>(
            predicate: #Predicate<PersonalWritingEntry> {
                ($0.modifiedDate ?? $0.dateImported) >= start
                    && ($0.modifiedDate ?? $0.dateImported) < end
            },
            sortBy: [SortDescriptor(\PersonalWritingEntry.dateImported)])
        return ((try? modelContext.fetch(descriptor)) ?? []).map {
            VolumeBinder.EntrySnapshot(id: $0.id,
                                       date: $0.modifiedDate ?? $0.dateImported,
                                       dateIsCertain: $0.modifiedDate != nil,
                                       text: $0.text)
        }
    }

    /// The pairing pool: `sampleLibrary`'s rule -- standalone lines, id
    /// order, strided to the sample size -- over a bounded prefix instead of
    /// the whole table. The store sorts by id, and ids are random, so the
    /// prefix is a deterministic pseudo-random subset: re-binding the same
    /// season yields the same book. No day seed, on purpose.
    func librarySample(poolLimit: Int = 1500,
                       sampleSize: Int = 150) -> [JournalPairFinder.HighlightSnapshot] {
        var descriptor = FetchDescriptor<Highlight>(sortBy: [SortDescriptor(\Highlight.id)])
        descriptor.fetchLimit = poolLimit
        // The snapshot is `id`, `text` and the book's title/tradition; the
        // 2 KB `embeddingData` on each of these 1,500 rows (~3 MB) was read
        // and discarded. Left out of the fetch; SwiftData faults it lazily
        // should anything on this actor ever ask for it.
        descriptor.propertiesToFetch = [\.id, \.text]
        descriptor.relationshipKeyPathsForPrefetching = [\.book]
        let standalone = ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { FlowQueueBuilder.readsStandalone($0.text) }
        guard !standalone.isEmpty else { return [] }
        let stride = max(1, standalone.count / sampleSize)
        var sampled: [JournalPairFinder.HighlightSnapshot] = []
        var index = 0
        while index < standalone.count, sampled.count < sampleSize {
            let highlight = standalone[index]
            if let book = highlight.book {
                sampled.append(.init(id: highlight.id, text: highlight.text,
                                     bookTitle: book.title, tradition: book.tradition))
            }
            index += stride
        }
        return sampled
    }
}
