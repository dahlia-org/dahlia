import Foundation

/// Contains only fixed categories and a numeric HTTP status, never the underlying error's content.
struct PiInstallError: LocalizedError, Equatable {
    enum Stage: String, CaseIterable {
        case release, download, verification, extraction, activation

        var description: String {
            switch self {
            case .release: L10n.piInstallReleaseStage
            case .download: L10n.piInstallDownloadStage
            case .verification: L10n.piInstallVerificationStage
            case .extraction: L10n.piInstallExtractionStage
            case .activation: L10n.piInstallActivationStage
            }
        }
    }

    enum Reason: String, CaseIterable {
        case http, rateLimited, invalidResponse, invalidRelease, missingAsset, missingDigest
        case checksumMismatch, extractionFailed, executableMissing
        case networkTimeout, networkOffline, networkTLS, networkOther, fileSystem

        var description: String {
            switch self {
            case .http: L10n.piInstallHTTPFailed
            case .rateLimited: L10n.piInstallRateLimited
            case .invalidResponse: L10n.piInstallInvalidResponse
            case .invalidRelease: L10n.piInstallInvalidRelease
            case .missingAsset: L10n.piInstallMissingAsset
            case .missingDigest: L10n.piInstallMissingDigest
            case .checksumMismatch: L10n.piInstallChecksumMismatch
            case .extractionFailed: L10n.piInstallExtractionFailed
            case .executableMissing: L10n.piInstallExecutableMissing
            case .networkTimeout: L10n.piInstallNetworkTimeout
            case .networkOffline: L10n.piInstallNetworkOffline
            case .networkTLS: L10n.piInstallNetworkTLS
            case .networkOther: L10n.piInstallNetworkFailed
            case .fileSystem: L10n.piInstallFileSystemFailed
            }
        }
    }

    let stage: Stage
    let reason: Reason
    var httpStatus: Int?

    var errorDescription: String? {
        let message = L10n.piInstallFailed(stage.description, reason.description)
        return httpStatus.map { "\(message) (HTTP \($0))" } ?? message
    }

    var diagnosticContext: [String: String] {
        var context = ["source": "piInstallation", "piInstallStage": stage.rawValue, "piInstallReason": reason.rawValue]
        if let httpStatus { context["httpStatus"] = String(httpStatus) }
        return context
    }

    static func wrapping(_ error: Error, stage: Stage) -> Self {
        if let failure = error as? Self { return failure }
        guard let network = error as? URLError else { return Self(stage: stage, reason: .fileSystem) }
        let reason: Reason = switch network.code {
        case .timedOut: .networkTimeout
        case .notConnectedToInternet: .networkOffline
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired: .networkTLS
        default: .networkOther
        }
        return Self(stage: stage, reason: reason)
    }
}
