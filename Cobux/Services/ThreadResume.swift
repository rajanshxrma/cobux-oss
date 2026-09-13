import Foundation

/// "Where we left off" for the thread pickers: each row shows when its
/// conversation last moved and a one-line quote of the last message -- so
/// reopening after days away, he can see which thread holds which
/// conversation before entering it.
///
/// Quote-and-date, never a summary: a summary of "what we were discussing"
/// characterizes; the last line, dated, is a mirror. Pure over value tuples
/// so the rules live in the harness:
///
/// - **The journal thread contributes nothing at all** -- not even a date. It
///   sits behind Face ID, and a "last written Tuesday" line in an unlocked
///   picker is a leak of exactly the kind the lock exists to stop.
/// - **Situation threads get the date only, no excerpt.** Transcripts about
///   real people are the most sensitive non-journal content in the app; the
///   name he gave the thread is already its identity.
/// - Book and general threads get the last message's first line, truncated.
enum ThreadResume {
    struct Line: Equatable {
        let date: Date
        let excerpt: String?
    }

    struct MessageStub: Sendable {
        let content: String
        let bookID: UUID?
        let timestamp: Date
    }

    static let excerptLimit = 80

    /// Latest line per thread key (nil key = the general thread).
    static func resumeLines(messages: [MessageStub],
                            journalThreadID: UUID,
                            situationIDs: Set<UUID>) -> [UUID?: Line] {
        var out: [UUID?: Line] = [:]
        for message in messages {
            if message.bookID == journalThreadID { continue }
            let key = message.bookID
            if let existing = out[key], existing.date >= message.timestamp { continue }
            let isSituation = message.bookID.map { situationIDs.contains($0) } ?? false
            out[key] = Line(date: message.timestamp,
                            excerpt: isSituation ? nil : excerpt(of: message.content))
        }
        return out
    }

    private static func excerpt(of content: String) -> String {
        let collapsed = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > excerptLimit else { return collapsed }
        return String(collapsed.prefix(excerptLimit)) + "…"
    }
}
