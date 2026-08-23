struct CodexAccountConfigurationSnapshot: Equatable {
    let provider: AIAccountProvider?
    let databricksProfile: String
}

@MainActor
protocol CodexAccountConfigurationStoring: AnyObject {
    var codexAccountConfigurationSnapshot: CodexAccountConfigurationSnapshot { get }

    func invalidateCodexAccountConfiguration()
    func markCodexAccountConfigurationCurrent(
        provider: AIAccountProvider,
        databricksProfile: String
    )
    func selectCodexAccountProvider(_ provider: AIAccountProvider)
}

extension CodexAccountConfigurationStoring {
    func restoreCodexAccountConfiguration(_ snapshot: CodexAccountConfigurationSnapshot) {
        if let provider = snapshot.provider {
            markCodexAccountConfigurationCurrent(
                provider: provider,
                databricksProfile: snapshot.databricksProfile
            )
        } else {
            invalidateCodexAccountConfiguration()
        }
    }
}

extension AppSettings: CodexAccountConfigurationStoring {
    var codexAccountConfigurationSnapshot: CodexAccountConfigurationSnapshot {
        CodexAccountConfigurationSnapshot(
            provider: AIAccountProvider(rawValue: codexConfiguredAccountProviderRawValue),
            databricksProfile: codexConfiguredDatabricksProfile
        )
    }
}
