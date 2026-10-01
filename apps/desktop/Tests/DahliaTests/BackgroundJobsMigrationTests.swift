import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct BackgroundJobsMigrationTests {
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
            try queue.write { db in
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
            let before = try queue.read { try Row.fetchAll($0, sql: "SELECT * FROM \(priorTable) WHERE indexKind <> 'archive' ORDER BY indexKind, targetKind, targetKey") }
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
            try queue.write { db in
                try db.execute(sql: "DELETE FROM jobs_background WHERE indexKind = 'fts'")
                try db.execute(sql: "UPDATE meetings SET name = 'Changed' WHERE id = ?", arguments: [meeting.id])
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM jobs_background WHERE targetKind = 'meeting'") == 1)
                try db.execute(sql: "UPDATE recording_archives SET retryAt = ? WHERE sessionId = ?", arguments: [Date.now, session.id])
                #expect(try Int.fetchOne(db, sql: "SELECT generation FROM jobs_background WHERE indexKind = 'archive'") == 2)
            }
        }
    }
#endif
