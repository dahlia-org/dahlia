import Foundation
import GRDB

/// One unattended run of a system task (the skill Curator, a review). Kept apart from chat threads, with its own retention.
struct AgentSystemRunRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "agent_system_runs"
    var id: String
    var accountID: String
    var task: String
    var status: String
    var summary: String
    var report: String
    var startedAt: Date
    var finishedAt: Date?

    /// Keeps the newest run of each task: the Curator's interval is measured from it.
    static func deleteExpired(_ db: Database, before cutoff: Date) throws {
        try db.execute(sql: """
        DELETE FROM agent_system_runs WHERE startedAt < ? AND status <> 'running' AND id NOT IN (
            SELECT id FROM (SELECT id, ROW_NUMBER() OVER (PARTITION BY accountID, task ORDER BY startedAt DESC, id DESC) AS n
            FROM agent_system_runs) WHERE n = 1
        )
        """, arguments: [cutoff])
    }
}
