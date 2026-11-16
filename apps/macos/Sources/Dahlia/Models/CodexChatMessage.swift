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
    var threadResults: [CodexChatThreadResult]
    var toolActivities: [CodexChatToolActivity]
    var runID: UUID?

    init(
        id: String = UUID.v7().uuidString,
        role: Role,
        text: String,
        reasoning: String = "",
        isStreaming: Bool = false,
        context: CodexChatContext? = nil,
        images: [CodexChatImageAttachment] = [],
        isSteer: Bool = false,
        threadResults: [CodexChatThreadResult] = [],
        toolActivities: [CodexChatToolActivity] = [],
        runID: UUID? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.isStreaming = isStreaming
        self.context = context
        self.images = images
        self.isSteer = isSteer
        self.threadResults = threadResults
        self.toolActivities = toolActivities
        self.runID = runID
    }

    var hasResponseContent: Bool {
        !text.isEmpty || !reasoning.isEmpty || !toolActivities.isEmpty
    }

    /// A page boundary can split a call and its result. Keep one row at the call's original position.
    static func prependingHistory(_ earlier: [Self], to current: [Self]) -> [Self] {
        var earlier = earlier
        var positions: [UUID?: [String: (Int, Int)]] = [:]
        for message in earlier.indices {
            for tool in earlier[message].toolActivities.indices {
                if let id = earlier[message].toolActivities[tool].callID {
                    positions[earlier[message].runID, default: [:]][id] = (message, tool)
                }
            }
        }
        let current = current.compactMap { message -> Self? in
            var message = message
            let hadTools = !message.toolActivities.isEmpty
            let runID = message.runID
            message.toolActivities.removeAll { activity in
                guard let id = activity.callID, let (row, tool) = positions[runID]?[id] else { return false }
                var updated = activity
                updated.detail = activity.detail ?? earlier[row].toolActivities[tool].detail
                earlier[row].toolActivities[tool] = updated
                return true
            }
            if hadTools, message.toolActivities.isEmpty, message.text.isEmpty, message.reasoning.isEmpty { return nil }
            return message
        }
        return earlier + current
    }

    mutating func recordToolActivity(_ activity: CodexChatToolActivity) {
        if let index = toolActivities.lastIndex(where: {
            if let id = activity.callID { return $0.callID == id }
            return $0.name == activity.name && $0.status == .running
        }) {
            var updated = activity
            updated.detail = activity.detail ?? toolActivities[index].detail
            toolActivities[index] = updated
        } else {
            toolActivities.append(activity)
            // Older operations remain available through stored history pages.
            if toolActivities.count > 100 { toolActivities.removeFirst(toolActivities.count - 100) }
        }
    }
}
