import Foundation

struct CodexChatThread: Equatable {
    let id: String
    let title: String
    var messages: [CodexChatMessage]
    let model: String?
    let reasoningEffort: String?
    let approvalMethod: CodexChatApprovalMethod?
    let earlierMessagesCursor: String?
    var isReadOnly = false
    var parentThread: CodexChatThreadSummary?
    var lastItemSeq: Int64?
    /// The agent whose Source's intake thread this is.
    var intakeAgent: AgentRecord?

    init(
        id: String,
        title: String,
        messages: [CodexChatMessage],
        model: String?,
        reasoningEffort: String?,
        approvalMethod: CodexChatApprovalMethod? = nil,
        earlierMessagesCursor: String? = nil,
        isReadOnly: Bool = false,
        parentThread: CodexChatThreadSummary? = nil,
        lastItemSeq: Int64? = nil,
        intakeAgent: AgentRecord? = nil
    ) {
        self.intakeAgent = intakeAgent
        self.isReadOnly = isReadOnly
        self.parentThread = parentThread
        self.lastItemSeq = lastItemSeq
        self.id = id
        self.title = title
        self.messages = messages
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.approvalMethod = approvalMethod
        self.earlierMessagesCursor = earlierMessagesCursor
    }
}
