import Foundation

/// One-time seed from the old 5-box Leitner system onto FSRS state, so
/// nobody's earned progress is lost when scheduling moves from per-highlight
/// (`HighlightMemory.box`) to per-card (`QuizQuestion`, since one highlight
/// can hold 4-6 independently testable facts and per-highlight scheduling was
/// a category error). Values are a deliberate approximation, not a precise
/// conversion — there is no exact mapping between a 5-box ladder and a
/// continuous memory-stability model — but they preserve the *ordering*
/// (higher box → higher starting stability/lower difficulty) so a
/// well-known fact doesn't get scheduled as if it were brand new.
public enum FSRSMigration {

    /// Seed (stability in days, difficulty on a 1-10 scale) per Leitner box.
    public static let seedTable: [Int: (stability: Double, difficulty: Double)] = [
        1: (1.0, 7.0),
        2: (2.5, 6.0),
        3: (6.0, 5.5),
        4: (14.0, 5.0),
        5: (34.0, 4.5)
    ]

    /// A `QuizQuestion` can draw from multiple source highlights, each with
    /// its own Leitner box — there is no clean 1:1 mapping. Averaging (rounded
    /// to the nearest box) is a fair middle ground: it doesn't over-credit a
    /// question just because ONE of its facts happened to be well-drilled,
    /// and doesn't under-credit it for sharing space with a newer fact either.
    public static func seedState(fromSourceHighlightBoxes boxes: [Int]) -> FSRSCardState {
        guard !boxes.isEmpty else { return .new }
        let averageBox = Int((Double(boxes.reduce(0, +)) / Double(boxes.count)).rounded())
        let clampedBox = min(max(averageBox, 1), 5)
        let seed = seedTable[clampedBox] ?? seedTable[1]!
        return FSRSCardState(stability: seed.stability, difficulty: seed.difficulty, reps: 1, lapses: 0)
    }
}
