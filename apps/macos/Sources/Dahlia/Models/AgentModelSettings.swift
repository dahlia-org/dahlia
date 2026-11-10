import Foundation

/// The Unity AI Gateway models an account turned on or off in Agents settings, by Pi reference (`provider/id`), kept in
/// app defaults. A model without a choice takes its default (`PiProviderConfiguration.DatabricksModel.isOnByDefault`): off,
/// except the one model a Databricks account's own gateway starts with.
enum AgentModelSettings {
    static func defaultsKey(for account: CodexRuntimeProvider) -> String {
        "agentGatewayModels.\(account.accountKey)"
    }

    static func choices(for account: CodexRuntimeProvider, defaults: UserDefaults = .standard) -> [String: Bool] {
        defaults.dictionary(forKey: defaultsKey(for: account)) as? [String: Bool] ?? [:]
    }

    static func setModel(_ reference: String, on: Bool, for account: CodexRuntimeProvider, defaults: UserDefaults = .standard) {
        var choices = choices(for: account, defaults: defaults)
        choices[reference] = on
        defaults.set(choices, forKey: defaultsKey(for: account))
    }
}
