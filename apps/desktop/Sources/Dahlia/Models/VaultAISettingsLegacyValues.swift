struct VaultAISettingsLegacyValues: Equatable, Sendable {
    let localProvider: AIAccountProvider
    let databricksProfile: String
    let summaryModelID: String
    let summaryReasoningEffort: String
    let chatModelID: String
    let chatReasoningEffort: String

    func apply(to vault: inout VaultRecord) {
        vault.localProvider = localProvider
        vault.databricksProfile = databricksProfile
        vault.summaryModelID = summaryModelID
        vault.summaryReasoningEffort = summaryReasoningEffort
        vault.chatModelID = chatModelID
        vault.chatReasoningEffort = chatReasoningEffort
    }
}

extension VaultAISettingsLegacyValues {
    @MainActor
    init(settings: AppSettings) {
        self.init(
            localProvider: settings.codexAccountProvider,
            databricksProfile: settings.codexDatabricksProfile,
            summaryModelID: settings.codexModelID,
            summaryReasoningEffort: settings.codexReasoningEffort,
            chatModelID: settings.codexChatModelID,
            chatReasoningEffort: settings.codexChatReasoningEffort
        )
    }
}
