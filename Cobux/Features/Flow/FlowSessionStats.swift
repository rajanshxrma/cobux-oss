import Foundation
import Observation

/// Live tallies for one Flow session, rendered on the recap cards. Counted
/// from cards the user actually SETTLED on (FlowView's scroll-position
/// change), not cards that merely built — plus direct increments from the
/// quick-check grade buttons, so the numbers are honest.
@Observable
final class FlowSessionStats {
    private(set) var quotesSeen = 0
    private(set) var lessonsSeen = 0
    private(set) var checksGraded = 0
    private(set) var checksCorrect = 0
    private(set) var booksTouched: Set<UUID> = []

    func recordSettled(on card: FlowCard) {
        switch card {
        case .highlight(let highlight):
            quotesSeen += 1
            if let bookID = highlight.book?.id { booksTouched.insert(bookID) }
        case .keyLesson(let chapter, _):
            lessonsSeen += 1
            if let bookID = chapter.book?.id { booksTouched.insert(bookID) }
        case .clozeTeaser(let question):
            if let bookID = question.book?.id { booksTouched.insert(bookID) }
        case .resonance(let a, let b):
            quotesSeen += 2
            if let bookID = a.book?.id { booksTouched.insert(bookID) }
            if let bookID = b.book?.id { booksTouched.insert(bookID) }
        case .weakTopic, .dailyOpener, .sessionRecap:
            break
        }
    }

    func recordGrade(correct: Bool) {
        checksGraded += 1
        if correct { checksCorrect += 1 }
    }
}
