import Foundation

enum CodexChatApprovalAction: Equatable, Identifiable, Sendable {
    case allowOnce
    case allowForSession
    case allowSimilarCommands(amendment: [String])
    case deny

    var id: String {
        switch self {
        case .allowOnce: "allowOnce"
        case .allowForSession: "allowForSession"
        case .allowSimilarCommands: "allowSimilarCommands"
        case .deny: "deny"
        }
    }

    var decision: CodexChatApprovalDecision {
        switch self {
        case .allowOnce: .accept
        case .allowForSession: .acceptForSession
        case let .allowSimilarCommands(amendment): .acceptWithExecpolicyAmendment(amendment)
        case .deny: .decline
        }
    }
}
