import Foundation

/// What game a book's counsel is playing.
///
/// Rajan's library holds Marcus Aurelius and *The 48 Laws of Power*, *The Art
/// of Seduction* beside *As a Man Thinketh*. Every one of those is his choice.
/// The defect was that Flow presented all of them in the SAME register: a line
/// from Greene about disarming a rival and a line from Aurelius about not being
/// harmed by another's fault arrived looking identical, carrying identical
/// authority. That flattening made a human flag necessary before adding any
/// book with an edge — someone had to hold a difference the app could not.
///
/// The resolution, per Fable: the honest thing an app may say about a book is
/// **not whether it is good counsel, but what game the counsel is playing.**
/// That is taxonomy, not evaluation — a library labelling its shelves.
///
/// Every word below is chosen to be a tradition's OWN self-description. Greene
/// would accept "strategy"; Pirke Avot would accept "devotion"; Bacon would
/// accept "method". **If a tradition would not accept its label as fair, the
/// label is wrong.** There is deliberately no word here that ranks anything.
enum BookTradition: String, Codable, CaseIterable {
    /// Discipline of attention and response. Aurelius, Epictetus, Seneca.
    case stoicPractice = "stoic-practice"
    /// How to win, with clear eyes about what winning costs. Greene, Machiavelli.
    case strategy
    /// Written from inside a religious or ethical tradition. Pirke Avot, the Kural.
    case devotion
    /// How to think, test and know. Bacon, Dewey, Descartes, Clifford.
    case method
    /// Mind shapes circumstance. New Thought and the success literature.
    case belief
    /// Worldly practical advice from one person to another. Chesterfield, Plutarch.
    case counsel
    /// Modern psychology aimed at repair. Attached, Dopamine Nation.
    case therapy
    /// A life told by the person who lived it.
    case memoir
    /// Fiction, and anything whose truth arrives through story.
    case narrative

    /// Shown in the Flow kicker beside the book title, small-caps. Never a
    /// warning, never an adjective — the shelf's own name.
    var label: String {
        switch self {
        case .stoicPractice: "Stoic practice"
        case .strategy: "Strategy"
        case .devotion: "Devotion"
        case .method: "Method"
        case .belief: "Belief"
        case .counsel: "Counsel"
        case .therapy: "Therapy"
        case .memoir: "Memoir"
        case .narrative: "Narrative"
        }
    }

    /// Whether a quiz stem must ATTRIBUTE rather than assert.
    ///
    /// "In The 48 Laws, Greene advises…" rather than "The best way to disarm a
    /// rival is…". The app can test comprehension of a claim without endorsing
    /// it as fact, and that is the whole difference between a library and a
    /// doctrine. Method and stoic-practice books may state principles directly;
    /// strategy, belief and counsel are always attributed to their author.
    var requiresAttributedQuizStems: Bool {
        switch self {
        case .strategy, .belief, .counsel, .narrative, .memoir: true
        case .stoicPractice, .devotion, .method, .therapy: false
        }
    }
}
