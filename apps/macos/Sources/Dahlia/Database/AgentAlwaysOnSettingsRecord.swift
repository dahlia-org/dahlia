import Foundation
import GRDB

/// The account's always-on agent switch: paused stops every new run and every external write.
struct AgentAlwaysOnSettingsRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "agent_always_on_settings"
    var accountID: String
    var paused: Bool
}
