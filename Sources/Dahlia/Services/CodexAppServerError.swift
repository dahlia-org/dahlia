import Foundation

enum CodexAppServerError: LocalizedError, Equatable {
    case helperNotBundled
    case launchFailed(String)
    case notLoggedIn
    case loginFailed(String?)
    case loginPageCouldNotOpen
    case processExited(String?)
    case requestTimedOut(String)
    case invalidProtocolResponse
    case rpcError(code: Int?, message: String)
    case turnFailed(String?)
    case turnInterrupted
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .helperNotBundled: L10n.codexHelperNotBundled
        case let .launchFailed(detail): L10n.codexLaunchFailed(detail)
        case .notLoggedIn: L10n.codexNotLoggedIn
        case let .loginFailed(detail): detail.map(L10n.codexLoginFailed) ?? L10n.codexLoginFailedWithoutDetail
        case .loginPageCouldNotOpen: L10n.codexLoginPageCouldNotOpen
        case let .processExited(detail):
            detail.map(L10n.codexProcessExitedWithDetail) ?? L10n.codexProcessExited
        case let .requestTimedOut(operation): L10n.codexRequestTimedOut(operation)
        case .invalidProtocolResponse: L10n.codexInvalidResponse
        case let .rpcError(_, message): L10n.codexRequestFailed(message)
        case let .turnFailed(detail): detail.map(L10n.codexRequestFailed) ?? L10n.codexTurnFailed
        case .turnInterrupted: L10n.codexTurnInterrupted
        case .emptyResponse: L10n.llmErrorEmptyResponse
        }
    }
}
