import Foundation

/// Dahlia Bot's standing settings, kept on this Mac for each account. Only the user edits them in Settings; the Router
/// and Workers read them and have no tool that changes them.
enum AgentBotSettings {
    static let guidanceLimit = 8000

    static func remove(accountKey: String, defaults: UserDefaults = .standard) {
        for prefix in ["botGuidance", "botWorkServers", "botWebSearch", "botHomeThread"] {
            defaults.removeObject(forKey: "\(prefix).\(accountKey)")
        }
    }

    static func guidanceKey(for account: CodexRuntimeProvider) -> String { "botGuidance.\(account.accountKey)" }
    static func workServersKey(for account: CodexRuntimeProvider) -> String { "botWorkServers.\(account.accountKey)" }
    static func webSearchKey(for account: CodexRuntimeProvider) -> String { "botWebSearch.\(account.accountKey)" }
    static func homeThreadKey(for account: CodexRuntimeProvider) -> String { homeThreadKey(accountKey: account.accountKey) }
    static func homeThreadKey(accountKey: String) -> String { "botHomeThread.\(accountKey)" }

    /// The Thread where the user talks with their secretary.
    static func homeThread(for account: CodexRuntimeProvider, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: homeThreadKey(for: account))
    }

    /// The user's guidance for their secretary (Orca's `SOUL.md`): whom to put first, tone, what never to do, quiet hours.
    static func guidance(for account: CodexRuntimeProvider, defaults: UserDefaults = .standard) -> String {
        String((defaults.string(forKey: guidanceKey(for: account)) ?? "").prefix(guidanceLimit))
    }

    /// Stable connection IDs a Worker may read for work the user asked for, besides the Source an event came from.
    static func workServers(for account: CodexRuntimeProvider, defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: workServersKey(for: account)) ?? []
    }

    /// Web search for Workers. Queries leave the Mac, so it is off until the user turns it on.
    static func webSearch(for account: CodexRuntimeProvider, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: webSearchKey(for: account))
    }
}
