@testable import Dahlia

@MainActor
final class TestCodexAccountConfigurationStore: CodexAccountConfigurationStoring {
    private(set) var configuredProviderRawValue: String
    private(set) var configuredDatabricksProfile: String

    init(
        configuredProvider: AIAccountProvider = .chatGPTSubscription,
        configuredDatabricksProfile: String = ""
    ) {
        configuredProviderRawValue = configuredProvider.rawValue
        self.configuredDatabricksProfile = configuredDatabricksProfile
    }

    func invalidateCodexAccountConfiguration() {
        configuredProviderRawValue = ""
        configuredDatabricksProfile = ""
    }

    func markCodexAccountConfigurationCurrent(
        provider: AIAccountProvider,
        databricksProfile: String
    ) {
        configuredProviderRawValue = provider.rawValue
        configuredDatabricksProfile = provider == .databricks ? databricksProfile : ""
    }
}
