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

    enum Reviewability: Equatable, Sendable {
        case ready
        case tooLarge
        case unsupported
    }

    let id: String
    let itemID: String?
    let kind: Kind
    let command: String?
    let cwd: String?
    let fileChanges: [FileChange]
    let grantRoot: String?
    let reason: String?
    let reviewability: Reviewability
    let actions: [CodexChatApprovalAction]

    var canApprove: Bool {
        guard reviewability == .ready,
              grantRoot == nil,
              actions.contains(where: { $0 != .deny }) else { return false }
        return switch kind {
        case .commandExecution: command?.nilIfBlank != nil
        case .fileChange: !fileChanges.isEmpty
        }
    }

    init(
        id: String,
        itemID: String? = nil,
        kind: Kind,
        command: String? = nil,
        cwd: String? = nil,
        fileChanges: [FileChange] = [],
        grantRoot: String? = nil,
        reason: String? = nil,
        reviewability: Reviewability = .ready,
        actions: [CodexChatApprovalAction]? = nil
    ) {
        self.id = id
        self.itemID = itemID
        self.kind = kind
        self.command = command
        self.cwd = cwd
        self.fileChanges = fileChanges
        self.grantRoot = grantRoot
        self.reason = reason
        self.reviewability = reviewability
        self.actions = actions ?? Self.defaultActions(kind: kind, reviewability: reviewability)
    }

    private static func defaultActions(
        kind _: Kind,
        reviewability: Reviewability
    ) -> [CodexChatApprovalAction] {
        guard reviewability == .ready else { return [.deny] }
        return [.allowOnce, .allowForSession, .deny]
    }
}
