import DahliaRuntimeSupport
import Foundation

/// The account whose Pi runtime runs AI work: the app's one account, which uses the Pi subscriptions and every
/// provider account (Databricks connections and the signed-in Dahlia account's Gateway).
enum CodexRuntimeProvider: Codable, Hashable, Sendable {
    case local

    var displayName: String { L10n.localAccount }

    /// Recording processing persisted by earlier releases stores `chatGPTSubscription`, `databricks`, a Databricks
    /// account's `databricksWorkspace`, or a Dahlia Server account's `dahlia`; each is the app's account now.
    private enum CodingKeys: String, CodingKey {
        case local, dahlia, databricksWorkspace, chatGPTSubscription, databricks
    }

    private enum AssociatedKeys: String, CodingKey {
        case connectionID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.local) || container.contains(.chatGPTSubscription) || container.contains(.databricks)
            || container.contains(.databricksWorkspace) || container.contains(.dahlia) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown AI account"))
        }
        self = .local
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        _ = container.nestedContainer(keyedBy: AssociatedKeys.self, forKey: .local)
    }
}
