import Foundation

/// Why this person opened Cobux — chosen in onboarding, changeable in
/// Settings. Copy-tuning only: every persona has the full feature set, and
/// `exam` reproduces the app's pre-persona behavior exactly (Utkarsh's flows
/// are a strict subset, never a fork). Plain Foundation enum: `Cobux/Models`
/// is compiled into the extension targets too, so no framework imports here.
enum UserPersona: String, CaseIterable, Identifiable {
    /// Studying for a specific exam — quiz-forward, countdown-aware framing.
    case exam
    /// Wants to actually remember what they read — review-forward framing.
    case retention
    /// Building a daily reading/wisdom habit — streak- and Flow-forward framing.
    case habit

    var id: String { rawValue }

    static let storageKey = "userPersona"

    var title: String {
        switch self {
        case .exam: "Study for an exam"
        case .retention: "Remember what I read"
        case .habit: "Build a daily wisdom habit"
        }
    }

    var subtitle: String {
        switch self {
        case .exam: "Question banks, countdown pacing, and spaced review tuned to a date."
        case .retention: "Spaced repetition that quietly resurfaces what matters."
        case .habit: "A streak, a daily flow of quotes, and gentle nudges."
        }
    }

    var icon: String {
        switch self {
        case .exam: "graduationcap.fill"
        case .retention: "brain.head.profile"
        case .habit: "flame.fill"
        }
    }
}
