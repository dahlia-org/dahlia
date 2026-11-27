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
    /// `mail`, `slack`, or empty for another MCP server and the calendar. Fixed when the Source is created.
    var service = ""
    /// `AgentSourceOptions` as JSON.
    var options = "{}"

    var sourceOptions: AgentSourceOptions {
        get { (try? JSONDecoder().decode(AgentSourceOptions.self, from: Data(options.utf8))) ?? .init() }
        set {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            options = String(decoding: (try? encoder.encode(newValue)) ?? Data("{}".utf8), as: UTF8.self)
        }
    }

    /// Reading channels the user has not joined needs channels or notes to say which, or it has no bound.
    var lacksSlackChannels: Bool {
        service == "slack" && sourceOptions.slackScope == .all && (sourceOptions.includeChannels ?? []).isEmpty
            && instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A Source's per-service choices. A missing value narrows nothing.
struct AgentSourceOptions: Codable, Equatable, Sendable {
    enum SlackScope: String, Codable, CaseIterable, Sendable {
        case mentions, joined, all
    }

    /// Mail: only mail with the user in To or Cc, not mail through a list or group.
    var addressedOnly: Bool?
    /// Mail: sender domains, lowercased and without `@`. A sender matches its domain or a subdomain of it.
    var allowedDomains: [String]?
    var slackScope: SlackScope?
    /// Slack channel names without `#`.
    var includeChannels: [String]?
    var excludeChannels: [String]?
    /// Calendar: the weekly check's time (`HH:mm`) and its weekday (1 is Sunday, as `Calendar`).
    var weeklyAt: String?
    var weekday: Int?
    /// Calendar: only meetings the user accepted, organizes, or has alone.
    var acceptedOnly: Bool?
}
