import Foundation

struct CodexChatApprovalRequest: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case commandExecution
        case fileChange
    }

    let id: String
    let kind: Kind
    let command: String?
    let cwd: String?
    let reason: String?

    init(
        id: String,
        kind: Kind,
        command: String? = nil,
        cwd: String? = nil,
        reason: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.command = command
        self.cwd = cwd
        self.reason = reason
    }
}
