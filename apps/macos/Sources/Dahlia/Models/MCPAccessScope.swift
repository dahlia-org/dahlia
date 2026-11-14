import DahliaRuntimeSupport
import Foundation

enum MCPAccessScope: Equatable {
    case all
    case account(WorkspaceAccountChoice)
    case workspace(UUID)

    var arguments: [String] {
        switch self {
        case .all: []
        case .account(.local): ["--account", "local"]
        case let .account(.dahlia(id)), let .account(.databricks(id)): ["--account", id.uuidString]
        case let .workspace(id): ["--workspace-id", TypeID.encode(id, as: .workspace)]
        }
    }

    static func resolve(account: WorkspaceAccountChoice?, workspaceID: UUID?, workspaces: [WorkspaceRecord]) -> Self? {
        if let workspaceID {
            guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
                  WorkspaceAccountChoice(workspace) == account else { return nil }
            return .workspace(workspaceID)
        }
        return account.map(Self.account) ?? .all
    }
}
