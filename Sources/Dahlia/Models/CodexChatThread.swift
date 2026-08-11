import Foundation

struct CodexChatThread: Equatable {
    let id: String
    let title: String
    let messages: [CodexChatMessage]
    let model: String?
    let reasoningEffort: String?
}
