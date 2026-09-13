import Foundation
import SwiftData
import CobuxCore

/// Cross-conversation memory: one chat drawing on what he said in the others.
///
/// Its own file, not a region of `SearchService`, for one load-bearing reason:
/// these are the most privacy-critical lines in the app -- the journal/Face-ID
/// exclusion, the assistant-never-retrieved rule, the quiet-words gate -- and
/// they must be EXECUTABLE outside the app target, because the app's test
/// target cannot link for the simulator (MLX has no simulator slice). A
/// separate Foundation-clean file drops into the macOS test harness verbatim,
/// so these boundaries are proven by running tests, not by reading.
///
/// Deliberately references nothing above it: no ChatPromptBuilder, no views.
/// Callers hand in the journal thread id; `SearchService.CrossChatInput`
/// defaults it to the real one so it fails closed.
enum CrossChatMemory {
    /// A value snapshot of one user message -- everything retrieval needs and
    /// nothing more.
    ///
    /// The privacy core operates on THESE, never on live `ChatMessage` models:
    /// models are confined to the main actor (the documented Build-5 crash
    /// class), and ranking cosine similarity over two thousand of them is
    /// exactly the work that must not run there. A `Sendable` snapshot makes
    /// off-main ranking safe by construction -- and makes these functions
    /// testable with plain values, no SwiftData container required.
    struct Snapshot: Sendable {
        let content: String
        let isUser: Bool
        let bookID: UUID?
        let timestamp: Date
        let embedding: [Float]?
    }

    /// Caps for cross-chat retrieval. Small on purpose: this is memory, not a
    /// transcript, and the failure mode it has to avoid is rumination
    /// amplification -- the thing he talks about most is the most similar to
    /// everything, so an unbounded version quietly turns his worst loop into
    /// the background of every conversation.
    static let crossChatTopK = 3
    static let crossChatExcerptCharLimit = 300

    /// What a retrieved message's thread may be called in the block.
    ///
    /// Structured rather than a free string so the names-closed rule can be
    /// applied HERE, beside the sentence that states it. A situation's name is
    /// his label for a real person or a real situation; the block orders the
    /// model to say which conversation a memory came from AND never to repeat
    /// personal names -- and with the caller's finished string already holding
    /// the name, the label won by construction: a name he had closed came out
    /// through the attribution line. A privacy gate a label can defeat is not
    /// a gate. Book titles are public and stay.
    enum ThreadLabel: Sendable, Equatable {
        case general
        case book(title: String)
        case situation(name: String)
        case unknown

        func rendered(useRealNames: Bool) -> String {
            switch self {
            case .general:
                return "your general Cobux chat"
            case .book(let title):
                return "your \(title) thread"
            case .situation(let name):
                return useRealNames ? "your thread about \(name)" : "one of your situation threads"
            case .unknown:
                return "another conversation"
            }
        }
    }

    /// How many of HIS turns the model will actually see this request.
    ///
    /// `ClaudeService` sends the newest `maxMessages` messages of the strictly
    /// alternating history -- user AND assistant -- so a full window holds half
    /// as many of his turns as messages. The current-window exclusion used to
    /// count `maxMessages` USER rows instead: twice the real window, and every
    /// turn in the gap was in neither the history nor retrieval -- "what did I
    /// say earlier about my brother?" failed on a message fourteen turns back.
    static func visibleUserTurns(historyRoles: [String], maxMessages: Int) -> Int {
        historyRoles.suffix(max(0, maxMessages)).filter { $0 == "user" }.count
    }

    /// The timestamp separating "already in front of the model" from "eligible
    /// for retrieval" in the current thread: the oldest of the newest
    /// `visibleUserTurns + 1` user rows. The +1 is the turn being sent right
    /// now -- inserted before the fetch, not yet in the history, and the one
    /// message that must never be quoted back at itself. `contextBlock`
    /// excludes rows at or after the cutoff; nil excludes nothing.
    static func recentWindowCutoff(userTimestampsNewestFirst timestamps: [Date],
                                   visibleUserTurns: Int) -> Date? {
        timestamps.prefix(max(0, visibleUserTurns) + 1).last
    }

    /// Whether he is explicitly asking about past conversations.
    ///
    /// Same asymmetry as `asksAboutOwnWriting`, and for the same reason: a
    /// direct question is not ambient, so it is not gated. Misses fail SAFE
    /// (treated as incidental, therefore filtered), which is the direction an
    /// imperfect substring matcher should fail in.
    static func asksAboutPastChats(_ query: String) -> Bool {
        let lowered = query.lowercased()
        let markers = ["we talked about", "we discussed", "last time", "you told me",
                       "you said", "what did i say", "i told you", "i mentioned",
                       "our other chat", "earlier conversation", "previous conversation",
                       "we were talking", "remember when i", "did i tell you"]
        return markers.contains { lowered.contains($0) }
    }

    /// Ranks his past messages against the current question.
    ///
    /// Groups by thread rather than by message so one heavily-used thread
    /// cannot crowd out every other -- the same argument `relevantPersonalWriting`
    /// makes with `entry.source`.
    static func relevantChatMessages(query: String, messages: [Snapshot],
                                     topK: Int = CrossChatMemory.crossChatTopK) -> [Snapshot] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !messages.isEmpty else { return [] }

        guard let queryVector = EmbeddingService.embed(trimmed) else {
            let lowered = trimmed.lowercased()
            return Array(messages.filter { $0.content.lowercased().contains(lowered) }
                .prefix(topK))
        }

        var byID: [String: Snapshot] = [:]
        var items: [RankableItem] = []
        items.reserveCapacity(messages.count)
        for (index, message) in messages.enumerated() {
            guard let vector = message.embedding else { continue }
            // The array index: provably unique within this call, which is the
            // only scope the id lives in.
            let idString = String(index)
            byID[idString] = message
            items.append(RankableItem(
                id: idString,
                bookID: message.bookID?.uuidString ?? "general",
                rawScore: EmbeddingService.cosineSimilarity(queryVector, vector)
            ))
        }
        return Ranker.rank(items: items, topK: topK).compactMap { byID[$0.id] }
    }

    /// The block that lets one conversation draw on the others.
    ///
    /// Three exclusions are structural rather than configurable:
    ///
    /// - **Assistant messages are never in the pool.** They are not passed in
    ///   at all (see `ChatMessage.embeddingData`). Retrieving Cobux's own past
    ///   replies would re-inject real names spelled out under an older toggle
    ///   state, and would let the app's past characterizations of him
    ///   reinforce themselves into a permanent verdict.
    /// - **The journal thread is never in the pool.** It sits behind the
    ///   journal's Face ID lock; content behind biometrics must not reappear in
    ///   an unlocked thread through a side channel.
    /// - **The current thread's recent window is never in the pool**, because
    ///   it is already in the conversation history verbatim; retrieving it
    ///   again would spend budget quoting what the model can already see.
    ///
    /// And the quiet-words gate applies to the incidental case exactly as it
    /// does everywhere else, with the same single exception: a DIRECT question
    /// about past conversations is ungated, because quieting a word means stop
    /// bringing it up at me, never hide my own words from me.
    ///
    /// Attribution is rendered from `ThreadLabel`s under the same
    /// `useRealNames` flag that governs the names sentence, so under
    /// names-closed the block can say which conversation a memory came from
    /// without a situation's name ever appearing in it.
    static func contextBlock(query: String,
                                      userMessages: [Snapshot],
                                      currentThreadID: UUID?,
                                      recentWindowCutoff: Date?,
                                      journalThreadID: UUID,
                                      threadLabel: @escaping (UUID?) -> ThreadLabel,
                                      useRealNames: Bool) -> String {
        let direct = asksAboutPastChats(query)
        let pool = userMessages.filter { message in
            guard message.isUser else { return false }
            guard message.bookID != journalThreadID else { return false }
            if message.bookID == currentThreadID, let cutoff = recentWindowCutoff,
               message.timestamp >= cutoff { return false }
            return direct || JournalHighlightSelector.maySurface(message.content)
        }
        let ranked = relevantChatMessages(query: query, messages: pool,
                                          topK: direct ? crossChatTopK * 4 : crossChatTopK)
        guard !ranked.isEmpty else { return "" }

        var block = "## From The User's Other Conversations With You\n\n"
        block += direct
            ? "The user is asking about something said in an earlier conversation, so treat these as the primary material and answer from them directly. "
            : "Where one of these genuinely bears on the question, you may draw on it — at most one per reply, and only when it truly fits. "
        // The app quotes and dates; it never claims to simply remember. He must
        // always know WHY he is being shown something.
        block += "Whenever you use one, say which conversation it came from and when, in words (\"in your Meditations thread back in March you mentioned…\"). Never present it as something you simply recall. "
        block += useRealNames
            ? "You may refer to people from these by the names used there.\n\n"
            : "NEVER repeat personal names of private individuals from these — refer to people only by role or relationship, even if the message names them.\n\n"

        // Built once per prompt assembly, already OUTSIDE the loop it feeds:
        // `contextBlock` runs once for the message being sent, not per row and
        // not per frame. It also runs inside `ChatView.send`'s detached
        // off-main task -- deliberately, so the ranking does not sit under his
        // thumb -- so a shared `static let` here would be a formatter reached
        // from a background caller, which is exactly the condition `ChatView`'s
        // own hoisted pair documents itself as NOT doing.
        // lint-ok: formatter-constructed-per-render -- once per message sent, off-main by design, already outside the loop
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        for message in ranked {
            let excerpt = message.content.count > crossChatExcerptCharLimit
                ? String(message.content.prefix(crossChatExcerptCharLimit)) + "…"
                : message.content
            let label = threadLabel(message.bookID).rendered(useRealNames: useRealNames)
            block += "- [\(label)] (\(formatter.string(from: message.timestamp))): \"\(excerpt)\"\n"
        }
        block += "\n"
        return block
    }

}
