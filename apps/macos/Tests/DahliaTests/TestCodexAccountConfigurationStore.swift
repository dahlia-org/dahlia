@testable import Dahlia

@MainActor
final class TestCodexAccountConfigurationStore: CodexAccountConfigurationStoring {
    private(set) var selectedProviderRawValue: String
    private(set) var configuredProviderRawValue: String
    private(set) var configuredDatabricksProfile: String

    init(
        selectedProvider: AIAccountProvider? = nil,
        configuredProvider: AIAccountProvider = .chatGPTSubscription,
        configuredDatabricksProfile: String = ""
    ) {
        selectedProviderRawValue = (selectedProvider ?? configuredProvider).rawValue
        configuredProviderRawValue = configuredProvider.rawValue
        self.configuredDatabricksProfile = configuredDatabricksProfile
    }

    var codexAccountConfigurationSnapshot: CodexAccountConfigurationSnapshot {
        CodexAccountConfigurationSnapshot(
            provider: AIAccountProvider(rawValue: configuredProviderRawValue),
            databricksProfile: configuredDatabricksProfile
        )
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

    func selectCodexAccountProvider(_ provider: AIAccountProvider) {
        selectedProviderRawValue = provider.rawValue
    }
}
