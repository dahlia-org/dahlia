import Foundation

struct CodexChatThreadPage: Equatable {
    let threads: [CodexChatThreadSummary]
    let nextCursor: String?
}
