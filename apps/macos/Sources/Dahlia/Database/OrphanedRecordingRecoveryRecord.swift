import Foundation
import GRDB

/// Private startup state; never copied as portable workspace content.
struct OrphanedRecordingRecoveryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "orphaned_recording_recoveries"

    var workspaceId: UUID

    static func createTableIfNeeded(in db: Database) throws {
        try db.create(table: databaseTableName, ifNotExists: true) { table in
            // The parent changes from vaults to workspaces during historical migrations.
            // Keep this checkpoint independent of their rebuilds; finish validates ownership.
            table.primaryKey("workspaceId", .blob).notNull()
        }
    }
}
