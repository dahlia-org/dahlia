import Foundation

enum PiRuntimeError: LocalizedError, Equatable {
    case helperNotBundled
    /// No `pi` at the path set in Settings, or none found on the search path when it is `nil`.
    case piCommandNotFound(String?)
    case launchFailed(String)
    case notLoggedIn
    case loginFailed(String?)
    case loginPageCouldNotOpen
    case processExited(String?)
    case requestTimedOut(String)
    case invalidProtocolResponse
    case rpcError(code: Int?, message: String)
    case providerAuthenticationFailed(String?)
    case turnFailed(String?)
    case turnInterrupted
    case backendResetForSafety
    case approvalNoLongerPending
    case emptyResponse
    case requestedModelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .helperNotBundled: L10n.codexHelperNotBundled
        case let .piCommandNotFound(path): path.map(L10n.piExecutableNotFound) ?? L10n.piCommandNotFound
        case let .launchFailed(detail): L10n.codexLaunchFailed(detail)
        case .notLoggedIn: L10n.codexNotLoggedIn
        case let .loginFailed(detail): detail.map(L10n.codexLoginFailed) ?? L10n.codexLoginFailedWithoutDetail
        case .loginPageCouldNotOpen: L10n.codexLoginPageCouldNotOpen
        case let .processExited(detail):
            detail.map(L10n.codexProcessExitedWithDetail) ?? L10n.codexProcessExited
        case let .requestTimedOut(operation): L10n.codexRequestTimedOut(operation)
        case .invalidProtocolResponse: L10n.codexInvalidResponse
        case let .rpcError(_, message): L10n.codexRequestFailed(message)
        case let .providerAuthenticationFailed(detail):
            detail.map(L10n.codexRequestFailed) ?? L10n.codexTurnFailed
        case let .turnFailed(detail): detail.map(L10n.codexRequestFailed) ?? L10n.codexTurnFailed
        case .turnInterrupted: L10n.codexTurnInterrupted
        case .backendResetForSafety: L10n.codexBackendResetForSafety
        case .approvalNoLongerPending: L10n.codexApprovalNoLongerPending
        case .emptyResponse: L10n.llmErrorEmptyResponse
        case let .requestedModelUnavailable(model): L10n.piRequestedModelUnavailable(model)
        }
    }

    var isNoActiveTurnToSteer: Bool {
        guard case let .rpcError(_, message) = self else { return false }
        return message.localizedCaseInsensitiveContains("no active turn to steer")
    }

    var isThreadNotFound: Bool {
        guard case let .rpcError(_, message) = self else { return false }
        return message.localizedCaseInsensitiveContains("thread not found")
    }
}
