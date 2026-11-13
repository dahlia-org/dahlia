import Foundation

/// The account a workspace is listed under. Local and Databricks workspaces keep their data on this Mac.
enum WorkspaceAccountChoice: Hashable {
    case local
    case databricks(UUID)
    case dahlia(UUID)

    init(_ workspace: WorkspaceRecord) {
        self = workspace.accountConnectionId.map(Self.dahlia) ?? workspace.databricksConnectionId.map(Self.databricks) ?? .local
    }

    func displayName(connections: [DahliaAccountConnection], databricksAccounts: [DatabricksConnection]) -> String {
        switch self {
        case .local:
            L10n.localAccount
        case let .databricks(id):
            databricksAccounts.first(where: { $0.id == id }).map { L10n.unityGatewayHost($0.hostName) }
                ?? "\(L10n.account) · \(id.uuidString.prefix(8))"
        case let .dahlia(id):
            connections.first(where: { $0.id == id }).map {
                "\($0.displayName) · \($0.isCloud ? L10n.dahliaCloud : L10n.dahliaServer)"
            } ?? "\(L10n.account) · \(id.uuidString.prefix(8))"
        }
    }
}
