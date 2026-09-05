import Foundation

struct LocalAccountAISettings: Equatable, Sendable {
    static let providerKey = "codexAccountProvider"
    static let databricksProfileKey = "llmDatabricksProfile"
    static let migrationKey = "localAccountAISettingsMigrated"

    var provider: AIAccountProvider
    var databricksProfile: String

    init(provider: AIAccountProvider, databricksProfile: String) {
        self.provider = provider
        self.databricksProfile = databricksProfile
    }

    init(defaults: UserDefaults) {
        provider = defaults.string(forKey: Self.providerKey)
            .flatMap(AIAccountProvider.init(rawValue:)) ?? .chatGPTSubscription
        databricksProfile = defaults.string(forKey: Self.databricksProfileKey) ?? ""
    }

    func save(to defaults: UserDefaults) {
        defaults.set(provider.rawValue, forKey: Self.providerKey)
        defaults.set(databricksProfile, forKey: Self.databricksProfileKey)
        defaults.set(true, forKey: Self.migrationKey)
    }
}
