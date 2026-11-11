import Foundation

/// An empty selection follows the model of each chat; explicit reviewer models belong to the execution account.
enum AgentAutoReviewSettings {
    static func defaultsKey(for account: CodexRuntimeProvider) -> String {
        "autoReviewModel.\(account.accountKey)"
    }

    static func model(for account: CodexRuntimeProvider, defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: defaultsKey(for: account)) ?? ""
    }
}
