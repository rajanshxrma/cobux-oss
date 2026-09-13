import CobuxCore
import Foundation
import Observation
import SwiftData

/// One turn of the in-pane conversation.
///
/// A value, not a `@Model`: the transcript here is this session's only, and
/// the durable copy is written to the app's store as ordinary `ChatMessage`
/// rows once a reply finishes (`MessagesPaneModel.persist`). Holding SwiftData
/// objects in a view's state across a store write is the exact class of trap
/// `docs/regressions.yml` records for Wisdom; values cannot do that.
struct MessagesChatTurn: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case cobux
    }

    let id: UUID
    let role: Role
    /// The model's output verbatim, `<sources>` tag and all, while streaming;
    /// the cleaned display text once finished. `displayText` hides the seam.
    var rawText: String
    var isStreaming: Bool
    /// Set instead of text when the turn failed. Already user-facing copy
    /// (`ClaudeError.userFacingMessage`), never a status code.
    var errorLine: String?

    init(role: Role, rawText: String = "", isStreaming: Bool = false) {
        self.id = UUID()
        self.role = role
        self.rawText = rawText
        self.isStreaming = isStreaming
    }

    /// What the bubble shows.
    ///
    /// `PromptTemplates.base` ends with `CitationResolver.instructionSuffix`,
    /// which asks the model to close every reply with `<sources>…</sources>`.
    /// The app parses that tag off before display; this pane has no citation
    /// chips to feed, but it uses the SAME template so the Messages answer and
    /// the in-app answer come from one prompt, not two -- so it strips the tag
    /// the same way. While streaming, the tag arrives a few characters at a
    /// time, so anything from a trailing `<` that could still become
    /// `<sources>` is held back rather than flashed on screen.
    var displayText: String {
        guard isStreaming else {
            return CitationResolver.parse(rawReply: rawText).displayText
        }
        if let open = rawText.range(of: "<sources>") {
            return String(rawText[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let lastOpen = rawText.range(of: "<", options: .backwards) {
            let tail = String(rawText[lastOpen.lowerBound...])
            if "<sources>".hasPrefix(tail) {
                return String(rawText[..<lastOpen.lowerBound])
            }
        }
        return rawText
    }

    /// The lines the model marked as message drafts (`"> "` prefix, the
    /// repartee convention in `PromptTemplates`), without the marker. Each
    /// one is offered on its own as something to drop into the conversation.
    var draftLines: [String] {
        displayText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0) }
            .filter { $0.hasPrefix("> ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The whole reply as a sendable message: draft markers removed, nothing
    /// else touched. What "Send to conversation" inserts.
    var sendableText: String {
        displayText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                line.hasPrefix("> ") ? String(line.dropFirst(2)) : String(line)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The pane's single source of truth, owned by `MessagesViewController` and
/// handed to whichever root view the presentation style calls for.
///
/// Why a model outside the view: Messages does not re-present the pane when
/// it changes size, it hands the controller a new style and the controller
/// REASSIGNS `host.rootView`. State that lives inside the view survives that
/// only as long as SwiftUI happens to see the same view identity, which is
/// exactly the kind of "happens to" a text field's contents should not rest
/// on -- what he typed in the strip has to be what the expanded pane shows.
/// Holding it here makes the carry-over a fact rather than a property of the
/// diff, and gives the controller a place to say "focus now" after the
/// transition it alone knows has finished (`focusRequest`).
///
/// Nothing runs at construction. The keychain is read on the first send, the
/// network monitor starts on the first send, the store is opened after the
/// first finished reply -- an extension gets a fraction of an app's memory and
/// its first frame must cost nothing.
@MainActor
@Observable
final class MessagesPaneModel {
    /// What the expanded pane is for right now. The compact strip is always
    /// journal; this only steers the roomier surface.
    enum Mode: Hashable {
        case journal
        case ask
    }

    /// One line above the transcript, for states that are not a turn.
    enum Notice: Equatable {
        /// No key readable from this process. The line carries a link to
        /// Settings because that is the only place it can be fixed.
        case missingKey
        /// `MSConversation.insertText` reported an error.
        case insertFailed
        /// Confirmation after a copy; cleared on the next action.
        case copied
    }

    var mode: Mode = .journal

    // MARK: Journal

    var journalText = ""

    /// Bumped by the controller once Messages has FINISHED the transition to
    /// the expanded style. Views watch it and take focus on change. Distinct
    /// from `.onAppear`, which can fire while the pane is still mid-animation
    /// and not yet able to host the keyboard -- the "sometimes" in "sometimes
    /// it does not show the keyboard".
    private(set) var focusRequest = 0

    func requestFocus() {
        focusRequest += 1
    }

    // MARK: Ask Cobux

    private(set) var turns: [MessagesChatTurn] = []
    var draft = ""
    private(set) var isReplying = false
    var notice: Notice?

    @ObservationIgnored private var replyTask: Task<Void, Never>?

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isReplying
    }

    /// The system prompt: `PromptTemplates.base` -- Cobux's own voice, the
    /// repartee register, the tradition rule, the sources tag -- with the
    /// library slot carrying a one-line note instead of a library, and one
    /// paragraph after it saying where the user is.
    ///
    /// The note in the slot matters more than it looks. `base` tells the
    /// model that when "the library genuinely has nothing bearing on the
    /// question" it should say so and suggest adding a book. Fed an EMPTY
    /// slot it would obey that on every turn and tell him his library is
    /// empty. The paragraph names the surface, says the library is simply not
    /// attached here, and relaxes the grounding rule exactly that far and no
    /// further -- attribute by author, never invent a quote. It also asks for
    /// what he actually wants from this pane, in his words: something "text
    /// friendly" he can "slide down and send".
    ///
    /// Appended AFTER `String(format:)` so nothing in it can be read as a
    /// format directive.
    private static let systemPrompt: String = {
        let slot = "(Not attached on this surface -- see the note below.)"
        let addendum = """


        One more thing about where you are right now. The user is talking to you from inside a text conversation in Messages, on a small pane, and what they want from you is something they can send as a message. Their library is not attached on this surface, so the grounding rule above relaxes exactly this far: draw on the books Cobux carries -- attachment, influence, power, stoicism, human nature -- name the author when you lean on one, and never invent a quote or a study. Do not tell them the library is empty and do not send them off to add a book; this pane simply does not carry it. Keep it short, a text rather than an essay, in their register. When you draft the message itself, put each candidate on its own "> " line so they can lift it straight into the conversation.
        """
        return String(format: PromptTemplates.base, slot) + addendum
    }()

    /// A short, cheap turn. Thinking off and a tight cap for the same reason
    /// voice mode sets them: a texting-length answer is retrieval-free and
    /// short, and thinking tokens bill as output while buying nothing here.
    private static let requestOptions = ClaudeService.RequestOptions(maxTokens: 1024, thinkingDisabled: true)

    func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isReplying else { return }
        draft = ""
        notice = nil
        ask(question)
    }

    /// Re-sends the question a failed reply was answering. The failed pair is
    /// removed so the transcript never shows two attempts at one question.
    func retry(_ replyID: UUID) {
        guard !isReplying,
              let replyIndex = turns.firstIndex(where: { $0.id == replyID }),
              replyIndex > 0,
              turns[replyIndex - 1].role == .user else { return }
        let question = turns[replyIndex - 1].rawText
        turns.removeSubrange((replyIndex - 1)...replyIndex)
        notice = nil
        ask(question)
    }

    /// Stops a reply mid-stream. Whatever arrived stays -- a half answer he
    /// stopped on purpose is his, not an error.
    func stop() {
        replyTask?.cancel()
        replyTask = nil
        if let index = turns.lastIndex(where: { $0.isStreaming }) {
            turns[index].isStreaming = false
            if turns[index].rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                turns[index].errorLine = "Stopped."
            }
        }
        isReplying = false
    }

    private func ask(_ question: String) {
        // The user's line lands on screen before anything else happens --
        // before the keychain read, before the network check.
        turns.append(MessagesChatTurn(role: .user, rawText: question))
        let reply = MessagesChatTurn(role: .cobux, isStreaming: true)
        turns.append(reply)
        isReplying = true

        let history = conversationHistory(excludingLast: 2)
        let replyID = reply.id

        replyTask = Task { [weak self] in
            guard let self else { return }
            guard let apiKey = KeychainManager.load(key: KeychainManager.anthropicAPIKey), !apiKey.isEmpty else {
                // Not a failed turn: nothing was asked yet. Put the question
                // back in the composer and say the one true thing.
                turns.removeLast(2)
                draft = question
                isReplying = false
                notice = .missingKey
                return
            }

            let service = ClaudeService(apiKey: apiKey)
            let stream = service.streamMessage(
                userMessage: question,
                conversationHistory: history,
                systemPrompt: Self.systemPrompt,
                options: Self.requestOptions
            )

            do {
                for try await chunk in stream {
                    guard !Task.isCancelled else { return }
                    append(chunk, to: replyID)
                }
                // A cancelled consumer ends the stream quietly rather than
                // throwing, and `stop()` has already settled the turn.
                guard !Task.isCancelled else { return }
                finish(replyID, question: question)
            } catch is CancellationError {
                // `stop()` already settled the turn.
            } catch let error as ClaudeError {
                if case .truncated = error {
                    // Everything the model said was yielded; only the tail
                    // is missing. Keep it, the way the app does.
                    finish(replyID, question: question)
                } else {
                    fail(replyID, line: error.userFacingMessage)
                }
            } catch {
                fail(replyID, line: ClaudeError.networkError(error).userFacingMessage)
            }
        }
    }

    private func append(_ chunk: String, to replyID: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == replyID }) else { return }
        turns[index].rawText += chunk
    }

    private func finish(_ replyID: UUID, question: String) {
        guard let index = turns.firstIndex(where: { $0.id == replyID }) else { return }
        let cleaned = CitationResolver.parse(rawReply: turns[index].rawText).displayText
        turns[index].rawText = cleaned
        turns[index].isStreaming = false
        if cleaned.isEmpty {
            turns[index].errorLine = ClaudeError.invalidResponse.userFacingMessage
        }
        isReplying = false
        replyTask = nil
        if !cleaned.isEmpty {
            persist(question: question, answer: cleaned)
        }
    }

    private func fail(_ replyID: UUID, line: String) {
        guard let index = turns.firstIndex(where: { $0.id == replyID }) else { return }
        turns[index].isStreaming = false
        turns[index].errorLine = line
        isReplying = false
        replyTask = nil
    }

    /// The finished turns as the API wants them, capped at the app's own
    /// window so a long pane session costs what a long app session costs.
    private func conversationHistory(excludingLast: Int) -> [AIMessage] {
        let settled = turns.dropLast(excludingLast).filter { $0.errorLine == nil && !$0.isStreaming && !$0.rawText.isEmpty }
        let window = Array(settled.suffix(ClaudeService.maxHistoryMessages))
        return window.map { AIMessage(role: $0.role == .user ? "user" : "assistant", content: $0.rawText) }
    }

    /// Writes the finished exchange into the app's general thread.
    ///
    /// His design for this surface: "the whole thing opens and then Cobux
    /// chat could load and you could respond". The thread should live in the
    /// app and the pane should be a window onto it -- so each finished turn
    /// becomes two ordinary `ChatMessage` rows with `bookID: nil` (the general
    /// thread), through the same App-Group container the journal strip
    /// already writes. `ChatView` loads its history when it mounts, so the
    /// exchange is there the next time the Chat tab opens.
    ///
    /// Off the main actor, after the reply is on screen: opening the
    /// container is the one non-trivial cost in this file and nothing he can
    /// see waits on it. `referencedBooks` stays empty -- the pane carries no
    /// library to resolve a declared title against, and a missing chip is a
    /// smaller failure than a wrong one. `embeddingData` stays nil, which the
    /// model documents as "not indexed yet"; the app's own backfill decides.
    private func persist(question: String, answer: String) {
        let asked = Date.now
        Task.detached(priority: .utility) {
            guard let container = CobuxSchema.makeAppGroupContainer() else { return }
            let context = ModelContext(container)
            context.insert(ChatMessage(content: question, isUser: true, timestamp: asked, bookID: nil))
            context.insert(ChatMessage(content: answer, isUser: false, timestamp: asked.addingTimeInterval(1), bookID: nil))
            do {
                try context.save()
                // A separate process wrote to the store; tell the app.
                CrossProcessSync.markDirty()
            } catch {
                // Back on the main actor for the log line: `DiagnosticLog`
                // stamps its first line of a launch with `UIDevice` fields.
                let description = error.localizedDescription
                await MainActor.run {
                    DiagnosticLog.log("messages pane: chat persist failed: \(description)")
                }
            }
        }
    }
}
