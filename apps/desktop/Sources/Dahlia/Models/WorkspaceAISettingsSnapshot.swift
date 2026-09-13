import Foundation

struct WorkspaceAISettingsSnapshot: Equatable, Sendable {
    let workspaceID: UUID
    var accountConnectionID: UUID?
    var localProvider: AIAccountProvider
    var databricksProfile: String
    var summaryModelID: String
    var summaryReasoningEffort: String
    var chatModelID: String
    var chatReasoningEffort: String

    func apply(to workspace: inout WorkspaceRecord) {
        workspace.accountConnectionId = accountConnectionID
        applyAISettings(to: &workspace)
    }

    func applyAISettings(to workspace: inout WorkspaceRecord) {
        workspace.summaryModelID = summaryModelID
        workspace.summaryReasoningEffort = summaryReasoningEffort
        workspace.chatModelID = chatModelID
        workspace.chatReasoningEffort = chatReasoningEffort
        workspace.aiSettingsBackfilled = true
    }
}

extension WorkspaceAISettingsSnapshot {
    init(workspace: WorkspaceRecord, localAccountSettings: LocalAccountAISettings) {
        workspaceID = workspace.id
        accountConnectionID = workspace.accountConnectionId
        localProvider = localAccountSettings.provider
        databricksProfile = localAccountSettings.databricksProfile
        summaryModelID = workspace.summaryModelID
        summaryReasoningEffort = workspace.summaryReasoningEffort
        chatModelID = workspace.chatModelID
        chatReasoningEffort = workspace.chatReasoningEffort
    }
}
