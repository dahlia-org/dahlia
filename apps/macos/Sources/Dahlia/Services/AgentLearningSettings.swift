import Foundation

enum AgentLearningSettings {
    static let openThread = Notification.Name("DahliaAgentOpenThread")
    /// Opens a new chat and sends the notification's object (a prompt string) in it.
    static let sendChat = Notification.Name("DahliaAgentSendChat")
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

    /// Upstream `memory.nudge_interval` (user turns) and `skills.creation_nudge_interval` (tool-calling responses), default 10.
    static let reviewIntervalChoices = [5, 10, 20, 50]
    static func memoryIntervalKey(_ account: String) -> String { "agentMemoryReviewInterval.\(account)" }
    static func skillIntervalKey(_ account: String) -> String { "agentSkillReviewInterval.\(account)" }
    static func memoryInterval(_ account: String) -> Int { interval(memoryIntervalKey(account)) }
    static func skillInterval(_ account: String) -> Int { interval(skillIntervalKey(account)) }

    enum ReviewKind: String, CaseIterable, Sendable { case memory, skill }

    /// Each review has its own account-local model and reasoning level, independent of chat selections.
    static func reviewModelKey(_ account: String, kind: ReviewKind) -> String { "agentReviewModel.\(kind.rawValue).\(account)" }
    static func reviewEffortKey(_ account: String, kind: ReviewKind) -> String { "agentReviewEffort.\(kind.rawValue).\(account)" }
    static func reviewModel(_ account: String, kind: ReviewKind) -> String {
        UserDefaults.standard.string(forKey: reviewModelKey(account, kind: kind))
            ?? UserDefaults.standard.string(forKey: "agentReviewModel.\(account)") ?? ""
    }

    static func reviewEffort(_ account: String, kind: ReviewKind) -> String {
        (UserDefaults.standard.string(forKey: reviewEffortKey(account, kind: kind))
            ?? UserDefaults.standard.string(forKey: "agentReviewEffort.\(account)"))?.nilIfBlank ?? CodexReasoningEffortOption.defaultValue
    }

    /// Pick once from this account's catalog, then persist it. A later chat-model change cannot affect the selection.
    @discardableResult
    static func prepareReviewModel(_ account: String, kind: ReviewKind, models: [CodexModel]) -> String? {
        let saved = reviewModel(account, kind: kind)
        if !saved.isEmpty { return saved }
        let visible = models.filter { !$0.hidden }
        let selected = PiRuntimeService.ownProvidersFirst(visible) { candidates in
            ["claude-haiku-5-5", "gpt-6-luna"].lazy.compactMap { PiRuntimeService.matchingModel($0, in: candidates) }.first ?? candidates.first
        }
        guard let selected else { return nil }
        UserDefaults.standard.set(selected.model, forKey: reviewModelKey(account, kind: kind))
        return selected.model
    }

    private static func interval(_ key: String) -> Int {
        let stored = UserDefaults.standard.integer(forKey: key)
        return stored >= 1 ? stored : 10
    }
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
