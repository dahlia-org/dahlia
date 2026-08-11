import Foundation

enum DatabricksCLIError: LocalizedError {
    case cliNotInstalled
    case commandFailed(detail: String?)
    case invalidProfilesResponse

    var errorDescription: String? {
        switch self {
        case .cliNotInstalled:
            L10n.databricksCLINotInstalled
        case let .commandFailed(detail):
            detail.map(L10n.databricksCLICommandFailed) ?? L10n.databricksCLICommandFailedWithoutDetail
        case .invalidProfilesResponse:
            L10n.databricksCLIInvalidProfilesResponse
        }
    }
}
