import Foundation
import SwiftData

/// One ongoing situation with another person, as its own chat thread.
///
/// Chat's biggest real use in this app is working through something with
/// someone — and in the general thread that person gets diluted between GRE
/// questions and book lookups until, thirty messages later, she is gone. The
/// thread was already the memory unit; it just needed one dedicated to her.
///
/// **What this deliberately is not: a dossier.**
///
/// Everything remembered here is one of exactly two things the user can see and
/// delete — the transcript itself, and a note they wrote by hand. There is no
/// field for an inference about the other person, and that absence is the
/// design, not an omission. "She's textbook avoidant" may appear in the
/// transcript, where he wrote it and can delete it; it must never become a
/// stored attribute, because an app that quietly keeps structured findings on a
/// real third party is one screenshot away from being indefensible — and the
/// person it describes never agreed to any of it.
///
/// So: no auto-creation (the model may suggest a thread; only a tap makes one),
/// no extraction of facts from messages, no merging threads by name, no link to
/// Contacts. A situation is a story the user is telling, not an identity record.
@Model
final class SituationThread {
    var id: UUID = UUID()
    /// Whatever he wants to call it. The field's placeholder offers a nickname
    /// or "the situationship" precisely so the app never requires a real name
    /// for a real person.
    var name: String = ""
    /// Optional context he pins himself. Written by him, edited by him, and the
    /// only structured memory this feature has.
    var note: String?
    var createdDate: Date = Date()
    var lastActivityDate: Date = Date()

    init(name: String, note: String? = nil) {
        self.id = UUID()
        self.name = name
        self.note = note
        self.createdDate = .now
        self.lastActivityDate = .now
    }
}
