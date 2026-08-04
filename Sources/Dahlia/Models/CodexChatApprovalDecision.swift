import Foundation

/// Wire values of the Codex app-server `CommandExecutionApprovalDecision` and
/// `FileChangeApprovalDecision` responses.
enum CodexChatApprovalDecision: String, Sendable {
    case accept
    case acceptForSession
    case decline
    /// Denies the request and interrupts the turn instead of letting the agent continue.
    case cancel
}
