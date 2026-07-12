import Foundation

/// プロバイダーごとの Bearer トークン取得方法を統一する。
struct LLMCredentialResolver {
    private let databricksClient: DatabricksCLIClient

    init(databricksClient: DatabricksCLIClient = DatabricksCLIClient()) {
        self.databricksClient = databricksClient
    }

    func accessToken(
        provider: LLMProvider,
        openAIAPIToken: String,
        databricksProfile: String
    ) async throws -> String {
        switch provider {
        case .openAI:
            guard let token = openAIAPIToken.nilIfBlank else {
                throw LLMCredentialError.openAITokenRequired
            }
            return token
        case .databricks:
            return try await databricksClient.accessToken(profile: databricksProfile)
        }
    }
}

enum LLMCredentialError: LocalizedError {
    case openAITokenRequired

    var errorDescription: String? {
        L10n.openAIAPITokenRequired
    }
}
