import Foundation

struct CodexChatThread: Equatable {
    let id: String
    let title: String
    let messages: [CodexChatMessage]
    let model: String?
    let reasoningEffort: String?
    let approvalMethod: CodexChatApprovalMethod?

    init(
        id: String,
        title: String,
        messages: [CodexChatMessage],
        model: String?,
        reasoningEffort: String?,
        approvalMethod: CodexChatApprovalMethod? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.approvalMethod = approvalMethod
    }
}
