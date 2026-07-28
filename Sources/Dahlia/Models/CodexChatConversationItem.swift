import Foundation

enum CodexChatConversationItem: Identifiable, Equatable {
    case contextDivider(id: String, context: CodexChatContext?)
    case message(CodexChatMessage)
    case thinking

    var id: String {
        switch self {
        case let .contextDivider(id, _):
            "context-\(id)"
        case let .message(message):
            "message-\(message.id)"
        case .thinking:
            "thinking"
        }
    }

    static func build(
        from messages: [CodexChatMessage],
        showsStandaloneThinking: Bool = false
    ) -> [Self] {
        var items: [Self] = []
        var previousUserContext: CodexChatContext?
        var hasPreviousUserMessage = false

        for message in messages {
            if message.role == .user {
                if shouldInsertDivider(
                    before: message.context,
                    previousContext: previousUserContext,
                    hasPreviousUserMessage: hasPreviousUserMessage
                ) {
                    items.append(.contextDivider(id: message.id, context: message.context))
                }
                previousUserContext = message.context
                hasPreviousUserMessage = true
            }
            items.append(.message(message))
        }
        if showsStandaloneThinking {
            items.append(.thinking)
        }
        return items
    }

    private static func shouldInsertDivider(
        before context: CodexChatContext?,
        previousContext: CodexChatContext?,
        hasPreviousUserMessage: Bool
    ) -> Bool {
        guard hasPreviousUserMessage else { return context != nil }
        switch (previousContext, context) {
        case (nil, nil):
            return false
        case let (previous?, current?):
            return !previous.sharesConversationSection(with: current)
        case (.some, nil), (nil, .some):
            return true
        }
    }
}
