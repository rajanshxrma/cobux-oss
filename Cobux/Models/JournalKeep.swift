import Foundation
import SwiftData

/// A passage he chose to hold on to, and optionally a question he asked himself
/// about it.
///
/// This is the honest version of what he asked for. He wanted a surface that
/// says *"you wrote this principle — are you still following it?"*, and Fable's
/// ruling was that the app cannot ask that: to do so it must first decide a
/// passage IS a principle, a goal, a resolution. That is inference, which is the
/// exact vocabulary `Pick` and `EbbCard` were built to make unrepresentable. And
/// a template question applied blind is worse than none — "where does this stand
/// now?" printed under a passage about someone he lost is a knife.
///
/// So the app never decides, and never asks. **He marks the passage, and he
/// writes the question.** The app's whole job is to carry both forward through
/// time and hand them back, dated, unaltered.
///
/// The re-surfacing ladder is **elapsed time only** — 7, 21, 60, 180 days — and
/// deliberately not FSRS. `HighlightMemory.recordAnswer` grades; a Keep must
/// never be graded (there is no correct, no missed, no lapse), so it cannot ride
/// the spaced-repetition machinery even though the shape looks similar. The
/// return of his own words IS the question. Nothing else asks it.
///
/// This is his own stated reason for the app, built literally: *"one of the
/// problems in the life of homo sapiens is that our memories — we forget.
/// Sometimes we planned doing something but we forget, and we repeat our
/// mistakes."*
@Model
final class JournalKeep {
    var id: UUID = UUID()
    /// The entry this came from. A reference, never a copy that could drift —
    /// and never a deletion, since entries are permanent.
    var entryID: UUID = UUID()
    /// His words, exactly as they were when he kept them.
    var passage: String = ""
    /// When he wrote it, not when he kept it.
    var sourceDate: Date = Date()
    var createdDate: Date = Date()
    /// A question he wrote to his future self. Optional, and never generated.
    var question: String?
    /// Last time this was shown, so the ladder can advance. Nil until first shown.
    var lastSurfacedDate: Date?
    /// When he set this keep down. Releasing marks rather than deletes: the
    /// passage and the entry were never at risk either way, but the record that
    /// he once chose to hold this is itself his, and this app does not quietly
    /// destroy his record of himself to implement a "stop showing me" button.
    /// Everywhere else it grows only; a keep is not the exception.
    var releasedDate: Date?
    /// How many rungs it has climbed. Advances on TIME, never on performance.
    var rung: Int = 0

    init(entryID: UUID, passage: String, sourceDate: Date, question: String? = nil) {
        self.id = UUID()
        self.entryID = entryID
        self.passage = passage
        self.sourceDate = sourceDate
        self.createdDate = .now
        self.question = question
        self.rung = 0
    }

    /// Days between rungs. Widening, so something kept long ago returns rarely
    /// rather than never — and the last rung repeats forever rather than
    /// retiring, because a thing worth keeping does not expire.
    static let ladder: [Int] = [7, 21, 60, 180]

    /// Whether this is due to come back.
    ///
    /// Pure time. No streak, no score, nothing that could read as being behind
    /// on it — he deleted a guilt notification once, and this must never become
    /// a quieter version of the same thing.
    func isDue(now: Date = .now) -> Bool {
        guard releasedDate == nil else { return false }
        let interval = Self.ladder[min(rung, Self.ladder.count - 1)]
        let since = lastSurfacedDate ?? createdDate
        guard let due = Calendar.current.date(byAdding: .day, value: interval, to: since)
        else { return false }
        return now >= due
    }

    /// A calendar day boundary is not a reading. A sighting at 23:59 and
    /// another at 00:01 are two different `isSameDay` results but one actual
    /// look at the passage — without this, that pair would carry a keep from
    /// the 7-day rung to the 60-day one off eleven minutes. Pure elapsed
    /// time, same as the ladder itself; nothing here reads how long he spent
    /// or whether he engaged, only that a real gap passed.
    static let minimumElapsedBetweenRungs: TimeInterval = 12 * 60 * 60

    /// Recorded when it is actually shown, not when it is dealt.
    ///
    /// Idempotent within a day, and that is a correctness property rather than
    /// a nicety: the card lives in a `List`, so scrolling its row off screen
    /// and back re-inserts the view. Advancing per insertion meant two idle
    /// scroll-bys could carry a keep from the 7-day rung to the 60-day one
    /// without him having read it twice. The ladder is supposed to measure
    /// elapsed time, so a second sighting on the same day is not a rung —
    /// and, since a calendar day is a wall-clock fiction, neither is a second
    /// sighting less than `minimumElapsedBetweenRungs` after the first, even
    /// when the two land on different calendar days.
    func markSurfaced(now: Date = .now) {
        if let last = lastSurfacedDate {
            let sameCalendarDay = Calendar.current.isDate(last, inSameDayAs: now)
            let elapsed = now.timeIntervalSince(last)
            if sameCalendarDay || elapsed < Self.minimumElapsedBetweenRungs {
                return
            }
        }
        lastSurfacedDate = now
        rung = min(rung + 1, Self.ladder.count - 1)
    }
}
