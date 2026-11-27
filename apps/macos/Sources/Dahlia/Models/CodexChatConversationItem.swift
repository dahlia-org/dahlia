import Foundation

enum CodexChatConversationItem: Identifiable, Equatable {
    case contextDivider(id: String, context: CodexChatContext?)
    case message(CodexChatMessage)
    case relatedThreads(messageID: String, threads: [CodexChatThreadSummary])
    case thinking
    /// The steps of a finished run before its final answer, shown collapsed.
    case work(id: String, messages: [CodexChatMessage], duration: TimeInterval?)
    /// The header of a run still streaming, shown in an agent's chat.
    case running(id: String, startedAt: Date?)

    var id: String {
        switch self {
        case let .contextDivider(id, _):
            "context-\(id)"
        case let .message(message):
            "message-\(message.id)"
        case let .relatedThreads(messageID, _):
            "related-\(messageID)"
        case .thinking:
            "thinking"
        case let .work(id, _, _):
            "work-\(id)"
        case let .running(id, _):
            "running-\(id)"
        }
    }

    static func build(
        from messages: [CodexChatMessage],
        showsStandaloneThinking: Bool = false,
        showsRunHeaders: Bool = false,
        previousUserContext initialPreviousUserContext: CodexChatContext? = nil,
        hasPreviousUserMessage initialHasPreviousUserMessage: Bool = false,
        relatedThreadsByMessageID: [String: [CodexChatThreadSummary]] = [:]
    ) -> [Self] {
        var items: [Self] = []
        var previousUserContext = initialPreviousUserContext
        var hasPreviousUserMessage = initialHasPreviousUserMessage

        for segment in collapsingFinishedRuns(messages, showsRunHeaders: showsRunHeaders) {
            guard case let .message(message) = segment else {
                if case let .work(_, steps, _) = segment,
                   let steer = steps.last(where: { $0.role == .user }) {
                    previousUserContext = steer.context
                }
                items.append(segment)
                continue
            }
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

        let hasStreamingReasoning: Bool = if case let .message(message)? = items.last {
            message.role == .assistant && message.isStreaming && message.text.isEmpty && !message.reasoning.isEmpty
        } else {
            false
        }

        items = items.flatMap { item -> [Self] in
            let messageIDs: [String] = switch item {
            case let .message(message): [message.id]
            // The answer row carries its own threads; its steps copy shares its ID.
            case let .work(answerID, steps, _): steps.map(\.id).filter { $0 != answerID }
            default: []
            }
            let threads = messageIDs.flatMap { relatedThreadsByMessageID[$0] ?? [] }
            guard let messageID = messageIDs.last, !threads.isEmpty else { return [item] }
            return [item, .relatedThreads(messageID: messageID, threads: threads)]
        }
        let hasRunningHeader = items.contains { if case .running = $0 { true } else { false } }
        if showsStandaloneThinking || hasStreamingReasoning, !hasRunningHeader { items.append(.thinking) }
        return items
    }

    /// Splits each finished run into its opening message, collapsed steps, and final answer.
    /// A run still streaming, or one that ended without an answer, stays expanded.
    /// With `showsRunHeaders`, a streaming run and a finished run without steps get a header too.
    private static func collapsingFinishedRuns(_ messages: [CodexChatMessage], showsRunHeaders: Bool) -> [Self] {
        var segments: [Self] = []
        var runStartTimes: [UUID: Date] = [:]
        var start = messages.startIndex
        while start < messages.endIndex {
            let head = messages[start]
            var end = start + 1
            if let runID = head.runID {
                while end < messages.endIndex, messages[end].runID == runID, !isRequest(messages[end]) {
                    end += 1
                }
            }
            let run = messages[start ..< end]
            start = end
            // A request or notification opens the run and stays outside its steps.
            let bodyStart = run.startIndex + (head.role != .assistant && !head.isSteer ? 1 : 0)
            // Live notices can split one run into several display segments.
            if let runID = head.runID, isRunOpener(head), let timestamp = head.timestamp, runStartTimes[runID] == nil {
                runStartTimes[runID] = timestamp
            }
            let startedAt = head.runID.flatMap { runStartTimes[$0] }
            guard head.runID != nil,
                  !run.contains(where: \.isStreaming),
                  let finalIndex = run[bodyStart...].lastIndex(where: { !$0.isSteer }),
                  messages[finalIndex].role == .assistant,
                  !messages[finalIndex].text.isEmpty,
                  !messages[finalIndex].endsWithToolActivity
            else {
                segments += messages[run.startIndex ..< bodyStart].map { .message($0) }
                if showsRunHeaders, let runID = head.runID, run.contains(where: \.isStreaming) {
                    segments.append(.running(id: runID.uuidString, startedAt: startedAt))
                }
                segments += messages[bodyStart ..< run.endIndex].map { .message($0) }
                continue
            }
            let answer = messages[finalIndex]
            var steps = Array(messages[bodyStart ..< finalIndex])
            if !answer.reasoning.isEmpty || !answer.toolActivities.isEmpty {
                var answerSteps = answer
                answerSteps.text = ""
                steps.append(answerSteps)
            }
            // A live response holds the whole run, so steers delivered during it follow it until history reloads.
            let trailing = messages[(finalIndex + 1) ..< run.endIndex]
            steps += trailing.filter(\.isSteer)
            segments += messages[run.startIndex ..< bodyStart].map { .message($0) }
            if steps.isEmpty, !showsRunHeaders {
                segments.append(.message(answer))
            } else {
                let duration = startedAt.flatMap { startedAt in
                    answer.timestamp.map { $0.timeIntervalSince(startedAt) }
                }
                var finalAnswer = answer
                finalAnswer.reasoning = ""
                finalAnswer.toolActivities = []
                segments += [.work(id: answer.id, messages: steps, duration: duration), .message(finalAnswer)]
            }
            segments += trailing.filter { !$0.isSteer }.map { .message($0) }
        }
        return segments
    }

    private static func isRequest(_ message: CodexChatMessage) -> Bool {
        message.role == .user && !message.isSteer
    }

    private static func isRunOpener(_ message: CodexChatMessage) -> Bool {
        if case .notice = message.role { return true }
        return isRequest(message)
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
