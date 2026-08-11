import Foundation

enum CodexAppServerChatTurnEvent: Sendable {
    case started(turnID: String)
    case message(JSONValue)
    case approvalResolved(id: String)
}

struct CodexAppServerChatTurn: Sendable {
    let id: UUID
    let events: AsyncThrowingStream<CodexAppServerChatTurnEvent, any Error>
}
