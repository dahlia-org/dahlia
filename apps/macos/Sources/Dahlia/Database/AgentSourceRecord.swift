import Foundation
import GRDB

/// Where the always-on agent reads: an MCP server, what to read there, how often, and how far it has read.
struct AgentSourceRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "agent_event_sources"
    var id: String
    var agentID: String
    var name: String
    var server: String
    var instructions: String
    var intervalMinutes: Int
    var allowedSenders: String
    var cursor: String?
    var enabled: Bool
    var lastIntakeAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var revision = 1
    var connectionID = ""
    var kind = "mcp"
    var lastReadCount = 0
    var lastRecordedCount = 0
    var dailyAt: String?
    var leadHours: Double?
}
