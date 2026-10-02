import Foundation

struct WorkspaceAISettingsSnapshot: Equatable, Sendable {
    let workspaceID: UUID
    var accountConnectionID: UUID?
    var localProvider: AIAccountProvider
    var databricksProfile: String
    var generationSettings: WorkspaceGenerationSettings
    var summaryModelID: String { generationSettings.local.model }
    var summaryReasoningEffort: String { generationSettings.local.reasoningEffort }
    var chatModelID: String
    var chatReasoningEffort: String

    func apply(to workspace: inout WorkspaceRecord) {
        workspace.accountConnectionId = accountConnectionID
        applyAISettings(to: &workspace)
    }

    func applyAISettings(to workspace: inout WorkspaceRecord) {
        workspace.generationSettings.outputLanguage = generationSettings.outputLanguage
        workspace.aiSettingsBackfilled = true
    }
}

extension WorkspaceAISettingsSnapshot {
    init(workspace: WorkspaceRecord, localAccountSettings: LocalAccountAISettings, defaults: UserDefaults = .standard) {
        let account = AccountInferenceSettings(workspace: workspace, defaults: defaults)
        workspaceID = workspace.id
        accountConnectionID = workspace.accountConnectionId
        localProvider = localAccountSettings.provider
        databricksProfile = localAccountSettings.databricksProfile
        generationSettings = account.generationSettings(outputLanguage: workspace.generationSettings.outputLanguage)
        chatModelID = account.chatModelID
        chatReasoningEffort = account.chatReasoningEffort
    }
}
