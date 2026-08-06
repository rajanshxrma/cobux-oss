import SwiftUI
import SwiftData
import WidgetKit

struct BookDetailView: View {
    @Bindable var book: Book
    /// Set only when reached from a source that registered a matching
    /// `.matchedTransitionSource` (currently: Library's book grid) -- see
    /// `View+ZoomTransition.swift`. Left nil elsewhere so this view still
    /// works unchanged from search results and Wisdom's theme highlights.
    var heroTransitionNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTab = "Highlights"
    @State private var showingAddHighlight = false
    @State private var showingAddChapter = false
    @State private var showingClosingInterview = false
    @State private var chapterToggleFeedback = false

    /// Grows to fit a 2-line title (bounded by `BookTitleText`'s
    /// `lineLimit: 2` + `minimumScaleFactor`) plus the "Finished" badge when
    /// present, so the hero never has to overflow above its own image the
    /// way an unbounded-height title used to.
    private var heroHeight: CGFloat {
        book.dateFinished != nil ? 260 : 232
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Hero Header — bounded so a long title (e.g. "Robbins & Cotran
                // Pathologic Basis of Disease", which wraps to 2-3 lines at
                // .largeTitle) can never grow taller than the hero image and
                // overflow above it. lineLimit + minimumScaleFactor bound the
                // title's own height instead of letting it wrap unbounded;
                // the taller frame (was 200) and stronger, higher-reaching
                // scrim give a 2-line title real contrast against any cover.
                ZStack(alignment: .bottomLeading) {
                    heroBackground
                        .frame(height: heroHeight)
                        .clipped()

                    LinearGradient(
                        colors: [.black.opacity(0.85), .black.opacity(0.35), .clear],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                    .frame(height: heroHeight)

                    VStack(alignment: .leading, spacing: 8) {
                        if let dateFinished = book.dateFinished {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption2)
                                Text("Finished \(dateFinished.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.18))
                            .clipShape(Capsule())
                        }
                        BookTitleText(
                            title: book.title,
                            font: .largeTitle,
                            weight: .bold,
                            color: .white,
                            lineLimit: 2,
                            expandsWidth: true
                        )
                        .minimumScaleFactor(0.7)
                        Text(book.author)
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .padding()
                }

                // Stats card — floats slightly over the hero's bottom edge
                // instead of sitting as a flat, disconnected block directly
                // beneath it.
                VStack(spacing: 10) {
                    HStack(spacing: 24) {
                        StatView(value: "\(book.highlights.count)", label: "Highlights")
                        StatView(value: "\(book.chapters.count)", label: "Chapters")
                        StatView(value: book.dateAdded.formatted(date: .abbreviated, time: .omitted), label: "Added")
                    }

                    if let progress = book.chapterProgress {
                        VStack(spacing: 4) {
                            ProgressView(value: progress)
                                .tint(Color(hex: book.coverColorHex))
                            Text("\(book.completedChapterCount)/\(book.chapters.count) chapters read")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                .padding(.horizontal)
                .padding(.top, -24)
                .zIndex(1)

                // Segmented Picker
                Picker("View", selection: $selectedTab) {
                    Text("Highlights").tag("Highlights")
                    Text("Chapters").tag("Chapters")
                }
                .pickerStyle(.segmented)
                .padding()

                // Content
                if selectedTab == "Highlights" {
                    highlightsList
                } else {
                    chaptersList
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: { showingAddHighlight = true }) {
                        Label("Add Highlight", systemImage: "quote.opening")
                    }
                    Button(action: { showingAddChapter = true }) {
                        Label("Add Chapter", systemImage: "text.book.closed")
                    }
                    if book.dateFinished == nil {
                        Button(action: {
                            book.dateFinished = .now
                            showingClosingInterview = true
                        }) {
                            Label("Mark as Finished", systemImage: "checkmark.seal")
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.white)
                }
            }
        }
        .sheet(isPresented: $showingAddHighlight) {
            AddHighlightView(book: book)
        }
        .sheet(isPresented: $showingAddChapter) {
            AddChapterView(book: book)
        }
        .sheet(isPresented: $showingClosingInterview) {
            ClosingInterviewView(book: book)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .ignoresSafeArea(edges: .top)
        .sensoryFeedback(.selection, trigger: chapterToggleFeedback)
        .cobuxZoomTransitionDestination(id: book.id, in: heroTransitionNamespace)
    }

    @ViewBuilder
    private var heroBackground: some View {
        if let urlString = book.coverImageURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                default:
                    CoverGradientView(colorHex: book.coverColorHex)
                }
            }
        } else {
            CoverGradientView(colorHex: book.coverColorHex)
        }
    }

    private var highlightsList: some View {
        LazyVStack(spacing: 16) {
            if book.highlights.isEmpty {
                Text("No highlights yet.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ForEach(book.highlights.sorted(by: { $0.dateAdded > $1.dateAdded })) { highlight in
                    HStack(alignment: .top, spacing: 0) {
                        // A colored accent bar ties each card back to its
                        // book, and replaces the old literal quote marks
                        // (which doubled up whenever a pasted excerpt
                        // already carried its own quotation marks).
                        Rectangle()
                            .fill(Color(hex: book.coverColorHex))
                            .frame(width: 3)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(quotedText(for: highlight.text))
                                .font(.body)
                                // Italic reads fine for a short aphorism but
                                // hurts readability on long, dense clinical
                                // paragraphs — only apply it below a length
                                // where it still helps rather than hinders.
                                .italic(highlight.text.count < 150)

                            if let note = highlight.personalNote, !note.isEmpty {
                                Text("Note: \(note)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 12) {
                                if let chapter = highlight.chapter, !chapter.isEmpty {
                                    Label(chapter, systemImage: "text.book.closed")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                if let page = highlight.page {
                                    Label("p. \(page)", systemImage: "number")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }

                            if !highlight.tags.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack {
                                        ForEach(highlight.tags, id: \.self) { tag in
                                            TagBadge(tag: tag)
                                        }
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                    )
                    .padding(.horizontal)
                    .contextMenu {
                        Button(role: .destructive) {
                            deleteHighlight(highlight)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .padding(.bottom)
    }

    private var chaptersList: some View {
        LazyVStack(spacing: 16) {
            if book.chapters.isEmpty {
                Text("No chapters added yet.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ForEach(book.chapters.sorted(by: { ($0.chapterNumber ?? 0) < ($1.chapterNumber ?? 0) })) { chapter in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(chapter.summary)
                                .font(.body)
                                .foregroundStyle(.secondary)

                            if !chapter.keyLessons.isEmpty {
                                Text("Key Lessons:")
                                    .font(.headline)
                                    .padding(.top, 8)
                                ForEach(chapter.keyLessons, id: \.self) { lesson in
                                    HStack(alignment: .top) {
                                        Text("•")
                                        Text(lesson)
                                    }
                                    .font(.subheadline)
                                }
                            }
                        }
                        // The outer card already carries `.padding()` below —
                        // this used to ALSO pad the top, doubling the gap
                        // between the label row and the expanded content.
                        .padding(.top, 4)
                    } label: {
                        HStack {
                            Button {
                                chapter.isCompleted.toggle()
                                chapterToggleFeedback.toggle()
                            } label: {
                                Image(systemName: chapter.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(chapter.isCompleted ? Color(hex: book.coverColorHex) : .secondary)
                            }
                            .buttonStyle(.plain)

                            Text(chapter.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .strikethrough(chapter.isCompleted, color: .secondary)
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                    )
                    .padding(.horizontal)
                    .contextMenu {
                        Button(role: .destructive) {
                            deleteChapter(chapter)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .padding(.bottom)
    }

    /// Many pasted-in excerpts (especially from the medical textbooks)
    /// already carry their own leading/trailing quotation marks straight
    /// from the source PDF — wrapping those again produced a visible
    /// double-quote (`""..."."`). Only add quotes when the text doesn't
    /// already have its own.
    private func quotedText(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoteChars: Set<Character> = ["\"", "\u{201C}", "\u{201D}"]
        if let first = trimmed.first, let last = trimmed.last,
           quoteChars.contains(first), quoteChars.contains(last) {
            return trimmed
        }
        return "\"\(trimmed)\""
    }

    private func deleteHighlight(_ highlight: Highlight) {
        if let index = book.highlights.firstIndex(of: highlight) {
            book.highlights.remove(at: index)
            modelContext.delete(highlight)
            SpotlightIndexer.deindex(highlight)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func deleteChapter(_ chapter: Chapter) {
         if let index = book.chapters.firstIndex(of: chapter) {
            book.chapters.remove(at: index)
            modelContext.delete(chapter)
        }
    }
}

struct StatView: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline)
                .fontWeight(.bold)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
