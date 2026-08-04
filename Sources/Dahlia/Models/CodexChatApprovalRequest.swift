import Foundation

struct CodexChatApprovalRequest: Identifiable, Equatable, Sendable {
    struct FileChange: Equatable, Sendable {
        let path: String
        let diff: String
    }

    enum Kind: Equatable, Sendable {
        case commandExecution
        case fileChange
    }

    let id: String
    let kind: Kind
    let command: String?
    let cwd: String?
    let fileChanges: [FileChange]
    let grantRoot: String?
    let reason: String?

    init(
        id: String,
        kind: Kind,
        command: String? = nil,
        cwd: String? = nil,
        fileChanges: [FileChange] = [],
        grantRoot: String? = nil,
        reason: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.command = command
        self.cwd = cwd
        self.fileChanges = fileChanges
        self.grantRoot = grantRoot
        self.reason = reason
    }

    var canApprove: Bool {
        switch kind {
        case .commandExecution:
            command?.nilIfBlank != nil
        case .fileChange:
            !fileChanges.isEmpty
        }
    }
}
