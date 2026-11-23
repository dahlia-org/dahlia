import DahliaRuntimeSupport
import Foundation

/// The account whose Pi runtime runs AI work: the app's one account (`local`), which uses the Pi subscriptions and
/// every Databricks provider account, or a Dahlia Server account, which uses its Server and has its own Pi directory.
enum CodexRuntimeProvider: Codable, Hashable, Sendable {
    case local
    case dahlia(connectionID: UUID)

    init(accountConnectionID: UUID?) {
        self = accountConnectionID.map(Self.dahlia) ?? .local
    }

    init(workspace: WorkspaceRecord?) {
        self.init(accountConnectionID: workspace?.accountConnectionId)
    }

    /// The Dahlia account's connection; nil for the app's account.
    var accountConnectionID: UUID? {
        guard case let .dahlia(connectionID) = self else { return nil }
        return connectionID
    }

    var displayName: String {
        switch self {
        case .local: L10n.localAccount
        case .dahlia: L10n.dahliaAccount
        }
    }

    /// Recording processing persisted by earlier releases stores `chatGPTSubscription`, `databricks`, or a Databricks
    /// account's `databricksWorkspace`; each is the app's account now.
    private enum CodingKeys: String, CodingKey {
        case local, dahlia, databricksWorkspace, chatGPTSubscription, databricks
    }

    private enum AssociatedKeys: String, CodingKey {
        case connectionID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let values = try? container.nestedContainer(keyedBy: AssociatedKeys.self, forKey: .dahlia) {
            self = try .dahlia(connectionID: values.decode(UUID.self, forKey: .connectionID))
        } else if container.contains(.local) || container.contains(.chatGPTSubscription) || container.contains(.databricks)
            || container.contains(.databricksWorkspace) {
            self = .local
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown AI account"))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            _ = container.nestedContainer(keyedBy: AssociatedKeys.self, forKey: .local)
        case let .dahlia(connectionID):
            var values = container.nestedContainer(keyedBy: AssociatedKeys.self, forKey: .dahlia)
            try values.encode(connectionID, forKey: .connectionID)
        }
    }
}
