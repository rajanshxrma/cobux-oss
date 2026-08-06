import SwiftUI
import SwiftData

/// DEBUG-only visibility into the exact classes of invisible corruption this app has
/// actually had: the `Highlight.chapter` free-text join silently going stale, duplicate
/// IDs collapsing SwiftUI's diffing, embeddings not finishing their backfill, and so on.
/// The point is turning "something is subtly wrong" into a number Rajan can see without
/// attaching a debugger — part of the answer to "I shouldn't have to be the bug-finder."
struct DiagnosticsView: View {
    @Query private var books: [Book]
    @Query private var highlights: [Highlight]
    @Query private var chatMessages: [ChatMessage]
    @Query private var highlightMemories: [HighlightMemory]
    @Query private var quizQuestions: [QuizQuestion]
    @Query private var themes: [Theme]
    @Query private var figures: [Figure]

    private var embeddedCount: Int { highlights.filter { $0.embeddingData != nil }.count }

    /// Mirrors the exact lookup `Book.highlights(in:)` performs -- a highlight resolved
    /// by neither `chapterRef` nor the free-text `chapter` string is invisible to that
    /// lookup (and therefore to Quiz, which scopes by chapter) with no error raised
    /// anywhere. Only books that actually have chapters are checked, so a book still
    /// being authored without chapters yet doesn't falsely show every highlight as orphaned.
    private var orphanedHighlights: [(highlight: Highlight, bookTitle: String)] {
        highlights.compactMap { highlight in
            guard let book = highlight.book, !book.chapters.isEmpty else { return nil }
            if highlight.chapterRef != nil { return nil }
            guard let chapterName = highlight.chapter else { return (highlight, book.title) }
            let matches = book.chapters.contains { $0.title == chapterName }
            return matches ? nil : (highlight, book.title)
        }
    }

    /// How many highlights (of those in a chaptered book) still rely on the free-text
    /// fallback rather than the real `chapterRef` relationship -- should trend to 0 as
    /// the launch-time backfill runs across installs.
    private var chapterRefBackfillProgress: (resolved: Int, total: Int) {
        let inChapteredBooks = highlights.filter { ($0.book?.chapters.isEmpty ?? true) == false }
        return (inChapteredBooks.filter { $0.chapterRef != nil }.count, inChapteredBooks.count)
    }

    private var duplicateBookIDCount: Int {
        let ids = books.map(\.id)
        return ids.count - Set(ids).count
    }

    private var duplicateHighlightIDCount: Int {
        let ids = highlights.map(\.id)
        return ids.count - Set(ids).count
    }

    private var duplicateThemeIDCount: Int {
        let ids = themes.map(\.id)
        return ids.count - Set(ids).count
    }

    private var generalThreadCount: Int { chatMessages.filter { $0.bookID == nil }.count }
    private var bookScopedThreadCount: Int { chatMessages.filter { $0.bookID != nil }.count }

    var body: some View {
        List {
            Section("Embeddings") {
                diagnosticRow("Backfilled", "\(embeddedCount) / \(highlights.count)", isHealthy: embeddedCount == highlights.count)
            }

            Section("Chapter Join Integrity") {
                let progress = chapterRefBackfillProgress
                diagnosticRow("chapterRef backfilled", "\(progress.resolved) / \(progress.total)", isHealthy: progress.resolved == progress.total)
                diagnosticRow("Orphaned highlights", "\(orphanedHighlights.count)", isHealthy: orphanedHighlights.isEmpty)
                if !orphanedHighlights.isEmpty {
                    ForEach(Array(orphanedHighlights.prefix(10).enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.bookTitle).font(.caption).fontWeight(.semibold)
                            Text("\"\(entry.highlight.chapter ?? "")\" matches no chapter title")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if orphanedHighlights.count > 10 {
                        Text("+ \(orphanedHighlights.count - 10) more").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Duplicate IDs") {
                diagnosticRow("Book", "\(duplicateBookIDCount)", isHealthy: duplicateBookIDCount == 0)
                diagnosticRow("Highlight", "\(duplicateHighlightIDCount)", isHealthy: duplicateHighlightIDCount == 0)
                diagnosticRow("Theme", "\(duplicateThemeIDCount)", isHealthy: duplicateThemeIDCount == 0)
            }

            Section("Chat") {
                diagnosticRow("General thread", "\(generalThreadCount) messages", isHealthy: true)
                diagnosticRow("Book-scoped threads", "\(bookScopedThreadCount) messages", isHealthy: true)
            }

            Section("Quiz") {
                diagnosticRow("Questions generated", "\(quizQuestions.count)", isHealthy: true)
                diagnosticRow("Highlights with review state", "\(highlightMemories.count) / \(highlights.count)", isHealthy: true)
                diagnosticRow("Figures", "\(figures.count)", isHealthy: true)
            }

            Section("Spend") {
                diagnosticRow("Estimated this month", String(format: "$%.2f", UsageTracker.currentMonthEstimate()), isHealthy: true)
            }

            Section("Build") {
                diagnosticRow("Version", "\(appVersion) (\(appBuild))", isHealthy: true)
                diagnosticRow("TestFlight renews in", "\(BuildInfo.daysUntilExpiry) day(s)", isHealthy: BuildInfo.daysUntilExpiry > 14)
            }
        }
        .navigationTitle("Diagnostics")
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    @ViewBuilder
    private func diagnosticRow(_ label: String, _ value: String, isHealthy: Bool) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(isHealthy ? Color.secondary : Color.cobuxWarning)
                .fontWeight(isHealthy ? .regular : .semibold)
        }
    }
}
