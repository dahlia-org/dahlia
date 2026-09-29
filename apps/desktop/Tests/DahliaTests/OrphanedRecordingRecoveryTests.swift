import DahliaRuntimeSupport
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct OrphanedRecordingRecoveryTests {
        @Test(arguments: ["v17_calendarEventIntegrity", "v41_vaultAISettingsBackfill"])
        func startupPreservesOrphanedRecordingsAndReopens(version: String) throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID.v7().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appending(path: "test.sqlite").path
            let meetingID = UUID.v7()
            let existingWorkspaceID = UUID.v7(), existingMeetingID = UUID.v7()
            let sessionIDs = [UUID.v7(), UUID.v7()]
            let date = Date(timeIntervalSince1970: 1_788_000_000)
            let queue = try DatabaseQueue(path: path, configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: version)
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: """
                INSERT INTO vaults (id, path, name, createdAt, lastOpenedAt) VALUES (?, '/tmp/existing', 'Existing', ?, ?);
                INSERT INTO meetings (id, vaultId, name, createdAt, updatedAt) VALUES (?, ?, 'Existing meeting', ?, ?);
                """, arguments: [existingWorkspaceID, date, date, existingMeetingID, existingWorkspaceID, date, date])
                try db.execute(sql: "PRAGMA foreign_keys = OFF")
                for sessionID in sessionIDs {
                    try db.execute(sql: """
                    INSERT INTO recording_sessions (id, meetingId, startedAt, endedAt, duration, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, 700, ?, ?)
                    """, arguments: [sessionID, meetingID, date, date.addingTimeInterval(700), date, date])
                }
                try db.execute(sql: "PRAGMA foreign_keys = ON")
                #expect(throws: DatabaseError.self) { try db.checkForeignKeys() }
            }
            // The unmodified migration path reproduces the reported launch failure.
            #expect(throws: DatabaseError.self) { try AppDatabaseManager.migrator.migrate(queue) }
            try queue.close()

            for _ in 0 ..< 2 {
                let manager = try AppDatabaseManager(path: path)
                try manager.dbQueue.read { db in
                    let meeting = try #require(try MeetingRecord.fetchOne(db, key: meetingID))
                    let workspace = try #require(try WorkspaceRecord.fetchOne(db, key: meeting.workspaceId))
                    #expect(workspace.accountConnectionId == nil && workspace.organizationId == nil)
                    #expect(workspace.path == nil && !workspace.generationSettings.automaticProcessing)
                    #expect(workspace.id != existingWorkspaceID)
                    #expect(try MeetingRecord.fetchCount(db) == 2)
                    #expect(try WorkspaceRecord.fetchCount(db) == 2)
                    #expect(try WorkspaceRecord.fetchOne(db, key: existingWorkspaceID)?.path == "/tmp/existing")
                    #expect(try MeetingRecord.fetchOne(db, key: existingMeetingID)?.name == "Existing meeting")
                    #expect(try RecordingSessionRecord.fetchCount(db) == 2)
                    for id in sessionIDs {
                        let session = try #require(try RecordingSessionRecord.fetchOne(db, key: id))
                        #expect(session.meetingId == meetingID && session.startedAt == date)
                        #expect(session.endedAt == date.addingTimeInterval(700) && session.duration == 700)
                    }
                    try db.checkForeignKeys()
                    #expect(try AppDatabaseManager.hasExpectedCurrentSchema(db))
                }
                try manager.close()
            }
        }

        @Test
        func migrationFailureCanRetryWithoutDuplicatingRecoveryOrLosingContent() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v41_vaultAISettingsBackfill")
            let meetingID = UUID.v7(), sessionID = UUID.v7(), segmentID = UUID.v7(), imageID = UUID.v7()
            let date = Date(timeIntervalSince1970: 1_788_000_000)
            let image = Data([1, 2, 3])
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA foreign_keys = OFF")
                try db.execute(sql: """
                INSERT INTO recording_sessions (id, meetingId, startedAt, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?);
                INSERT INTO transcript_segments (id, meetingId, sessionId, startTime, text, isConfirmed)
                VALUES (?, ?, ?, ?, 'saved transcript', 1);
                INSERT INTO screenshots (id, meetingId, capturedAt, imageData, mimeType) VALUES (?, ?, ?, ?, 'image/png');
                INSERT INTO notes (meetingId, text, createdAt, updatedAt) VALUES (?, 'saved note', ?, ?);
                CREATE TABLE workspace_relocation_scope (source_workspace_id BLOB, destination_workspace_id BLOB);
                """, arguments: [
                    sessionID, meetingID, date, date, date,
                    segmentID, meetingID, sessionID, date,
                    imageID, meetingID, date, image,
                    meetingID, date, date,
                ])
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            let recoveryPath = "/tmp/recovery-retry"
            try queue.write { try OrphanedRecordingRecovery.prepare(in: $0, recoveryPath: recoveryPath) }
            #expect(throws: DatabaseError.self) { try AppDatabaseManager.migrator.migrate(queue) }
            try queue.write { db in
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM vaults") == 1)
                #expect(try String.fetchOne(db, sql: "SELECT text FROM transcript_segments") == "saved transcript")
                #expect(try Data.fetchOne(db, sql: "SELECT imageData FROM screenshots") == image)
                try db.execute(sql: "DROP TABLE workspace_relocation_scope")
                try OrphanedRecordingRecovery.prepare(in: db, recoveryPath: recoveryPath)
            }
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.write { try OrphanedRecordingRecovery.finish(in: $0, recoveryPath: recoveryPath) }
            try queue.read { db in
                let workspace = try #require(try WorkspaceRecord.fetchOne(db))
                #expect(try WorkspaceRecord.fetchCount(db) == 1)
                #expect(workspace.path == nil && !workspace.generationSettings.automaticProcessing)
                #expect(try String.fetchOne(db, sql: "SELECT text FROM transcript_segment_bodies WHERE segmentId = ?", arguments: [segmentID])
                    == "saved transcript")
                #expect(try MeetingScreenshotRecord.fetchOne(db, key: imageID)?.imageData == image)
                #expect(try MeetingNoteRecord.fetchOne(db, key: meetingID)?.text == "saved note")
                try db.checkForeignKeys()
            }
        }

        @Test
        func unrelatedCorruptionRollsBackRecovery() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v17_calendarEventIntegrity")
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA foreign_keys = OFF")
                try db.execute(sql: """
                INSERT INTO recording_sessions (id, meetingId, startedAt, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?);
                INSERT INTO meetings (id, vaultId, createdAt, updatedAt) VALUES (?, ?, ?, ?);
                """, arguments: [UUID.v7(), UUID.v7(), Date.now, Date.now, Date.now, UUID.v7(), UUID.v7(), Date.now, Date.now])
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            #expect(throws: DatabaseError.self) {
                try queue.write { try OrphanedRecordingRecovery.prepare(in: $0, recoveryPath: "/tmp/recovery") }
            }
            let counts = try queue.read { db in
                try (
                    Int.fetchOne(db, sql: "SELECT count(*) FROM vaults"),
                    Int.fetchOne(db, sql: "SELECT count(*) FROM meetings"),
                    Int.fetchOne(db, sql: "SELECT count(*) FROM recording_sessions")
                )
            }
            #expect(counts.0 == 0 && counts.1 == 1 && counts.2 == 1)
        }
    }
#endif
