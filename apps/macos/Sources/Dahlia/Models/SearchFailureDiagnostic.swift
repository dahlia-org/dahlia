import Foundation
import GRDB

struct SearchFailureDiagnostic: Hashable, Sendable {
    enum Operation: String, Sendable {
        case indexing = "searchIndexing"
        case imageAnalysis = "screenshotAnalysis"
    }

    enum Reason: String, CaseIterable, Sendable {
        case configuration, authentication, modelUnavailable, helperUnavailable
        case launchFailed, processExited, timedOut, invalidResponse, providerFailed
        case databaseBusy, databaseFailed, unknown
    }

    let operation: Operation
    let reason: Reason

    init?(error: any Error, operation: Operation) {
        self.operation = operation
        switch error {
        case is CancellationError:
            return nil
        case let error as PiRuntimeError:
            switch error {
            case .turnInterrupted, .backendResetForSafety: return nil
            case .notLoggedIn, .loginFailed, .loginPageCouldNotOpen, .providerAuthenticationFailed: reason = .authentication
            case .requestedModelUnavailable: reason = .modelUnavailable
            case .helperNotBundled, .piCommandNotFound: reason = .helperUnavailable
            case .launchFailed: reason = .launchFailed
            case .processExited: reason = .processExited
            case .requestTimedOut: reason = .timedOut
            case .invalidProtocolResponse, .emptyResponse: reason = .invalidResponse
            case .rpcError, .turnFailed: reason = .providerFailed
            case .approvalNoLongerPending: reason = .unknown
            }
        case is AIConfigurationError:
            reason = .configuration
        case is ScreenshotAnalysisError:
            reason = .invalidResponse
        case let error as DatabaseError:
            reason = error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED ? .databaseBusy : .databaseFailed
        default:
            reason = .unknown
        }
    }
}
