import Foundation

/// The account a workspace is listed under: the app's, whose data stays on this Mac, or a Dahlia Server's.
enum WorkspaceAccountChoice: Hashable {
    case local
    case dahlia(UUID)

    init(_ workspace: WorkspaceRecord) {
        self = workspace.accountConnectionId.map(Self.dahlia) ?? .local
    }

    func displayName(connections: [DahliaAccountConnection]) -> String {
        switch self {
        case .local:
            L10n.localAccount
        case let .dahlia(id):
            connections.first(where: { $0.id == id }).map {
                "\($0.displayName) · \($0.isCloud ? L10n.dahliaCloud : L10n.dahliaServer)"
            } ?? "\(L10n.account) · \(id.uuidString.prefix(8))"
        }
    }
}
