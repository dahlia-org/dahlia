import Foundation

struct CodexChatTurnHandle: Sendable {
    let id: UUID
    let events: AsyncThrowingStream<CodexChatTurnEvent, any Error>
}
