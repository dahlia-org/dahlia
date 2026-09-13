#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct WorkspacePathMigrationTests {
        @Test
        func v42MakesWorkspacePathOptionalWithoutLosingExistingRelationships() throws {
            let queue = try DatabaseQueue(path: ":memory:", configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v41_vaultAISettingsBackfill")
            let firstWorkspace = UUID.v7()
            let secondWorkspace = UUID.v7()
            let project = UUID.v7()
            let meeting = UUID.v7()
            try queue.write { db in
                try db.execute(
                    sql: "INSERT INTO vaults (id, path, name, createdAt, lastOpenedAt) VALUES (?, ?, 'First', ?, ?)",
                    arguments: [firstWorkspace, "/tmp/first", Date.now, Date.now]
                )
                try db.execute(
                    sql: "INSERT INTO projects(id, vaultId, name, nameKey, createdAt, projectType) VALUES (?, ?, 'Project', 'project', ?, 'undefined')",
                    arguments: [project, firstWorkspace, Date.now]
                )
                try db.execute(
                    sql: "INSERT INTO meetings(id, vaultId, projectId, name, status, duration, createdAt, updatedAt) VALUES (?, ?, ?, 'Meeting', 'READY', 0, ?, ?)",
                    arguments: [meeting, firstWorkspace, project, Date.now, Date.now]
                )
            }

            try AppDatabaseManager.migrator.migrate(queue)

            try queue.write { db in
                try WorkspaceRecord(
                    id: secondWorkspace, path: nil, name: "Second",
                    createdAt: .now, lastOpenedAt: .distantPast
                ).insert(db)
            }
            let result = try queue.read { db in
                try (
                    WorkspaceRecord.fetchOne(db, key: firstWorkspace),
                    WorkspaceRecord.fetchOne(db, key: secondWorkspace),
                    ProjectRecord.fetchOne(db, key: project),
                    MeetingRecord.fetchOne(db, key: meeting),
                    Row.fetchOne(db, sql: "PRAGMA foreign_key_check")
                )
            }
            #expect(result.0?.path == "/tmp/first")
            #expect(result.1?.path == nil)
            #expect(result.2?.workspaceId == firstWorkspace)
            #expect(result.3?.projectId == project)
            #expect(result.4 == nil)

            _ = try queue.write { db in
                try WorkspaceRecord.deleteOne(db, key: firstWorkspace)
            }
            let cleanupJob = try queue.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT targetKind, targetKey FROM jobs_search_index WHERE targetKind = 'workspaceCleanup'"
                )
            }
            #expect(cleanupJob?["targetKind"] as String? == "workspaceCleanup")
            #expect(cleanupJob?["targetKey"] as UUID? == firstWorkspace)
        }
    }
#endif
