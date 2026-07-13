import Foundation

/// プロバイダーごとの Bearer トークン取得方法を統一する。
struct LLMCredentialResolver {
    private let databricksClient: DatabricksCLIClient

    init(databricksClient: DatabricksCLIClient = DatabricksCLIClient()) {
        self.databricksClient = databricksClient
    }

    func accessToken(
        provider: LLMProvider,
        apiToken: String,
        databricksAuthenticationType: DatabricksAuthenticationType,
        databricksProfile: String
    ) async throws -> String {
        switch provider {
        case .openAI:
            guard let token = apiToken.nilIfBlank else {
                throw LLMCredentialError.openAITokenRequired
            }
            return token
        case .databricks:
            switch databricksAuthenticationType {
            case .personalAccessToken:
                guard let token = apiToken.nilIfBlank else {
                    throw LLMCredentialError.databricksPersonalAccessTokenRequired
                }
                return token
            case .oauthCLI:
                return try await databricksClient.accessToken(profile: databricksProfile)
            }
        }
    }
}

enum LLMCredentialError: LocalizedError {
    case openAITokenRequired
    case databricksPersonalAccessTokenRequired

    var errorDescription: String? {
        switch self {
        case .openAITokenRequired:
            L10n.openAIAPITokenRequired
        case .databricksPersonalAccessTokenRequired:
            L10n.databricksPersonalAccessTokenRequired
        }
    }
}
