import Foundation

/// Chat preferences stay on this Mac, separately for each execution account.
enum AgentChatInstructions {
    static func defaultsKey(for account: CodexRuntimeProvider) -> String {
        "chatCustomInstructions.\(account.accountKey)"
    }

    static func load(for account: CodexRuntimeProvider, defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: defaultsKey(for: account)) ?? ""
    }
}
