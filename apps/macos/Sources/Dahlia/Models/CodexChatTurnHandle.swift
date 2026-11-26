import Foundation

struct CodexChatTurnHandle: Sendable {
    let id: UUID
    let events: AsyncThrowingStream<CodexChatTurnEvent, any Error>
    let approvalMethod: CodexChatApprovalMethod?
    let isCommand: Bool
    var snapshot: CodexChatThread?

    init(
        id: UUID,
        events: AsyncThrowingStream<CodexChatTurnEvent, any Error>,
        approvalMethod: CodexChatApprovalMethod? = nil,
        snapshot: CodexChatThread? = nil,
        isCommand: Bool = false
    ) {
        self.id = id
        self.events = events
        self.approvalMethod = approvalMethod
        self.snapshot = snapshot
        self.isCommand = isCommand
    }
}
