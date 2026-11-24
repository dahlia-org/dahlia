import DahliaRuntimeSupport
import Foundation

enum MCPAccessScope: Equatable {
    case all
    case workspace(UUID)

    var arguments: [String] {
        switch self {
        case .all: []
        case let .workspace(id): ["--workspace-id", TypeID.encode(id, as: .workspace)]
        }
    }

    /// Nil when the chosen workspace is no longer on this Mac.
    static func resolve(workspaceID: UUID?, workspaces: [WorkspaceRecord]) -> Self? {
        guard let workspaceID else { return .all }
        return workspaces.contains { $0.id == workspaceID } ? .workspace(workspaceID) : nil
    }
}
