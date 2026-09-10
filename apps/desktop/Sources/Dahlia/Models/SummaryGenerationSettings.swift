import Foundation

/// Immutable LLM settings captured when a summary job starts.
struct SummaryGenerationSettings: Codable, Equatable, Sendable {
    let modelID: String?
    let reasoningEffort: String
    let detailLevelInstruction: String
    let languageDisplayName: String
    let runtimeProvider: CodexRuntimeProvider
    var accountConnectionID: UUID?

    var sourceAccountConnectionID: UUID? { accountConnectionID ?? runtimeProvider.accountConnectionID }

    @MainActor
    static func current(
        _ settings: AppSettings = .shared,
        vaultAISettings: VaultAISettingsModel = .shared,
        detailLevel: SummaryDetailLevel? = nil,
        accountSettings: ServerAccountSettings? = nil
    ) -> Self {
        let account = accountSettings ?? settings.currentVault?.accountConnectionId.flatMap {
            ServerAccountSettingsModel.shared.state(for: $0).settings
        }
        return Self(
            modelID: settings.codexModelID.nilIfBlank,
            reasoningEffort: settings.codexReasoningEffort,
            detailLevelInstruction: (detailLevel ?? account?.summary?.detailLevel ?? settings.summaryDetailLevel).instruction,
            languageDisplayName: (account?.outputLanguage ?? settings.llmSummaryLanguage).displayName,
            runtimeProvider: CodexRuntimeProvider(
                accountConnectionID: nil,
                localProvider: vaultAISettings.localProvider,
                databricksProfile: vaultAISettings.databricksProfile
            ),
            accountConnectionID: settings.currentVault?.accountConnectionId
        )
    }

    func applying(detailLevel: SummaryDetailLevel?) -> Self {
        guard let detailLevel else { return self }
        return Self(
            modelID: modelID,
            reasoningEffort: reasoningEffort,
            detailLevelInstruction: detailLevel.instruction,
            languageDisplayName: languageDisplayName,
            runtimeProvider: runtimeProvider,
            accountConnectionID: accountConnectionID
        )
    }

    func applying(accountSettings: ServerAccountSettings, connectionID: UUID, detailLevel: SummaryDetailLevel?) -> Self {
        Self(
            modelID: modelID,
            reasoningEffort: reasoningEffort,
            detailLevelInstruction: (detailLevel ?? accountSettings.summary?.detailLevel)?.instruction ?? detailLevelInstruction,
            languageDisplayName: accountSettings.outputLanguage.displayName,
            runtimeProvider: runtimeProvider,
            accountConnectionID: connectionID
        )
    }

}
