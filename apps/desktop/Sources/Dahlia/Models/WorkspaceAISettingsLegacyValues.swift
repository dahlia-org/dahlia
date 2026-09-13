struct WorkspaceAISettingsLegacyValues: Equatable, Sendable {
    let localProvider: AIAccountProvider
    let databricksProfile: String
    let summaryModelID: String
    let summaryReasoningEffort: String
    let chatModelID: String
    let chatReasoningEffort: String

    func apply(to workspace: inout WorkspaceRecord) {
        workspace.localProvider = localProvider
        workspace.databricksProfile = databricksProfile
        workspace.summaryModelID = summaryModelID
        workspace.summaryReasoningEffort = summaryReasoningEffort
        workspace.chatModelID = chatModelID
        workspace.chatReasoningEffort = chatReasoningEffort
    }
}

extension WorkspaceAISettingsLegacyValues {
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
