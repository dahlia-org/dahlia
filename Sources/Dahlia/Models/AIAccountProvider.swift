import Foundation

enum AIAccountProvider: String, CaseIterable, Identifiable {
    case chatGPTSubscription
    case databricks

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chatGPTSubscription:
            L10n.chatGPTSubscription
        case .databricks:
            L10n.databricks
        }
    }
}
