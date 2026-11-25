import DahliaRuntimeSupport
import Foundation

/// Super Agent's settings kept on this Mac for the account. Its guidance itself is `SOUL.md` in its home (`DahliaBotHome`).
enum AgentBotSettings {
    static let guidanceLimit = 8000

    static func remove(accountKey: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: guidanceKey(for: accountKey))
        defaults.removeObject(forKey: botThreadKey(for: accountKey))
    }

    /// Where the guidance was kept before `SOUL.md`; `DahliaBotHome.ensure` moves it there once.
    static func guidanceKey(for account: String) -> String { "botGuidance.\(account)" }
    private static let threadScope = DahliaApplicationSupport.currentDirectoryURL.standardizedFileURL.resolvingSymlinksInPath().path

    /// Development worktrees and the released app share defaults, but each owns a different database.
    static func botThreadKey(for account: String, dataDirectory: URL? = nil) -> String {
        let scope = dataDirectory?.standardizedFileURL.resolvingSymlinksInPath().path ?? threadScope
        return "botThread.\(account).\(scope)"
    }

    static func legacyBotThreadKey(for account: String) -> String { "botThread.\(account)" }

    /// Dahlia Bot's one current thread, where the user talks with it and it routes events.
    static func botThread(for account: String, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: botThreadKey(for: account))
    }
}
