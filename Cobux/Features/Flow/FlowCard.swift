import Foundation

/// One full-screen card in the Flow feed. The mix of types IS the feature:
/// like any good For-You feed, not knowing whether the next swipe brings a
/// quote, a lesson, or a quick self-test is what makes the next swipe
/// interesting — except everything here comes from the user's own library,
/// on-device, with zero API cost.
enum FlowCard: Identifiable {
    case highlight(Highlight)
    case keyLesson(Chapter, lessonIndex: Int)
    case clozeTeaser(QuizQuestion)
    case weakTopic(topic: String, lapseCount: Int)
    /// First card of every session: where today stands (streak, ripe cards)
    /// so the very first swipe has a mission. Framing is a status report,
    /// never a stakes threat — the panel's critic killed the loss-aversion
    /// variant and that ruling stands.
    case dailyOpener(streak: Int, dueCount: Int)
    /// Lands every ~12 cards: the Duolingo set-complete beat. Content is
    /// rendered live from `FlowSessionStats` so the numbers are honest.
    case sessionRecap(setNumber: Int, ripeningTomorrow: Int, nextBook: String?)
    /// The rare gold card: two highlights from two DIFFERENT books that are
    /// saying the same thing, found by comparing the embeddings the library
    /// already stores. The "this app actually knows my books" moment.
    case resonance(Highlight, Highlight)

    var id: String {
        switch self {
        case .highlight(let highlight): "highlight-\(highlight.id.uuidString)"
        case .keyLesson(let chapter, let lessonIndex): "lesson-\(chapter.persistentModelID.hashValue)-\(lessonIndex)"
        case .clozeTeaser(let question): "cloze-\(question.id.uuidString)"
        case .weakTopic(let topic, _): "weak-\(topic)"
        case .dailyOpener: "opener"
        case .sessionRecap(let setNumber, _, _): "recap-\(setNumber)"
        case .resonance(let a, let b): "resonance-\(a.id.uuidString)-\(b.id.uuidString)"
        }
    }

    /// Drives the shared atmosphere layer in `FlowView` — the background
    /// melts toward the visible card's accent as it settles.
    var accentHex: String {
        switch self {
        case .highlight(let highlight): highlight.book?.coverColorHex ?? "#6366F1"
        case .keyLesson(let chapter, _): chapter.book?.coverColorHex ?? "#6366F1"
        case .clozeTeaser(let question): question.book?.coverColorHex ?? "#6366F1"
        case .weakTopic: "#F97316"
        case .dailyOpener: "#F59E0B"
        case .sessionRecap: "#10B981"
        case .resonance: "#EAB308"
        }
    }
}
