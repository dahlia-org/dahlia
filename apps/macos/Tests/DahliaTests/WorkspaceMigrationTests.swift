import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct WorkspaceMigrationTests {
        @Test
        func publishedDatabaseMovesToWorkspacesWithoutChangingIdentityOrContent() throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v41_vaultAISettingsBackfill")
            let workspaceID = UUID.v7()
            let meetingID = UUID.v7()
            try queue.write { db in
                try db.execute(
                    sql: "INSERT INTO vaults (id, path, name, createdAt, lastOpenedAt) VALUES (?, '/tmp/unchanged-vault', 'Vault literal', ?, ?)",
                    arguments: [workspaceID, Date.now, Date.now]
                )
                try db.execute(
                    sql: "INSERT INTO meetings (id, vaultId, name, createdAt, updatedAt) VALUES (?, ?, 'Unchanged meeting', ?, ?)",
                    arguments: [meetingID, workspaceID, Date.now, Date.now]
                )
            }
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.read { db in
                #expect(try !db.tableExists("vaults"))
                #expect(try db.tableExists("workspaces"))
                #expect(try db.columns(in: "meetings").contains { $0.name == "workspace_id" })
                #expect(try !db.columns(in: "meetings").contains { $0.name == "vaultId" })
                let workspace = try #require(try WorkspaceRecord.fetchOne(db, key: workspaceID))
                #expect(workspace.name == "Vault literal")
                #expect(workspace.path == "/tmp/unchanged-vault")
                let meeting = try #require(try MeetingRecord.fetchOne(db, key: meetingID))
                #expect(meeting.workspaceId == workspaceID)
                #expect(meeting.name == "Unchanged meeting")
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }

        @Test
        func failedUnpublishedMigrationRollsBackAndCanBeRetried() throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v41_vaultAISettingsBackfill")
            let id = UUID.v7()
            try queue.write { db in
                try db.execute(
                    sql: "INSERT INTO vaults (id, path, name, createdAt, lastOpenedAt) VALUES (?, '/tmp/preserved', 'Preserved', ?, ?)",
                    arguments: [id, Date.now, Date.now]
                )
                try db.execute(sql: "CREATE TABLE workspaces (id BLOB)")
            }
            #expect(throws: (any Error).self) { try AppDatabaseManager.migrator.migrate(queue) }
            try queue.write { db in
                #expect(try String.fetchOne(db, sql: "SELECT name FROM vaults WHERE id = ?", arguments: [id]) == "Preserved")
                #expect(try AppDatabaseManager.migrator.completedMigrations(db).last == "v41_vaultAISettingsBackfill")
                try db.execute(sql: "DROP TABLE workspaces")
            }
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.read { db in
                let workspace = try WorkspaceRecord.fetchOne(db, key: id)
                #expect(workspace?.name == "Preserved")
            }
        }

    }
#endif
