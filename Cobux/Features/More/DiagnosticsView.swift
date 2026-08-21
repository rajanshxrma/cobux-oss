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

    /// Never introduced into review at all -- would have caught the real shipped bug where
    /// every freshly generated question (paid and free cloze alike) had `dueDate == nil` and
    /// was therefore permanently invisible to Daily Review. Should trend to 0 shortly after
    /// any chapter is quizzed; a number that stays high and grows is exactly that bug back.
    private var notIntroducedCount: Int { quizQuestions.filter { $0.dueDate == nil }.count }
    private var dueNowCount: Int { quizQuestions.filter { !$0.isSuspended && ($0.dueDate.map { $0 <= .now } ?? false) }.count }
    private var scheduledFutureCount: Int { quizQuestions.filter { !$0.isSuspended && ($0.dueDate.map { $0 > .now } ?? false) }.count }
    private var newCardCount: Int { quizQuestions.filter { $0.fsrsReps == 0 && $0.dueDate != nil }.count }
    private var suspendedCount: Int { quizQuestions.filter(\.isSuspended).count }

    /// Mean days from now to each scheduled question's next review -- the "next-interval
    /// predictions" the FSRS risk table promised Diagnostics would expose, so a scheduler
    /// gone subtly wrong (way too short/long intervals) is a number visible here, not
    /// something that only shows up as "the app feels off" weeks later.
    private var averageDaysUntilNextReview: Double? {
        let futureDueDates = quizQuestions.compactMap { question -> Double? in
            guard !question.isSuspended, let due = question.dueDate, due > .now else { return nil }
            return due.timeIntervalSince(.now) / 86400
        }
        guard !futureDueDates.isEmpty else { return nil }
        return futureDueDates.reduce(0, +) / Double(futureDueDates.count)
    }

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

            Section("FSRS Scheduling") {
                diagnosticRow("Never introduced (dueDate nil)", "\(notIntroducedCount)", isHealthy: notIntroducedCount == 0)
                diagnosticRow("New cards", "\(newCardCount)", isHealthy: true)
                diagnosticRow("Due now", "\(dueNowCount)", isHealthy: true)
                diagnosticRow("Scheduled ahead", "\(scheduledFutureCount)", isHealthy: true)
                diagnosticRow("Suspended", "\(suspendedCount)", isHealthy: true)
                if let averageDaysUntilNextReview {
                    diagnosticRow("Avg. days to next review", String(format: "%.1f", averageDaysUntilNextReview), isHealthy: true)
                }
            }

            Section("Spend") {
                diagnosticRow("Estimated this month", String(format: "$%.2f", UsageTracker.currentMonthEstimate()), isHealthy: true)
            }

            Section("Build") {
                diagnosticRow("Version", "\(appVersion) (\(appBuild))", isHealthy: true)
                diagnosticRow("TestFlight renews in", "\(BuildInfo.daysUntilExpiry) day(s)", isHealthy: BuildInfo.daysUntilExpiry > 14)
            }

            // Always present, never gated on a crash existing first -- unlike
            // `CrashReportCollector`'s reports (which only ever appear after
            // something has already gone wrong), this log exists precisely so
            // there's real evidence to share BEFORE a bug reaches the point of
            // crashing, e.g. a seed that hangs instead of finishing.
            Section("Diagnostic Log") {
                let entries = DiagnosticLog.recentEntries()
                diagnosticRow("Entries", "\(entries.count)", isHealthy: true)
                if !entries.isEmpty {
                    ShareLink(item: DiagnosticLog.fileURL) {
                        Label("Share Diagnostic Log", systemImage: "doc.text.magnifyingglass")
                    }
                }
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
