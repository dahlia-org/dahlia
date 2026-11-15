import Foundation

struct AgentSkillSnapshot: Codable, Equatable, Sendable {
    var files: [String: Data] = [:]
    var modes: [String: Int] = [:]
}
