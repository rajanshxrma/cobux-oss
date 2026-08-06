import Foundation

/// FSRS-6 spaced-repetition scheduler — the Anki default since 2024, published and
/// externally validated. Chosen over the app's original 5-box Leitner (fixed 30-day
/// ceiling, no ease factor, full reset to box 1 on any miss) and over SM-2 (the
/// well-documented "ease hell" failure mode) because it models memory directly rather
/// than stepping through fixed intervals, and because `desiredRetention` gives Exam
/// Countdown mode a real dial instead of an invented heuristic.
///
/// Pure value types, no SwiftData/SwiftUI import — runs under `swift test` on the host,
/// no simulator required.
public enum FSRSGrade: Int, Codable, Sendable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4
}

public struct FSRSCardState: Codable, Sendable, Equatable {
    public var stability: Double
    public var difficulty: Double
    public var reps: Int
    public var lapses: Int

    public static let new = FSRSCardState(stability: 0, difficulty: 0, reps: 0, lapses: 0)

    public init(stability: Double, difficulty: Double, reps: Int, lapses: Int) {
        self.stability = stability
        self.difficulty = difficulty
        self.reps = reps
        self.lapses = lapses
    }

    public var isNew: Bool { reps == 0 }
}

public struct FSRSReviewResult: Sendable, Equatable {
    public let state: FSRSCardState
    public let intervalDays: Int
    public let dueDate: Date
}

public enum FSRS {

    // MARK: Constants

    static let decay: Double = -0.5
    static let factor: Double = 19.0 / 81.0

    /// FSRS-5 published default weights (19 parameters), used as-is per Fable's
    /// direction: they work well without per-user optimization, which this app has
    /// no data pipeline to perform anyway.
    static let w: [Double] = [
        0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046,
        1.54575, 0.1192, 1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315,
        2.9898, 0.51655, 0.6621
    ]

    // MARK: Retrievability / Interval — the memory model

    /// R(t, S) — probability of recall after `t` days at stability `S`.
    public static func retrievability(elapsedDays t: Double, stability S: Double) -> Double {
        guard S > 0 else { return 0 }
        return pow(1 + factor * t / S, decay)
    }

    /// I(r, S) — days until retrievability decays to `r` at stability `S`.
    /// Sanity identity: `interval(forRetention: 0.9, stability: S) == S`.
    public static func interval(forRetention r: Double, stability S: Double) -> Double {
        (S / factor) * (pow(r, 1 / decay) - 1)
    }

    // MARK: First review

    static func initialStability(grade: FSRSGrade) -> Double {
        w[grade.rawValue - 1]
    }

    static func initialDifficulty(grade: FSRSGrade) -> Double {
        clampDifficulty(w[4] - exp(w[5] * Double(grade.rawValue - 1)) + 1)
    }

    // MARK: Subsequent review

    static func nextDifficulty(previous D: Double, grade: FSRSGrade) -> Double {
        let deltaD = -w[6] * (Double(grade.rawValue) - 3)
        let dPrime = D + deltaD * (10 - D) / 9
        let d0Easy = initialDifficulty(grade: .easy)
        return clampDifficulty(w[7] * d0Easy + (1 - w[7]) * dPrime)
    }

    static func nextStabilityOnSuccess(S: Double, D: Double, R: Double, grade: FSRSGrade) -> Double {
        let hardPenalty = grade == .hard ? w[15] : 1.0
        let easyBonus = grade == .easy ? w[16] : 1.0
        return S * (1 + exp(w[8]) * (11 - D) * pow(S, -w[9])
            * (exp(w[10] * (1 - R)) - 1) * hardPenalty * easyBonus)
    }

    static func nextStabilityOnLapse(S: Double, D: Double, R: Double) -> Double {
        let sFail = w[11] * pow(D, -w[12]) * (pow(S + 1, w[13]) - 1) * exp(w[14] * (1 - R))
        return min(sFail, S)
    }

    static func nextStabilitySameDay(S: Double, grade: FSRSGrade) -> Double {
        S * exp(w[17] * (Double(grade.rawValue) - 3 + w[18]))
    }

    static func clampDifficulty(_ d: Double) -> Double { min(max(d, 1), 10) }

    // MARK: Fuzz — Anki-compatible, deterministic per card so it stays testable

    /// Spreads an interval by a card-seeded pseudo-random amount so cards introduced
    /// together don't all come due on exactly the same day forever.
    static func fuzzed(_ rawDays: Double, seed: UInt64) -> Double {
        guard rawDays >= 2.5 else { return rawDays }
        let spread: Double
        switch rawDays {
        case ..<7: spread = max(1, rawDays * 0.25)
        case 7..<20: spread = rawDays * 0.15
        default: spread = rawDays * 0.05
        }
        var rng = SplitMix64(seed: seed)
        let unit = Double(rng.next() >> 11) * (1.0 / 9_007_199_254_740_992.0) // [0, 1)
        let offset = (unit * 2 - 1) * spread
        return rawDays + offset
    }

    // MARK: Public entry point

    /// Schedule the next review for a card given its current state and the grade just given.
    /// - Parameters:
    ///   - state: current FSRS state (`.new` for a card never seen before).
    ///   - grade: the grade just recorded (Again/Hard/Good/Easy).
    ///   - elapsedDays: days since `lastReviewedAt` (0 for a same-day repeat, ignored for a new card).
    ///   - desiredRetention: the target retrievability at the next due date — Exam Countdown mode
    ///     raises this (0.90 → 0.95) as the exam approaches to compress intervals.
    ///   - maxIntervalDays: hard ceiling — Exam Countdown mode sets this to days-until-exam so
    ///     nothing is ever scheduled past it.
    ///   - now: injectable for deterministic tests.
    ///   - cardSeed: stable per-card identifier feeding the fuzz function.
    public static func schedule(
        state: FSRSCardState,
        grade: FSRSGrade,
        elapsedDays: Double,
        desiredRetention: Double = 0.9,
        minIntervalDays: Int = 1,
        maxIntervalDays: Int = 36500,
        now: Date = .now,
        cardSeed: UInt64
    ) -> FSRSReviewResult {
        let newState: FSRSCardState

        if state.isNew {
            newState = FSRSCardState(
                stability: initialStability(grade: grade),
                difficulty: initialDifficulty(grade: grade),
                reps: 1,
                lapses: 0
            )
        } else if elapsedDays < 1 {
            let s = nextStabilitySameDay(S: state.stability, grade: grade)
            newState = FSRSCardState(
                stability: s,
                difficulty: nextDifficulty(previous: state.difficulty, grade: grade),
                reps: state.reps + 1,
                lapses: state.lapses + (grade == .again ? 1 : 0)
            )
        } else {
            let R = retrievability(elapsedDays: elapsedDays, stability: state.stability)
            let d2 = nextDifficulty(previous: state.difficulty, grade: grade)
            let s2: Double
            if grade == .again {
                s2 = nextStabilityOnLapse(S: state.stability, D: state.difficulty, R: R)
            } else {
                s2 = nextStabilityOnSuccess(S: state.stability, D: state.difficulty, R: R, grade: grade)
            }
            newState = FSRSCardState(
                stability: s2,
                difficulty: d2,
                reps: state.reps + 1,
                lapses: state.lapses + (grade == .again ? 1 : 0)
            )
        }

        let raw = interval(forRetention: desiredRetention, stability: newState.stability)
        let fuzzedRaw = fuzzed(raw, seed: cardSeed)
        let clampedDays = min(max(Int(fuzzedRaw.rounded()), minIntervalDays), maxIntervalDays)
        let due = Calendar.current.date(byAdding: .day, value: clampedDays, to: now) ?? now

        return FSRSReviewResult(state: newState, intervalDays: clampedDays, dueDate: due)
    }
}

/// Small deterministic PRNG so fuzz is reproducible per card without pulling in a
/// third-party dependency for one call site.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
