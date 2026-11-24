#if canImport(Testing)
    import DahliaMeetingAccess
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct MeetingSyncMigrationTests {
        @Test
        func transcriptSchemaSeparatesAudioSourceFromSpeakerLabel() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v41_vaultAISettingsBackfill")
            let source = UUID.v7(), workspace = UUID.v7(), meeting = UUID.v7()
            let date = Date.now
            try queue.write { db in
                try db.execute(sql: """
                INSERT INTO vaults(id, path, name, createdAt, lastOpenedAt) VALUES (?, '/tmp/audio-source', 'Workspace', ?, ?);
                INSERT INTO meetings(id, vaultId, name, status, createdAt, updatedAt) VALUES (?, ?, 'Meeting', 'READY', ?, ?);
                INSERT INTO transcript_segments(id, meetingId, startTime, text, isConfirmed, speakerLabel)
                VALUES (?, ?, ?, 'Speech', 1, 'mic');
                """, arguments: [workspace, date, date, meeting, workspace, date, date, source, meeting, date])
            }
            try AppDatabaseManager.migrator.migrate(queue)
            let result = try queue.read { db in
                try (
                    Row.fetchOne(db, sql: "SELECT audioSource, speakerLabel FROM transcript_segments WHERE id = ?", arguments: [source]),
                    Row.fetchOne(db, sql: "SELECT \"notnull\" AS isNotNull FROM pragma_table_info('transcript_segments') WHERE name = 'speakerLabel'")
                )
            }
            #expect(result.0?["audioSource"] as String? == "mic")
            #expect(result.0?["speakerLabel"] as String? == nil)
            #expect(result.1?["isNotNull"] as Int? == 0)
        }
    }
#endif
