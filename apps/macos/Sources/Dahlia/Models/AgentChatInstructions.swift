import Foundation

/// Custom instruction preferences stay on this Mac, separately for each execution account.
enum AgentChatInstructions {
    static func defaultsKey() -> String {
        "chatCustomInstructions.\(AppAccount.key)"
    }

    static func summaryEnabledKey() -> String {
        "summaryCustomInstructionsEnabled.\(AppAccount.key)"
    }

    static func loadForSummary(defaults: UserDefaults = .standard) -> String? {
        guard defaults.bool(forKey: summaryEnabledKey()) else { return nil }
        return load(defaults: defaults).nilIfBlank
    }

    static func load(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: defaultsKey()) ?? ""
    }
}
