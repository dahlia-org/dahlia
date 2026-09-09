import Foundation

/// Immutable LLM settings captured when a summary job starts.
struct SummaryGenerationSettings: Codable, Equatable, Sendable {
    let modelID: String?
    let reasoningEffort: String
    let detailLevelInstruction: String
    let languageDisplayName: String
    let runtimeProvider: CodexRuntimeProvider

    @MainActor
    static func current(
        _ settings: AppSettings = .shared,
        vaultAISettings: VaultAISettingsModel = .shared,
        detailLevel: SummaryDetailLevel? = nil
    ) -> Self {
        let usesVaultSettings = vaultAISettings.vaultID == settings.currentVault?.id
        let localProvider = usesVaultSettings
            ? vaultAISettings.localProvider
            : settings.configuredCodexAccountProvider ?? settings.codexAccountProvider
        let databricksProfile = usesVaultSettings
            ? vaultAISettings.databricksProfile
            : settings.codexDatabricksProfile
        return Self(
            modelID: usesVaultSettings
                ? vaultAISettings.summaryModelID.nilIfBlank
                : settings.codexModelID.nilIfBlank,
            reasoningEffort: usesVaultSettings
                ? vaultAISettings.summaryReasoningEffort
                : settings.codexReasoningEffort,
            detailLevelInstruction: (detailLevel ?? settings.summaryDetailLevel).instruction,
            languageDisplayName: ((usesVaultSettings ? vaultAISettings.accountConnectionID : nil).flatMap {
                ServerAccountSettingsModel.shared.state(for: $0).settings?.outputLanguage
            } ?? settings.llmSummaryLanguage).displayName,
            runtimeProvider: CodexRuntimeProvider(
                accountConnectionID: usesVaultSettings ? vaultAISettings.accountConnectionID : nil,
                localProvider: localProvider,
                databricksProfile: databricksProfile
            )
        )
    }

    func applying(detailLevel: SummaryDetailLevel?) -> Self {
        guard let detailLevel else { return self }
        return Self(
            modelID: modelID,
            reasoningEffort: reasoningEffort,
            detailLevelInstruction: detailLevel.instruction,
            languageDisplayName: languageDisplayName,
            runtimeProvider: runtimeProvider
        )
    }

    func applying(language: SummaryLanguage) -> Self {
        Self(
            modelID: modelID,
            reasoningEffort: reasoningEffort,
            detailLevelInstruction: detailLevelInstruction,
            languageDisplayName: language.displayName,
            runtimeProvider: runtimeProvider
        )
    }
}
