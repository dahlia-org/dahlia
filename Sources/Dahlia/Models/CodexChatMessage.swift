import Foundation

struct CodexChatMessage: Identifiable, Equatable {
    enum Role {
        case user
        case assistant
    }

    let id: String
    let role: Role
    var text: String
    var isStreaming: Bool

    init(
        id: String = UUID.v7().uuidString,
        role: Role,
        text: String,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
    }
}
