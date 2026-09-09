#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct VaultPathMigrationTests {
        @Test
        func v42MakesVaultPathOptionalWithoutLosingExistingRelationships() throws {
            let queue = try DatabaseQueue(path: ":memory:", configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v41_vaultAISettingsBackfill")
            let firstVault = UUID.v7()
            let secondVault = UUID.v7()
            let project = UUID.v7()
            let meeting = UUID.v7()
            try queue.write { db in
                try db.execute(
                    sql: "INSERT INTO vaults (id, path, name, createdAt, lastOpenedAt) VALUES (?, ?, 'First', ?, ?)",
                    arguments: [firstVault, "/tmp/first", Date.now, Date.now]
                )
                try db.execute(
                    sql: "INSERT INTO projects (id, vaultId, name, nameKey, createdAt, projectType) VALUES (?, ?, 'Project', 'project', ?, 'undefined')",
                    arguments: [project, firstVault, Date.now]
                )
                try MeetingRecord(
                    id: meeting, vaultId: firstVault, projectId: project,
                    name: "Meeting", createdAt: .now, updatedAt: .now
                ).insert(db)
            }

            try AppDatabaseManager.migrator.migrate(queue)

            try queue.write { db in
                try VaultRecord(
                    id: secondVault, path: nil, name: "Second",
                    createdAt: .now, lastOpenedAt: .distantPast
                ).insert(db)
            }
            let result = try queue.read { db in
                try (
                    VaultRecord.fetchOne(db, key: firstVault),
                    VaultRecord.fetchOne(db, key: secondVault),
                    ProjectRecord.fetchOne(db, key: project),
                    MeetingRecord.fetchOne(db, key: meeting),
                    Row.fetchOne(db, sql: "PRAGMA foreign_key_check")
                )
            }
            #expect(result.0?.path == "/tmp/first")
            #expect(result.1?.path == nil)
            #expect(result.2?.vaultId == firstVault)
            #expect(result.3?.projectId == project)
            #expect(result.4 == nil)

            _ = try queue.write { db in
                try VaultRecord.deleteOne(db, key: firstVault)
            }
            let cleanupJob = try queue.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT targetKind, targetKey FROM search_index_jobs WHERE targetKind = 'vaultCleanup'"
                )
            }
            #expect(cleanupJob?["targetKind"] as String? == "vaultCleanup")
            #expect(cleanupJob?["targetKey"] as UUID? == firstVault)
        }
    }
#endif
