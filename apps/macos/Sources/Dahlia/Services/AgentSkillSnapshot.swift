import Foundation

struct AgentSkillSnapshot: Codable, Equatable, Sendable {
    var files: [String: String] = [:]
    var modes: [String: Int] = [:]
}
