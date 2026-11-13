import Foundation

struct CodexChatMessagePage: Sendable {
    let messages: [CodexChatMessage]
    let earlierCursor: String?
}
