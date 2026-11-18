import Foundation

enum AgentLearningSettings {
    static let openThread = Notification.Name("DahliaAgentOpenThread")
    static func memoryKey(_ account: String) -> String { "agentMemoryEnabled.\(account)" }
    /// The single review switch before skill and memory organization were split; it seeds both new switches.
    static func legacyReviewKey(_ account: String) -> String { "agentAutoLearningEnabled.\(account)" }
    static func skillReviewKey(_ account: String) -> String { "agentSkillReviewEnabled.\(account)" }
    static func memoryReviewKey(_ account: String) -> String { "agentMemoryReviewEnabled.\(account)" }
    static func memoryEnabled(_ account: String) -> Bool { UserDefaults.standard.object(forKey: memoryKey(account)) as? Bool ?? true }
    static func legacyReviewEnabled(_ account: String) -> Bool {
        UserDefaults.standard.object(forKey: legacyReviewKey(account)) as? Bool ?? true
    }

    static func skillReviewEnabled(_ account: String) -> Bool {
        UserDefaults.standard.object(forKey: skillReviewKey(account)) as? Bool ?? legacyReviewEnabled(account)
    }

    /// Memory reviews also need memory itself.
    static func memoryReviewEnabled(_ account: String) -> Bool {
        memoryEnabled(account) && UserDefaults.standard.object(forKey: memoryReviewKey(account)) as? Bool ?? legacyReviewEnabled(account)
    }

    static func reviewEnabled(_ account: String) -> Bool { skillReviewEnabled(account) || memoryReviewEnabled(account) }
}

/// Hermes `curator:` settings and its `auxiliary.curator` model slot. Only `enabled`, `interval_hours`, `archive_after_days`,
/// `consolidate` and the model and effort are user settings; the others keep the upstream defaults.
/// `prune_builtins` does not apply: bundled and package skills are read-only.
enum SkillCuratorSettings {
    static let intervalChoices = [24, 72, 168, 336]
    static let archiveChoices = [14, 30, 60, 90]
    static let minIdleHours = 2.0
    static let staleAfterDays = 14
    static func enabledKey(_ account: String) -> String { "agentSkillCuratorEnabled.\(account)" }
    static func intervalKey(_ account: String) -> String { "agentSkillCuratorIntervalHours.\(account)" }
    static func archiveKey(_ account: String) -> String { "agentSkillCuratorArchiveAfterDays.\(account)" }
    static func consolidateKey(_ account: String) -> String { "agentSkillCuratorConsolidate.\(account)" }
    static func modelKey(_ account: String) -> String { "agentSkillCuratorModel.\(account)" }
    static func effortKey(_ account: String) -> String { "agentSkillCuratorEffort.\(account)" }
    /// Pi reference (`provider/id`). Empty is upstream `auto`: Pi's default model for the account.
    static func model(_ account: String) -> String { UserDefaults.standard.string(forKey: modelKey(account)) ?? "" }
    /// Empty is upstream's unset `reasoning_effort`: the default level.
    static func effort(_ account: String) -> String { UserDefaults.standard.string(forKey: effortKey(account)) ?? "" }
    static func enabled(_ account: String) -> Bool { UserDefaults.standard.object(forKey: enabledKey(account)) as? Bool ?? true }
    static func consolidate(_ account: String) -> Bool { UserDefaults.standard.bool(forKey: consolidateKey(account)) }
    static func intervalHours(_ account: String) -> Int { bounded(intervalKey(account), default: 168) }
    static func archiveAfterDays(_ account: String) -> Int { bounded(archiveKey(account), default: 30) }

    /// Like upstream, a count below 1 falls back to the default instead of archiving everything at once.
    private static func bounded(_ key: String, default value: Int) -> Int {
        let stored = UserDefaults.standard.integer(forKey: key)
        return stored >= 1 ? stored : value
    }
}
