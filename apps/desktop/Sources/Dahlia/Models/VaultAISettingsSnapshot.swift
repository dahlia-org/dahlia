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
        vault.localProvider = localProvider
        vault.databricksProfile = databricksProfile
        vault.summaryModelID = summaryModelID
        vault.summaryReasoningEffort = summaryReasoningEffort
        vault.chatModelID = chatModelID
        vault.chatReasoningEffort = chatReasoningEffort
        vault.aiSettingsBackfilled = true
    }
}

extension VaultAISettingsSnapshot {
    init(vault: VaultRecord) {
        vaultID = vault.id
        accountConnectionID = vault.accountConnectionId
        localProvider = vault.localProvider
        databricksProfile = vault.databricksProfile
        summaryModelID = vault.summaryModelID
        summaryReasoningEffort = vault.summaryReasoningEffort
        chatModelID = vault.chatModelID
        chatReasoningEffort = vault.chatReasoningEffort
    }
}
