import SwiftUI
import SwiftData

struct QuizHomeView: View {
    @Bindable var claudeService: ClaudeService
    @Binding var path: NavigationPath
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]
    @State private var dailyReviewNavigation: AttemptNavigationWrapper?

    /// The FSRS-backed cross-library queue (`QuizQuestion.dueDate`) — distinct
    /// from each book row's own `dueReviewCount`, which still reads the older
    /// per-highlight `HighlightMemory.nextReviewDate` and only ever covers one
    /// book at a time. Daily Review is the first entry point that actually
    /// spans the whole library.
    private var dueCount: Int { DailyReviewService.dueQuestions(in: books).count }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if dueCount > 0 {
                    Section {
                        Button {
                            startDailyReview()
                        } label: {
                            HStack {
                                Label("Daily Review", systemImage: "clock.arrow.circlepath")
                                    .fontWeight(.semibold)
                                Spacer()
                                Text("\(min(dueCount, DailyReviewService.defaultNewPerDay + DailyReviewService.defaultReviewsPerDay)) due")
                                    .foregroundStyle(.secondary)
                                    .contentTransition(.numericText())
                                    .animation(.easeOut(duration: 0.3), value: dueCount)
                            }
                        }
                    }
                }

                Section {
                    ForEach(books) { book in
                        NavigationLink(destination: QuizScopeBuilderView(book: book, claudeService: claudeService)) {
                            QuizBookRow(book: book)
                        }
                    }
                }

                Section {
                    NavigationLink(destination: QuizAnalyticsView()) {
                        Label("Analytics", systemImage: "chart.bar.fill")
                    }
                }
            }
            .navigationTitle("Quiz")
            .overlay {
                if books.isEmpty {
                    CobuxEmptyStateView(
                        icon: "questionmark.circle",
                        title: "No books yet",
                        message: "Add a book in Library to start quizzing yourself on it."
                    )
                }
            }
            .navigationDestination(item: $dailyReviewNavigation) { wrapper in
                QuizSessionView(attempt: wrapper.attempt, questions: wrapper.questions, onDone: { dailyReviewNavigation = nil })
            }
        }
    }

    private func startDailyReview() {
        let due = DailyReviewService.dueQuestions(in: books)
        let queue = DailyReviewService.budgetedQueue(from: due)
        guard !queue.isEmpty else { return }

        let attempt = QuizAttempt(book: nil, scopeDescription: "Daily Review", mode: .practice)
        modelContext.insert(attempt)
        try? modelContext.save()

        dailyReviewNavigation = AttemptNavigationWrapper(attempt: attempt, questions: queue)
    }
}

private struct QuizBookRow: View {
    let book: Book

    private var readyChapterCount: Int {
        book.chapters.filter { !QuizGenerationService.needsGeneration(chapter: $0, in: book) && !$0.quizQuestions.isEmpty }.count
    }

    private var dueReviewCount: Int {
        book.highlights.compactMap(\.memory).filter { $0.nextReviewDate <= .now }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            BookTitleText(title: book.title)
            HStack(spacing: 8) {
                if book.chapters.isEmpty {
                    Text("No chapters yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(readyChapterCount)/\(book.chapters.count) chapters ready to quiz")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.3), value: readyChapterCount)
                }
                if dueReviewCount > 0 {
                    Label("\(dueReviewCount) due", systemImage: "clock.arrow.circlepath")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.cobuxWarning.opacity(0.15))
                        .foregroundStyle(Color.cobuxWarning)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 2)
    }
}
