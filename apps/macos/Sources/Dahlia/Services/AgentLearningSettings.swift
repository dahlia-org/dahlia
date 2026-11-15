import Foundation

enum AgentLearningSettings {
    static let openThread = Notification.Name("DahliaAgentOpenThread")
    static func memoryKey(_ account: String) -> String { "agentMemoryEnabled.\(account)" }
    static func reviewKey(_ account: String) -> String { "agentAutoLearningEnabled.\(account)" }
    static func memoryEnabled(_ account: String) -> Bool { UserDefaults.standard.object(forKey: memoryKey(account)) as? Bool ?? true }
    static func reviewEnabled(_ account: String) -> Bool { UserDefaults.standard.object(forKey: reviewKey(account)) as? Bool ?? true }
}
