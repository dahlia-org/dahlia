import DahliaRuntimeSupport
import Foundation

enum CodexRuntimeProvider: Codable, Hashable, Sendable {
    case chatGPTSubscription
    case databricks(profile: String)
    case dahlia(connectionID: UUID)

    init(
        accountConnectionID: UUID?,
        localProvider: AIAccountProvider,
        databricksProfile: String
    ) {
        if let accountConnectionID {
            self = .dahlia(connectionID: accountConnectionID)
        } else if localProvider == .databricks {
            self = .databricks(profile: databricksProfile)
        } else {
            self = .chatGPTSubscription
        }
    }

    var accountConnectionID: UUID? {
        guard case let .dahlia(connectionID) = self else { return nil }
        return connectionID
    }

    var authenticationConnection: (id: UUID, provider: DahliaTokenBrokerProtocol.Provider)? {
        switch self {
        case let .dahlia(id): (id, .dahlia)
        case let .databricks(profile): UUID(uuidString: profile).map { ($0, .databricks) }
        case .chatGPTSubscription: nil
        }
    }

    var localAccountProvider: AIAccountProvider? {
        switch self {
        case .chatGPTSubscription: .chatGPTSubscription
        case .databricks: .databricks
        case .dahlia: nil
        }
    }

    var displayName: String {
        switch self {
        case .chatGPTSubscription: L10n.chatGPTSubscription
        case .databricks: L10n.databricks
        case .dahlia: L10n.dahliaAccount
        }
    }
}
