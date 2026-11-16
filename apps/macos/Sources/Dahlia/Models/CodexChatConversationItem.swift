import Foundation

enum CodexChatConversationItem: Identifiable, Equatable {
    case contextDivider(id: String, context: CodexChatContext?)
    case message(CodexChatMessage, showsInlineActivity: Bool = false)
    case relatedThreads(messageID: String, threads: [CodexChatThreadSummary])
    case thinking

    var id: String {
        switch self {
        case let .contextDivider(id, _):
            "context-\(id)"
        case let .message(message, _):
            "message-\(message.id)"
        case let .relatedThreads(messageID, _):
            "related-\(messageID)"
        case .thinking:
            "thinking"
        }
    }

    static func build(
        from messages: [CodexChatMessage],
        showsStandaloneThinking: Bool = false,
        previousUserContext initialPreviousUserContext: CodexChatContext? = nil,
        hasPreviousUserMessage initialHasPreviousUserMessage: Bool = false,
        relatedThreadsByMessageID: [String: [CodexChatThreadSummary]] = [:]
    ) -> [Self] {
        var items: [Self] = []
        var previousUserContext = initialPreviousUserContext
        var hasPreviousUserMessage = initialHasPreviousUserMessage

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
            if !showsStandaloneThinking || !isEmptyStreamingResponse(message) {
                items.append(.message(message))
            }
        }

        var showsInlineActivity = false
        if let lastIndex = items.indices.last,
           case let .message(message, _) = items[lastIndex],
           message.role == .assistant,
           message.isStreaming,
           message.text.isEmpty,
           !message.reasoning.isEmpty {
            items[lastIndex] = .message(message, showsInlineActivity: true)
            showsInlineActivity = true
        }

        if showsStandaloneThinking, !showsInlineActivity {
            items.append(.thinking)
        }
        return items.flatMap { item -> [Self] in
            guard case let .message(message, _) = item,
                  let threads = relatedThreadsByMessageID[message.id] else { return [item] }
            return [item, .relatedThreads(messageID: message.id, threads: threads)]
        }
    }

    static func relatedThreadAnchors(
        threads: [CodexChatThreadSummary],
        messages: [CodexChatMessage],
        currentRunID: UUID?
    ) -> [String: [CodexChatThreadSummary]] {
        var groups: [String: [CodexChatThreadSummary]] = [:]
        let indices = Dictionary(messages.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let runIndices = Dictionary(messages.enumerated().compactMap { index, message in
            message.runID.map { ($0, index) }
        }, uniquingKeysWith: { first, _ in first })
        let lastVisibleIndex = messages.indices.last { !isEmptyStreamingResponse(messages[$0]) }
        for thread in threads {
            let sourceIndex = thread.requestMessageID.flatMap { indices[$0] }
                ?? thread.requestRunID.flatMap { runIndices[$0] }
                ?? (thread.requestRunID != nil && thread.requestRunID == currentRunID ? lastVisibleIndex : nil)
            guard var index = sourceIndex else { continue }
            // Keep the card with the reply to its request, before the next user input or notification.
            var next = index + 1
            while next < messages.count, messages[next].role == .assistant {
                if !isEmptyStreamingResponse(messages[next]) { index = next }
                next += 1
            }
            groups[messages[index].id, default: []].append(thread)
        }
        return groups
    }

    private static func isEmptyStreamingResponse(_ message: CodexChatMessage) -> Bool {
        message.role == .assistant && message.isStreaming && !message.hasResponseContent
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
