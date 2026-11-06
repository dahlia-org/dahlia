import DahliaRuntimeSupport
import Foundation

/// The account whose Pi runtime runs AI work. The Local Account uses the OpenAI and Anthropic subscriptions; a
/// Databricks account uses its workspace's AI Gateway; a Dahlia account uses its Server. Each has its own Pi directory.
enum CodexRuntimeProvider: Codable, Hashable, Sendable {
    case local
    case databricks(connectionID: UUID)
    case dahlia(connectionID: UUID)

    init(accountConnectionID: UUID?, databricksConnectionID: UUID? = nil) {
        self = accountConnectionID.map(Self.dahlia) ?? databricksConnectionID.map(Self.databricks) ?? .local
    }

    init(workspace: WorkspaceRecord?) {
        self.init(accountConnectionID: workspace?.accountConnectionId, databricksConnectionID: workspace?.databricksConnectionId)
    }

    /// The Dahlia account's connection; nil for the Local and Databricks accounts.
    var accountConnectionID: UUID? {
        guard case let .dahlia(connectionID) = self else { return nil }
        return connectionID
    }

    var displayName: String {
        switch self {
        case .local: L10n.localAccount
        case .databricks: L10n.databricks
        case .dahlia: L10n.dahliaAccount
        }
    }

    /// Recording processing persisted by Codex-era releases stores `chatGPTSubscription` or `databricks` (both now the
    /// Local Account); a Databricks account is `databricksWorkspace`.
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
        } else if let values = try? container.nestedContainer(keyedBy: AssociatedKeys.self, forKey: .databricksWorkspace) {
            self = try .databricks(connectionID: values.decode(UUID.self, forKey: .connectionID))
        } else if container.contains(.local) || container.contains(.chatGPTSubscription) || container.contains(.databricks) {
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
        case let .databricks(connectionID):
            var values = container.nestedContainer(keyedBy: AssociatedKeys.self, forKey: .databricksWorkspace)
            try values.encode(connectionID, forKey: .connectionID)
        case let .dahlia(connectionID):
            var values = container.nestedContainer(keyedBy: AssociatedKeys.self, forKey: .dahlia)
            try values.encode(connectionID, forKey: .connectionID)
        }
    }
}
