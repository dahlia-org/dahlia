import Foundation

enum CodexConfigurationError: LocalizedError, Equatable {
    case databricksProfileRequired
    case invalidDatabricksWorkspaceURL
    case accountNotReady
    case updateFailed(String)

    var errorDescription: String? {
        switch self {
        case .databricksProfileRequired:
            L10n.databricksProfileRequired
        case .invalidDatabricksWorkspaceURL:
            L10n.databricksWorkspaceURLInvalid
        case .accountNotReady:
            L10n.codexAccountConfigurationNotReady
        case let .updateFailed(detail):
            L10n.codexConfigurationUpdateFailed(detail)
        }
    }
}
