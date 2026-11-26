import DahliaRuntimeSupport
import Foundation

/// Super Agent's settings kept on this Mac for the account. Its guidance itself is `SOUL.md` in its home (`DahliaBotHome`).
enum AgentBotSettings {
    static let guidanceLimit = 8000

    static func remove(accountKey: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: guidanceKey(for: accountKey))
        defaults.removeObject(forKey: botThreadKey(for: accountKey))
        defaults.removeObject(forKey: intakeModelKey(for: accountKey))
        defaults.removeObject(forKey: unattendedModelKey(for: accountKey))
        defaults.removeObject(forKey: intakeEffortKey(for: accountKey))
        defaults.removeObject(forKey: unattendedEffortKey(for: accountKey))
    }

    /// The model intake reads event sources with; unset, Pi's default model.
    static func intakeModelKey(for account: String) -> String { "botIntakeModel.\(account)" }
    /// The model of Super Agent's turns that start without the user (event notices, results of its tasks); unset, its conversation's.
    static func unattendedModelKey(for account: String) -> String { "botUnattendedModel.\(account)" }

    /// Their reasoning efforts; unset, Pi's default for intake and the conversation's for unattended turns.
    static func intakeEffortKey(for account: String) -> String { "botIntakeEffort.\(account)" }
    static func unattendedEffortKey(for account: String) -> String { "botUnattendedEffort.\(account)" }

    static func model(_ key: String, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key)?.nilIfBlank
    }

    /// A chosen model and its effort, which the settings pick as one: with no model chosen, both follow the default.
    static func choice(model modelKey: String, effort effortKey: String, defaults: UserDefaults = .standard)
        -> (model: String, effort: String?)? {
        model(modelKey, defaults: defaults).map { ($0, model(effortKey, defaults: defaults)) }
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
