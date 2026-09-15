struct WorkspaceAISettingsLegacyValues: Equatable, Sendable {
    let chatModelID: String
    let chatReasoningEffort: String

    func apply(to workspace: inout WorkspaceRecord) {
        workspace.chatModelID = chatModelID
        workspace.chatReasoningEffort = chatReasoningEffort
    }
}

extension WorkspaceAISettingsLegacyValues {
    @MainActor
    init(settings: AppSettings) {
        self.init(
            chatModelID: settings.codexChatModelID,
            chatReasoningEffort: settings.codexChatReasoningEffort
        )
    }
}
