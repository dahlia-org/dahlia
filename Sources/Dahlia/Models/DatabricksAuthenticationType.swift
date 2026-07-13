import Foundation

/// Databricks AI Gateway への認証方法。
enum DatabricksAuthenticationType: String, CaseIterable, Identifiable {
    case personalAccessToken
    case oauthCLI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .personalAccessToken:
            L10n.personalAccessToken
        case .oauthCLI:
            L10n.oauthDatabricksCLI
        }
    }
}
