import Foundation

enum CodexChatApprovalDecision: Equatable, Sendable {
    case accept
    case acceptForSession
    case acceptWithExecpolicyAmendment([String])
    case decline
    case cancel

}
