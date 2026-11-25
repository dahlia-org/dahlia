import Foundation
import GRDB

/// Where the always-on agent reads: an MCP server, what to read there, how often, and how far it has read.
struct AgentSourceRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "agent_event_sources"
    var id: String
    var accountID: String
    var name: String
    var server: String
    var instructions: String
    var intervalMinutes: Int
    var sieve: String
    var allowedSenders: String
    var cursor: String?
    var enabled: Bool
    var gapDetectedAt: Date?
    var lastIntakeAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var revision = 1
    var connectionID = ""
}
