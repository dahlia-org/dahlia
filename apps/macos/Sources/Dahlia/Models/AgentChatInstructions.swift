import Foundation

/// Custom instruction preferences stay on this Mac, separately for each execution account.
enum AgentChatInstructions {
    static func defaultsKey(for account: CodexRuntimeProvider) -> String {
        "chatCustomInstructions.\(account.accountKey)"
    }

    static func summaryEnabledKey(for account: CodexRuntimeProvider) -> String {
        "summaryCustomInstructionsEnabled.\(account.accountKey)"
    }

    static func loadForSummary(for account: CodexRuntimeProvider, defaults: UserDefaults = .standard) -> String? {
        guard defaults.bool(forKey: summaryEnabledKey(for: account)) else { return nil }
        return load(for: account, defaults: defaults).nilIfBlank
    }

    static func load(for account: CodexRuntimeProvider, defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: defaultsKey(for: account)) ?? ""
    }
}
