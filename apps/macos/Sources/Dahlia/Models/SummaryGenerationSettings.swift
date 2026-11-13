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
    var customInstructions: String?

    var sourceAccountConnectionID: UUID? { accountConnectionID }

    @MainActor
    static func current(
        _: AppSettings = .shared,
        workspaceAISettings: WorkspaceAISettingsModel = .shared,
        detailLevel: SummaryDetailLevel? = nil,
        workspace: WorkspaceRecord? = nil,
        defaults: UserDefaults = .standard
    ) -> Self {
        let preferences = workspace.map { workspaceAISettings.generationSettings(for: $0) }
            ?? WorkspaceGenerationSettings()
        return Self(
            modelID: preferences.local.model,
            reasoningEffort: preferences.local.reasoningEffort,
            detailLevelInstruction: (detailLevel ?? preferences.summary.detailLevel).instruction,
            languageDisplayName: preferences.outputLanguage.displayName,
            runtimeProvider: CodexRuntimeProvider(workspace: workspace),
            accountConnectionID: workspace?.accountConnectionId,
            workspaceID: workspace?.id,
            workspacePreferences: preferences,
            customInstructions: AgentChatInstructions.loadForSummary(for: CodexRuntimeProvider(workspace: workspace), defaults: defaults)
        )
    }

    func applying(detailLevel: SummaryDetailLevel?) -> Self {
        guard let detailLevel else { return self }
        return Self(
            modelID: modelID, reasoningEffort: reasoningEffort,
            detailLevelInstruction: detailLevel.instruction, languageDisplayName: languageDisplayName,
            runtimeProvider: runtimeProvider, accountConnectionID: accountConnectionID,
            workspaceID: workspaceID, workspacePreferences: workspacePreferences, customInstructions: customInstructions
        )
    }

    func applying(workspace: WorkspaceRecord? = nil, options: SummaryGenerationOptions) -> Self {
        let connectionID = workspace.map(\.accountConnectionId) ?? sourceAccountConnectionID
        let preferences = options.applying(
            to: workspacePreferences ?? workspace
                .map { AccountInferenceSettings(workspace: $0).generationSettings(outputLanguage: $0.generationSettings.outputLanguage) } ??
                WorkspaceGenerationSettings(),
            usesServer: false
        )
        return Self(
            modelID: preferences.local.model, reasoningEffort: preferences.local.reasoningEffort,
            detailLevelInstruction: preferences.summary.detailLevel.instruction,
            languageDisplayName: preferences.outputLanguage.displayName,
            runtimeProvider: runtimeProvider, accountConnectionID: connectionID,
            workspaceID: workspace?.id ?? workspaceID, workspacePreferences: preferences, customInstructions: customInstructions
        )
    }
}
