import Foundation

struct AIMessage {
    let role: String
    let content: String
}

protocol AIService {
    func sendMessage(userMessage: String, conversationHistory: [AIMessage], systemPrompt: String) async throws -> String
    func streamMessage(userMessage: String, conversationHistory: [AIMessage], systemPrompt: String) -> AsyncThrowingStream<String, Error>
}
