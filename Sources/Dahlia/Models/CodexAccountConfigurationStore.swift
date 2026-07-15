@MainActor
protocol CodexAccountConfigurationStoring: AnyObject {
    func invalidateCodexAccountConfiguration()
    func markCodexAccountConfigurationCurrent(
        provider: AIAccountProvider,
        databricksProfile: String
    )
}

extension AppSettings: CodexAccountConfigurationStoring {}
