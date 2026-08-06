import SwiftData
import Foundation

/// What kind of content a book's chapters/highlights actually are, replacing
/// the old `highlightCount > 60` proxy that broke once every book (not just
/// the two medical textbooks) grew past that count under deeper authoring.
/// This is stored as a raw string on `Book` (see `contentProfileRaw`) rather
/// than relying on SwiftData's native enum storage, a known-safe pattern.
enum BookContentProfile: String, Codable, CaseIterable {
    /// Thesis-per-chapter self-help/psychology books: Peterson x2, Attached,
    /// The Value of Others, Dopamine Nation, The Mountain Is You. Full Tier
    /// A/B highlight mix, on-device cloze generation enabled, practice-style
    /// quizzes, content small enough to full-dump into the chat prompt.
    case propositional
    /// The two large academic reference texts (Robbins, Microbiology).
    /// Same full cloze generation as `propositional`, but retrieval-gated
    /// context (too large to full-dump) and exam-simulation quiz tone.
    case academicReference
    /// Dialogue/lecture-format books whose highlights capture only the
    /// *resolved* position, not every voice in the dialogue (Courage to Be
    /// Disliked, The Meaning of It All). Cloze generation enabled same as
    /// `propositional`.
    case doctrine
    /// Memoir/anecdotal prose with no extractable propositional claims
    /// (Surely You're Joking Mr. Feynman, Greenlights). Verbatim quotes
    /// only — cloze generation is disabled, nothing here should ever
    /// surface in a quiz.
    case narrative
    /// Dense original philosophical/academic argument (The Denial of
    /// Death). Verbatim quotes with a gloss; cloze generation disabled by
    /// default given the fabrication risk in paraphrasing the author's own
    /// claims into testable facts.
    case densePhilosophy

    /// Whether this profile's Tier A highlights should feed on-device cloze
    /// generation (`ClozeService.generateIfNeeded`) at all.
    var suppliesClozeCards: Bool {
        switch self {
        case .propositional, .academicReference, .doctrine: true
        case .narrative, .densePhilosophy: false
        }
    }

    /// Whether this book is large enough that chat context should be
    /// retrieval-gated (relevant snippets only) instead of dumped in full.
    var requiresRetrievalGating: Bool {
        self == .academicReference
    }

    /// Whether quiz sessions for this book default to exam-simulation tone
    /// (timed, high-stakes framing) instead of relaxed practice framing.
    var isExamStyleQuiz: Bool {
        self == .academicReference
    }
}

@Model
final class Book {
    var id: UUID = UUID()
    var title: String
    var author: String
    var coverColorHex: String
    var coverImageURL: String?
    var dateAdded: Date
    var dateFinished: Date?
    /// Exam Countdown mode — when set, nothing is ever scheduled past this
    /// date (`CobuxCore.ExamCountdown.maxIntervalDays`) and the FSRS
    /// retention target rises as it approaches, compressing review intervals
    /// automatically. `nil` = no exam set, scheduling behaves as normal.
    var examDate: Date?

    /// Content-authoring version this book's seed content was last upgraded
    /// to. Every seed function used to `return` early once a `Book` row with
    /// its title already existed — meaning a deeper rewrite of that seed
    /// function would never reach a device where the book was already
    /// seeded (silently, since the guard just returns). This field lets a
    /// content patch upgrade an already-seeded book's chapters/highlights in
    /// place instead of re-seeding (and duplicating) what's already there.
    var seedContentVersion: Int = 1

    /// Backing storage for `contentProfile` — see `BookContentProfile` for
    /// why this replaced the old `highlightCount > 60` size proxy. Stored as
    /// a raw string rather than the enum directly (a known-safe SwiftData
    /// pattern), defaulting every pre-existing row to `.propositional`;
    /// `SeedDataRobbins`/`SeedDataMicrobiology` backfill their two rows to
    /// `.academicReference` on next launch.
    var contentProfileRaw: String = BookContentProfile.propositional.rawValue

    var contentProfile: BookContentProfile {
        get { BookContentProfile(rawValue: contentProfileRaw) ?? .propositional }
        set { contentProfileRaw = newValue.rawValue }
    }

    @Relationship(deleteRule: .cascade, inverse: \Highlight.book)
    var highlights: [Highlight] = []

    @Relationship(deleteRule: .cascade, inverse: \Chapter.book)
    var chapters: [Chapter] = []

    @Relationship(deleteRule: .cascade, inverse: \Figure.book)
    var figures: [Figure] = []

    init(title: String, author: String, coverColorHex: String = "#6366F1", coverImageURL: String? = nil, dateAdded: Date = .now, dateFinished: Date? = nil, contentProfile: BookContentProfile = .propositional) {
        self.id = UUID()
        self.title = title
        self.author = author
        self.coverColorHex = coverColorHex
        self.coverImageURL = coverImageURL
        self.dateAdded = dateAdded
        self.dateFinished = dateFinished
        self.contentProfileRaw = contentProfile.rawValue
    }

    var highlightCount: Int { highlights.count }
    var chapterCount: Int { chapters.count }
    var completedChapterCount: Int { chapters.filter(\.isCompleted).count }
    /// nil when there are no chapters at all — lets the UI distinguish
    /// "no progress to show" from "0% complete."
    var chapterProgress: Double? {
        guard !chapters.isEmpty else { return nil }
        return Double(completedChapterCount) / Double(chapters.count)
    }

    /// Prefers the real `Highlight.chapterRef` relationship (stable across a chapter
    /// rename); falls back to the old free-text `Highlight.chapter` == `Chapter.title`
    /// match only for highlights that haven't been backfilled onto the relationship
    /// yet. `persistentModelID` comparison, not `===`, so this works correctly across
    /// ModelContext instances (e.g. a chapter fetched by a `@Query` in one view
    /// compared against a highlight loaded via a different context).
    /// Sorted by `dateAdded` -- SwiftData to-many relationship arrays have no
    /// guaranteed order, but this result's index is exactly what
    /// `QuizGenerationService` sends Claude as `sourceHighlightIndexes` (both
    /// when building the generation prompt and, potentially much later for a
    /// backgrounded batch, when applying the result). Without a stable sort
    /// here, the same call could return highlights in a different order
    /// between those two points and silently attach a generated question to
    /// the wrong highlight -- a real correctness bug, not just a flaky test
    /// (caught by `QuizGenerationServiceTests` returning a different highlight
    /// than expected once the underlying relationship's storage order shifted
    /// for an unrelated reason).
    func highlights(in chapter: Chapter) -> [Highlight] {
        highlights.filter { highlight in
            if let chapterRef = highlight.chapterRef {
                return chapterRef.persistentModelID == chapter.persistentModelID
            }
            return highlight.chapter == chapter.title
        }.sorted { $0.dateAdded < $1.dateAdded }
    }
}
