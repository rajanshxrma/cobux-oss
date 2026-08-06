import AppIntents
import SwiftData
import Foundation

enum AskCobuxIntentError: LocalizedError {
    case missingAPIKey
    case noContainer

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your Anthropic API key in Cobux Settings before asking questions."
        case .noContainer:
            return "Couldn't open your Cobux library. Try again from the app."
        }
    }
}

struct AskCobuxIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Cobux"
    static var description = IntentDescription("Ask your book library a question.")

    @Parameter(title: "Question")
    var question: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let container = try? ModelContainer(
            for: Book.self, Highlight.self, Chapter.self, ChatMessage.self, Theme.self,
            configurations: ModelConfiguration(groupContainer: .identifier("group.com.rajansharma.Cobux"))
        ) else {
            throw AskCobuxIntentError.noContainer
        }

        let context = ModelContext(container)
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []

        let (contextString, _) = SearchService.buildContext(query: question, books: books)

        guard let apiKey = KeychainManager.load(key: KeychainManager.anthropicAPIKey), !apiKey.isEmpty else {
            throw AskCobuxIntentError.missingAPIKey
        }

        let service = ClaudeService(apiKey: apiKey)
        let answer = try await service.sendMessage(
            userMessage: question,
            conversationHistory: [],
            systemPrompt: String(format: PromptTemplates.askIntent, contextString)
        )

        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}
