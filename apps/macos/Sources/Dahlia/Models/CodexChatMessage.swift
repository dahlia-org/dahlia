import Foundation

struct CodexChatMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
        case notice(CodexChatNoticeLevel)
    }

    let id: String
    let role: Role
    var text: String
    var reasoning: String
    var isStreaming: Bool
    var context: CodexChatContext?
    var images: [CodexChatImageAttachment]
    var isSteer: Bool

    init(
        id: String = UUID.v7().uuidString,
        role: Role,
        text: String,
        reasoning: String = "",
        isStreaming: Bool = false,
        context: CodexChatContext? = nil,
        images: [CodexChatImageAttachment] = [],
        isSteer: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.isStreaming = isStreaming
        self.context = context
        self.images = images
        self.isSteer = isSteer
    }
}
