import Foundation

struct CodexChatMessage: Identifiable, Equatable {
    enum Role {
        case user
        case assistant
    }

    let id: String
    let role: Role
    var text: String
    var reasoning: String
    var isStreaming: Bool
    var context: CodexChatContext?
    var images: [CodexChatImageAttachment]

    init(
        id: String = UUID.v7().uuidString,
        role: Role,
        text: String,
        reasoning: String = "",
        isStreaming: Bool = false,
        context: CodexChatContext? = nil,
        images: [CodexChatImageAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.isStreaming = isStreaming
        self.context = context
        self.images = images
    }
}
