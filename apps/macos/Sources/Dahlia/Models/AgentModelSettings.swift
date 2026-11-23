import Foundation

/// Model visibility choices in Dahlia, by Pi reference (`provider/id`), kept in account-local app defaults.
enum AgentModelSettings {
    static func isSubscriptionModelOn(_ reference: String, choices: [String: Bool]) -> Bool {
        choices[reference] ?? [
            "anthropic/claude-opus-5-5", "anthropic/claude-sonnet-5-5", "anthropic/claude-haiku-5-5",
            "openai/gpt-6.1-sol", "openai/gpt-6.1-terra", "openai/gpt-6-luna",
        ].contains(reference)
    }

    static func defaultsKey() -> String {
        "agentGatewayModels.\(AppAccount.key)"
    }

    static func choices(defaults: UserDefaults = .standard) -> [String: Bool] {
        defaults.dictionary(forKey: defaultsKey()) as? [String: Bool] ?? [:]
    }

    static func setModel(_ reference: String, on: Bool, defaults: UserDefaults = .standard) {
        var choices = choices(defaults: defaults)
        choices[reference] = on
        defaults.set(choices, forKey: defaultsKey())
    }
}
