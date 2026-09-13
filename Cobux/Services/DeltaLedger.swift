import CryptoKit
import Foundation
import SwiftData

/// The coarse record of what has accumulated here, and the seed of the Sigil.
///
/// Rajan's ask, in his words: a section that is *"like a treasure that the user
/// cannot open... it exists, but a user cannot click on it — it's gonna reflect
/// something."* His analogy is his own AI brain: it exists in a repository he
/// never reads, it is used by his agents, and knowing it exists is the point.
///
/// **What is deliberately NOT here: any distillation of who he is.** An
/// LLM-written summary of his philosophies would be a stored characterization he
/// cannot read — `SituationThread` already rules that shape indefensible when
/// pointed at a third party, and pointing it at the user himself is worse, not
/// better, because he could never check it. The treasure is the corpus he
/// already wrote. This is only the coarse shape of it.
///
/// Everything here is a count, a date, or a direction. No text, ever.
enum DeltaLedger {
    struct Snapshot: Equatable {
        var words = 0
        var entries = 0
        var chatTurns = 0
        var highlights = 0
        var keeps = 0
        var firstEntry: Date?
        /// Mean of his entry embeddings — a direction in semantic space, not a
        /// judgment. It drifts as what he writes about drifts, and says nothing
        /// about what that is.
        var centroid: [Float] = []
    }

    private static let saltKey = "cobux.delta.salt"
    /// The greatest `words` ever counted here. See `snapshot`'s own note on
    /// why a live recount alone cannot be trusted to only ever grow.
    private static let wordsHighWaterKey = "cobux.sigil.wordsHighWater"

    /// Minted once and kept, so the Sigil is his rather than the device's.
    static func salt() -> Data {
        if let existing = UserDefaults.standard.data(forKey: saltKey), existing.count == 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        let data = Data(bytes)
        UserDefaults.standard.set(data, forKey: saltKey)
        return data
    }

    @MainActor
    static func snapshot(context: ModelContext) -> Snapshot {
        var s = Snapshot()
        let entries = (try? context.fetch(FetchDescriptor<PersonalWritingEntry>())) ?? []
        s.entries = entries.count
        s.firstEntry = entries.map { $0.modifiedDate ?? $0.dateImported }.min()
        var sum: [Float] = []
        var vectors = 0
        for entry in entries {
            s.words += entry.text.split(whereSeparator: \.isWhitespace).count
            if let v = entry.embedding, !v.isEmpty {
                if sum.isEmpty { sum = v } else if sum.count == v.count {
                    for i in sum.indices { sum[i] += v[i] }
                }
                vectors += 1
            }
        }
        if vectors > 0, !sum.isEmpty {
            s.centroid = sum.map { $0 / Float(vectors) }
        }
        // What he types in chat counts toward the treasure, not just what he
        // files in the journal. His words: "as the user is talking more and
        // more, it should be collected." Chat's only route into the Sigil was
        // the `s.chatTurns / 25` bucket in `seed(for:)` below, which re-rolls
        // the PATTERN but never feeds `strands(words:)` -- so someone who only
        // ever chatted watched a mark that never grew, which is the one thing
        // a treasure has to do.
        //
        // Free: this fetch already existed and already materialised the rows to
        // count them, so the loop below reads `content` off objects that were
        // in memory either way. Still only a count leaves this function -- the
        // "no text, ever" rule at the top of the file holds. Assistant replies
        // stay excluded: they are not his.
        let chatMessages = ((try? context.fetch(FetchDescriptor<ChatMessage>())) ?? [])
            .filter(\.isUser)
        s.chatTurns = chatMessages.count
        for message in chatMessages {
            s.words += message.content.split(whereSeparator: \.isWhitespace).count
        }
        s.highlights = (try? context.fetchCount(FetchDescriptor<Highlight>())) ?? 0
        s.keeps = (try? context.fetchCount(FetchDescriptor<JournalKeep>())) ?? 0
        // High-water, because counting chat words above opened a way to DOCK
        // the mark. Chat rows are the user's to delete -- Clear Chat, a book
        // thread swiped away in the thread picker, a situation deleted -- and
        // this snapshot is recomputed from the store on every open, so a live
        // recount alone would hand `strands(words:)` a smaller number than
        // last time and the Sigil would visibly lose a strand. Growth-only
        // (see `strands` below) is the whole anti-grading mechanism: a
        // treasure accumulates and is never docked, and "I deleted a chat and
        // it took something away from me" is exactly the grading it forbids.
        // The greatest total ever counted is kept and floors every later one.
        // Journal words have no delete path, so for a journal-only user this
        // never does anything. Only the strand COUNT is a magnitude the eye
        // can see shrink; the `chatTurns / 25` bucket in `seed(for:)` re-rolls
        // the pattern rather than measuring it, and a re-rolled pattern is not
        // a smaller one.
        let highWaterWords = UserDefaults.standard.integer(forKey: wordsHighWaterKey)
        if s.words > highWaterWords {
            UserDefaults.standard.set(s.words, forKey: wordsHighWaterKey)
        } else {
            s.words = highWaterWords
        }
        return s
    }

    /// How complex the Sigil is allowed to be.
    ///
    /// Log-scaled and coarsely bucketed on purpose: it visibly grows across
    /// months and years and cannot move week to week, so it can never read as a
    /// weekly score. **Growth-only** is the anti-grading mechanism — a treasure
    /// accumulates and is never docked, so a quiet month costs him nothing.
    /// Monotonic here is only half of that: `words` now includes chat, which is
    /// deletable, so `snapshot` floors it with a high-water mark rather than
    /// letting a Clear Chat take a strand away.
    static func strands(words: Int) -> Int {
        guard words >= 500 else { return 3 }
        return min(11, 3 + Int(log2(Double(words) / 500.0)))
    }

    /// The Sigil's seed: hashed, so no strand thickness or count can be read
    /// back as a quantity. A decodable mapping would rebuild the census and
    /// monument vetoes in graphics.
    static func seed(for s: Snapshot) -> [UInt8] {
        var hasher = SHA256()
        hasher.update(data: salt())
        // Bucketed before hashing, so the mark is stable between milestones
        // rather than shifting every time he writes a sentence.
        for value in [s.words / 500, s.entries / 10, s.chatTurns / 25,
                      s.highlights / 100, s.keeps] {
            withUnsafeBytes(of: Int32(value).littleEndian) { hasher.update(data: Data($0)) }
        }
        return Array(hasher.finalize())
    }

    /// A hue angle from the centroid's direction — meaningless as judgment,
    /// but it drifts as his subject matter drifts.
    static func hueAngle(for s: Snapshot) -> Double {
        guard s.centroid.count >= 2 else { return 0 }
        let x = Double(s.centroid[0]), y = Double(s.centroid[1])
        guard x != 0 || y != 0 else { return 0 }
        return (atan2(y, x) + .pi) / (2 * .pi)
    }
}
