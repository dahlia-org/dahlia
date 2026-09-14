import Foundation

/// Immutable LLM settings captured when a summary job starts.
struct SummaryGenerationSettings: Codable, Equatable, Sendable {
    let modelID: String?
    let reasoningEffort: String
    let detailLevelInstruction: String
    let languageDisplayName: String
    let runtimeProvider: CodexRuntimeProvider
    var accountConnectionID: UUID?
    var workspaceID: UUID?
    var workspacePreferences: WorkspaceGenerationSettings?

    var sourceAccountConnectionID: UUID? { accountConnectionID ?? runtimeProvider.accountConnectionID }

    @MainActor
    static func current(
        _: AppSettings = .shared,
        workspaceAISettings: WorkspaceAISettingsModel = .shared,
        detailLevel: SummaryDetailLevel? = nil,
        workspace: WorkspaceRecord? = nil
    ) -> Self {
        let preferences = workspace?.generationSettings ?? WorkspaceGenerationSettings()
        return Self(
            modelID: preferences.local.model,
            reasoningEffort: preferences.local.reasoningEffort,
            detailLevelInstruction: (detailLevel ?? preferences.summary.detailLevel).instruction,
            languageDisplayName: preferences.outputLanguage.displayName,
            runtimeProvider: CodexRuntimeProvider(
                accountConnectionID: nil,
                localProvider: workspaceAISettings.localProvider,
                databricksProfile: workspaceAISettings.databricksProfile
            ),
            accountConnectionID: workspace?.accountConnectionId,
            workspaceID: workspace?.id,
            workspacePreferences: workspace?.generationSettings
        )
    }

    func applying(detailLevel: SummaryDetailLevel?) -> Self {
        guard let detailLevel else { return self }
        return Self(
            modelID: modelID, reasoningEffort: reasoningEffort,
            detailLevelInstruction: detailLevel.instruction, languageDisplayName: languageDisplayName,
            runtimeProvider: runtimeProvider, accountConnectionID: accountConnectionID,
            workspaceID: workspaceID, workspacePreferences: workspacePreferences
        )
    }

    func applying(workspace: WorkspaceRecord, options: SummaryGenerationOptions) -> Self {
        let preferences = options.applying(to: workspace.generationSettings)
        return Self(
            modelID: preferences.local.model, reasoningEffort: preferences.local.reasoningEffort,
            detailLevelInstruction: preferences.summary.detailLevel.instruction,
            languageDisplayName: preferences.outputLanguage.displayName,
            runtimeProvider: runtimeProvider, accountConnectionID: workspace.accountConnectionId,
            workspaceID: workspace.id, workspacePreferences: preferences
        )
    }
}
