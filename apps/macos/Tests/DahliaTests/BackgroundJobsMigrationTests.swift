import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct BackgroundJobsMigrationTests {
        @Test(arguments: ["v52_documentsAndSync", "v53_sharedBackgroundJobs", "v53_documentsSyncAndBackgroundJobs"])
        func validatesBackupsWithActualMergedDevelopmentHistory(prior: String) throws {
            let url = FileManager.default.temporaryDirectory.appending(path: "merged-backup-\(UUID.v7()).sqlite")
            defer { try? FileManager.default.removeItem(at: url) }
            let queue = try DatabaseQueue(path: url.path, configuration: AppDatabaseManager.configuration())
            try DevelopmentSchemaHistory.migrator.migrate(queue, upTo: "v51_scopedSyncReconciliation")
            let workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Preserved", createdAt: .now, lastOpenedAt: .now)
            try queue.write { db throws in
                try workspace.insert(db)
                // GRDB's merged v52 registration replaced these five identifiers, not the released chain.
                for identifier in [
                    "v47_documents",
                    "v48_independentDocuments",
                    "v49_workspaceImportDestinations",
                    "v50_syncPriority",
                    "v51_scopedSyncReconciliation",
                ] {
                    try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [identifier])
                }
                try db.execute(
                    sql: "INSERT INTO grdb_migrations VALUES (?)",
                    arguments: [prior == "v53_documentsSyncAndBackgroundJobs" ? prior : "v52_documentsAndSync"]
                )
                if prior != "v52_documentsAndSync" {
                    try BackgroundJobsMigration.migrate(in: db)
                    if prior == "v53_sharedBackgroundJobs" { try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v53_sharedBackgroundJobs')") }
                }
                let workspaces = try String(decoding: JSONEncoder().encode([BackupWorkspace(id: workspace.id, name: workspace.name)]), as: UTF8.self)
                try db.execute(sql: """
                CREATE TABLE dahlia_backup_metadata(formatVersion INTEGER, generationId TEXT, createdAt DATETIME,
                    schemaVersion INTEGER, migrationIdentifier TEXT, appVersion TEXT, appBuild TEXT, reason TEXT, workspacesJSON TEXT);
                INSERT INTO dahlia_backup_metadata VALUES (?, ?, ?, ?, ?, 'development', 'test', 'manual', ?);
                """, arguments: [
                    BackupMetadata.currentFormatVersion,
                    UUID.v7().uuidString,
                    Date.now,
                    AppDatabaseManager.schemaVersion(from: prior),
                    prior,
                    workspaces,
                ])
            }
            try queue.close()
            #expect(try BackupService.readAndValidateMetadata(at: url).migrationIdentifier == prior)
        }

        @Test
        func ineligibleArchivesBackOffWithoutLosingFutureRecovery() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Preserved", createdAt: .now, lastOpenedAt: .now)
            let meeting = MeetingRecord(id: .v7(), workspaceId: workspace.id, name: "Preserved", createdAt: .now, updatedAt: .now)
            let session = RecordingSessionRecord(
                id: .v7(),
                meetingId: meeting.id,
                startedAt: .now,
                endedAt: .now,
                offsetSeconds: 0,
                createdAt: .now,
                updatedAt: .now
            )
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://test.invalid", clientID: "test", createdAt: .now)
            try await database.dbQueue.write { db throws in
                try connection.insert(db)
                try workspace.insert(db)
                try meeting.insert(db)
                try session.insert(db)
                try RecordingArchiveRecord(
                    sessionId: session.id,
                    meetingId: meeting.id,
                    workspaceId: workspace.id,
                    connectionId: connection.id,
                    state: "pending"
                ).insert(db)
                try db.execute(sql: "UPDATE search_index_state SET phase = 'failed' WHERE indexKind = 'fts'")
            }
            for attempt in 1 ... 6 {
                try await database.dbQueue.write { db throws in
                    try db.execute(sql: "UPDATE jobs_background SET availableAt = 0 WHERE indexKind = 'archive'")
                }
                await database.searchIndexer.drain()
                try await database.dbQueue.read { db throws in
                    #expect(try Int.fetchOne(db, sql: "SELECT attempts FROM jobs_background WHERE indexKind = 'archive'") == attempt)
                    #expect(try Date.fetchOne(db, sql: "SELECT availableAt FROM jobs_background WHERE indexKind = 'archive'")! > Date.now)
                }
            }
            await database.searchIndexer.drain()
            try await database.dbQueue.write { db throws in
                #expect(try Int.fetchOne(db, sql: "SELECT attempts FROM jobs_background WHERE indexKind = 'archive'") == 6)
                try db.execute(sql: "UPDATE recording_archives SET retryAt = ? WHERE sessionId = ?", arguments: [Date.now, session.id])
                #expect(try Int.fetchOne(db, sql: "SELECT attempts FROM jobs_background WHERE indexKind = 'archive'") == 0)
            }
        }

        @Test(arguments: ["v47_orphanedRecordingRecoveryState", "v52_documentsAndSync", "v53_sharedBackgroundJobs"])
        func preservesPriorQueueAndArchiveManifest(prior: String) throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.schemaMigrator(for: prior).migrate(queue, upTo: prior)
            let priorTable = prior == "v53_sharedBackgroundJobs" ? "jobs_background" : "jobs_search_index"
            let workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Preserved", createdAt: .now, lastOpenedAt: .now)
            let meeting = MeetingRecord(id: .v7(), workspaceId: workspace.id, name: "Preserved", createdAt: .now, updatedAt: .now)
            let session = RecordingSessionRecord(
                id: .v7(),
                meetingId: meeting.id,
                startedAt: .now,
                endedAt: .now,
                offsetSeconds: 0,
                createdAt: .now,
                updatedAt: .now
            )
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://test.invalid", clientID: "test", createdAt: .now)
            try queue.write { db throws in
                try connection.insert(db)
                try workspace.insert(db)
                try meeting.insert(db)
                try session.insert(db)
                try RecordingArchiveRecord(
                    sessionId: session.id,
                    meetingId: meeting.id,
                    workspaceId: workspace.id,
                    connectionId: connection.id,
                    preparedJSON: "{}",
                    state: "failed",
                    retryAt: .distantFuture
                ).insert(db)
                try db.execute(sql: """
                UPDATE \(priorTable) SET generation = 7, attempts = 2, status = 'processing',
                    claimedAt = ?, leaseExpiresAt = ?, captionLanguage = 'ja'
                WHERE targetKind = 'meeting' AND targetKey = ?
                """, arguments: [Date.now, Date.distantFuture, meeting.id])
            }
            let before = try queue.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM \(priorTable) WHERE indexKind <> 'archive' ORDER BY indexKind, targetKind, targetKey")
            }
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.read { db throws in
                #expect(try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM jobs_background WHERE indexKind <> 'archive' ORDER BY indexKind, targetKind, targetKey"
                ) == before)
                #expect(try RecordingArchiveRecord.fetchOne(db, key: session.id)?.state == "failed")
                #expect(try UUID.fetchOne(db, sql: "SELECT targetKey FROM jobs_background WHERE indexKind = 'archive'") == session.id)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
                #expect(try AppDatabaseManager.hasExpectedCurrentSchema(db))
            }
            try queue.write { db throws in
                try db.execute(sql: "DELETE FROM jobs_background WHERE indexKind = 'fts'")
                try db.execute(sql: "UPDATE meetings SET name = 'Changed' WHERE id = ?", arguments: [meeting.id])
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM jobs_background WHERE targetKind = 'meeting'") == 1)
                try db.execute(sql: "UPDATE recording_archives SET retryAt = ? WHERE sessionId = ?", arguments: [Date.now, session.id])
                #expect(try Int.fetchOne(db, sql: "SELECT generation FROM jobs_background WHERE indexKind = 'archive'") == 2)
            }
        }
    }
#endif
