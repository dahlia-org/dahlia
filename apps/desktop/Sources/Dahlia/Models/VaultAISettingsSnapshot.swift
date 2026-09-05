import Foundation

struct VaultAISettingsSnapshot: Equatable, Sendable {
    let vaultID: UUID
    var accountConnectionID: UUID?
    var localProvider: AIAccountProvider
    var databricksProfile: String
    var summaryModelID: String
    var summaryReasoningEffort: String
    var chatModelID: String
    var chatReasoningEffort: String

    func apply(to vault: inout VaultRecord) {
        vault.accountConnectionId = accountConnectionID
        applyAISettings(to: &vault)
    }

    func applyAISettings(to vault: inout VaultRecord) {
        vault.summaryModelID = summaryModelID
        vault.summaryReasoningEffort = summaryReasoningEffort
        vault.chatModelID = chatModelID
        vault.chatReasoningEffort = chatReasoningEffort
        vault.aiSettingsBackfilled = true
    }
}

extension VaultAISettingsSnapshot {
    init(vault: VaultRecord, localAccountSettings: LocalAccountAISettings) {
        vaultID = vault.id
        accountConnectionID = vault.accountConnectionId
        localProvider = localAccountSettings.provider
        databricksProfile = localAccountSettings.databricksProfile
        summaryModelID = vault.summaryModelID
        summaryReasoningEffort = vault.summaryReasoningEffort
        chatModelID = vault.chatModelID
        chatReasoningEffort = vault.chatReasoningEffort
    }
}
