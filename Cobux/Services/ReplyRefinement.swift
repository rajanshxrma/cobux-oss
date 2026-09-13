import Foundation

/// One-tap refinements for a drafted reply: the candidate message Cobux wrote
/// for him, made warmer, shorter, or more direct without retyping the ask.
///
/// Foundation-clean and value-only on purpose -- this drops into the macOS
/// test harness like `CrossChatMemory` and `ChatTranscript`, so its rules are
/// proven by execution:
///
/// - The refinement is sent as a VISIBLE, ordinary user message through the
///   normal send path. Never a hidden prompt: the transcript is his record of
///   what was asked, and a chat that secretly edits its own inputs is a chat
///   whose history lies.
/// - The quote rides along re-prefixed with "> " line by line, and the reply
///   is requested back as a quote -- so the refined version renders as a
///   copyable card again, ready for the person it is actually for.
/// - The three templates are fixed strings with no characterization
///   vocabulary: they describe the TEXT ("warmer", "shorter", "more direct"),
///   never him or the person he is writing to.
enum ReplyRefinement: String, CaseIterable {
    case warmer, shorter, moreDirect

    var label: String {
        switch self {
        case .warmer: "Warmer"
        case .shorter: "Shorter"
        case .moreDirect: "More direct"
        }
    }

    var icon: String {
        switch self {
        case .warmer: "sun.max"
        case .shorter: "scissors"
        case .moreDirect: "arrow.forward"
        }
    }

    private var ask: String {
        switch self {
        case .warmer: "Make this warmer, keeping it real:"
        case .shorter: "Make this shorter, same substance:"
        case .moreDirect: "Make this more direct, still kind:"
        }
    }

    /// The user message a refinement tap sends.
    ///
    /// Every line of the quote gets its own "> " prefix -- a bare ">" would
    /// END a quote block (`ChatTranscript.blocks` documents why that rule
    /// exists), so blank interior lines are dropped rather than emitted bare.
    static func message(_ refinement: ReplyRefinement, quoting quote: String) -> String {
        let quoted = quote
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "> \($0)" }
            .joined(separator: "\n")
        return refinement.ask + "\n\n" + quoted + "\n\nReply with just the rewritten message, as a quote."
    }
}
