import Foundation

/// Immutable LLM settings captured when a summary job starts.
struct SummaryGenerationSettings: Equatable, Sendable {
    let modelID: String?
    let reasoningEffort: String
    let detailLevelInstruction: String
    let languageDisplayName: String

    @MainActor
    static func current(
        _ settings: AppSettings = .shared,
        vaultAISettings: VaultAISettingsModel = .shared,
        detailLevel: SummaryDetailLevel? = nil
    ) -> Self {
        let usesVaultSettings = vaultAISettings.vaultID == settings.currentVault?.id
        return Self(
            modelID: usesVaultSettings
                ? vaultAISettings.summaryModelID.nilIfBlank
                : settings.codexModelID.nilIfBlank,
            reasoningEffort: usesVaultSettings
                ? vaultAISettings.summaryReasoningEffort
                : settings.codexReasoningEffort,
            detailLevelInstruction: (detailLevel ?? settings.summaryDetailLevel).instruction,
            languageDisplayName: settings.llmSummaryLanguage.displayName
        )
    }
}
