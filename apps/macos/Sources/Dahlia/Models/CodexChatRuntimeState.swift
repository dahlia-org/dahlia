import Foundation

struct CodexChatRuntimeState: Sendable {
    let threadID: String
    let accountID: String
    let turnID: UUID
    let approvals: [CodexChatApprovalRequest]
    /// `running`, `queued`, or `settled`: the thread is idle and `turnID` is the last run it ended in this app session.
    var status = "running"
    var isScheduled = false
}
