#if canImport(Testing)
    import DahliaMeetingAccess
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct ReleaseSchemaMigrationTests {
        @Test(arguments: [false, true])
        func releasedDataSurvivesAtomicUpgradeAndReopen(retryAfterFailure: Bool) throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v41_vaultAISettingsBackfill")
            let vaultID = UUID.v7(), meetingID = UUID.v7(), segmentID = UUID.v7(), screenshotID = UUID.v7()
            let previewID = UUID.v7()
            let sessionID = UUID.v7(), emptySessionID = UUID.v7(), completedSessionID = UUID.v7()
            let date = Date(timeIntervalSince1970: 1_780_000_000)
            let bytes = Data([1, 2, 3, 4])
            try queue.write { db in
                try db.execute(sql: """
                INSERT INTO vaults(id, path, name, createdAt, lastOpenedAt, summaryModelID, aiSettingsBackfilled)
                VALUES (?, '/tmp/released-vault', 'Released vault', ?, ?, 'saved-model', 1)
                """, arguments: [vaultID, date, date])
                try MeetingRecord(id: meetingID, vaultId: vaultID, projectId: nil, name: "Released meeting", createdAt: date, updatedAt: date)
                    .insert(db)
                for (id, start, end, duration) in [
                    (sessionID, date, nil as Date?, nil as Double?),
                    (emptySessionID, date.addingTimeInterval(10), nil, 2),
                    (completedSessionID, date.addingTimeInterval(20), date.addingTimeInterval(25), 5),
                ] {
                    try db.execute(sql: """
                    INSERT INTO recording_sessions(id, meetingId, startedAt, endedAt, duration, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [id, meetingID, start, end, duration, start, end ?? start])
                }
                try db.execute(sql: """
                INSERT INTO transcript_segments(id, meetingId, sessionId, startTime, endTime, text, translatedText, isConfirmed, speakerLabel,
                    audioFeatureVersion, audioVoicedFrameRatio)
                VALUES (?, ?, ?, ?, ?, '原文', 'translation', 1, 'mic', 1, 0.7)
                """, arguments: [segmentID, meetingID, sessionID, date, date.addingTimeInterval(1)])
                try db.execute(sql: """
                INSERT INTO transcript_segments(id, meetingId, startTime, text, isConfirmed)
                VALUES (?, ?, ?, 'unfinished preview', 0)
                """, arguments: [previewID, meetingID, date])
                try db.execute(sql: """
                INSERT INTO summaries(meetingId, title, document, createdAt) VALUES (?, 'Saved summary', '{"version":1}', ?)
                """, arguments: [meetingID, date])
                try SummaryExportRecord.setURL("vault:///saved.md", meetingId: meetingID, type: .vault, in: db)
                try MeetingNoteRecord(meetingId: meetingID, text: "user note", createdAt: date, updatedAt: date).insert(db)
                try db.execute(sql: """
                INSERT INTO screenshots(id, meetingId, capturedAt, imageData, mimeType, ocrText, caption)
                VALUES (?, ?, ?, ?, 'image/png', 'OCR 原文', 'caption')
                """, arguments: [screenshotID, meetingID, date, bytes])
                if retryAfterFailure {
                    // The final step must fail, after earlier steps have rebuilt tables and moved bodies.
                    try db.execute(sql: "CREATE TABLE vault_relocation_scope(sourceVaultId BLOB, destinationVaultId BLOB)")
                }
            }
            if retryAfterFailure {
                #expect(throws: DatabaseError.self) { try AppDatabaseManager.migrator.migrate(queue) }
                try queue.write { db in
                    #expect(try String
                        .fetchOne(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1") == "v41_vaultAISettingsBackfill")
                    #expect(try !db.tableExists("files"))
                    #expect(try String.fetchOne(db, sql: "SELECT text FROM transcript_segments") == "原文")
                    #expect(try Data.fetchOne(db, sql: "SELECT imageData FROM screenshots") == bytes)
                    #expect(try Date.fetchOne(db, sql: "SELECT endedAt FROM recording_sessions WHERE id = ?", arguments: [sessionID]) == nil)
                    try db.execute(sql: "DROP TABLE vault_relocation_scope")
                }
            }
            try AppDatabaseManager.migrator.migrate(queue)
            let transcriptID = try queue.read { try TranscriptRecord.current(meetingID, in: $0)?.id }
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.read { db in
                let vault = try #require(try VaultRecord.fetchOne(db, key: vaultID))
                #expect(vault.path == "/tmp/released-vault" && vault.summaryModelID == "saved-model")
                #expect(vault.syncRole == nil && vault.syncConfirmedConnectionId == nil)
                #expect(try Int.fetchOne(db, sql: "SELECT syncMutationGeneration FROM vaults WHERE id = ?", arguments: [vaultID]) == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT syncMeetingEventsVersion FROM vaults WHERE id = ?", arguments: [vaultID]) == 0)
                let segment = try #require(try fetchTranscriptContent(id: segmentID, in: db))
                #expect(segment.text == "原文" && segment.translatedText == "translation")
                #expect(segment.audioSource == "mic" && segment.audioVoicedFrameRatio == 0.7)
                #expect(segment.startTime == date && segment.endTime == date.addingTimeInterval(1))
                #expect(segment.sessionId == sessionID)
                #expect(segment.createdAt == date.addingTimeInterval(25))
                let recovered = try #require(try RecordingSessionRecord.fetchOne(db, key: sessionID))
                #expect(recovered.endedAt == date.addingTimeInterval(1) && recovered.duration == 1)
                let empty = try #require(try RecordingSessionRecord.fetchOne(db, key: emptySessionID))
                #expect(empty.endedAt == date.addingTimeInterval(12) && empty.duration == 2)
                let completed = try #require(try RecordingSessionRecord.fetchOne(db, key: completedSessionID))
                #expect(completed.endedAt == date.addingTimeInterval(25) && completed.duration == 5)
                #expect(try RecordingSessionRecord.fetchCount(db) == 3)
                #expect(try MeetingRecord.fetchOne(db, key: meetingID)?.duration == 8)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM transcript_segment_bodies WHERE segmentId = ?", arguments: [previewID]) == 0)
                #expect(try SummaryContent.fetchOne(db, key: meetingID)?.document == "{\"version\":1}")
                #expect(try SummaryExportRecord.fetchOne(meetingId: meetingID, type: .vault, in: db)?.url == "vault:///saved.md")
                #expect(try MeetingNoteRecord.fetchOne(db, key: meetingID)?.text == "user note")
                let image = try #require(try MeetingScreenshotRecord.fetchOne(db, key: screenshotID))
                #expect(image.imageData == bytes && image.ocrText == "OCR 原文" && image.caption == "caption")
                #expect(try String.fetchOne(db, sql: "SELECT ocrText FROM file_text_bodies WHERE fileId = ?", arguments: [screenshotID]) == "OCR 原文")
                #expect(try String.fetchOne(db, sql: "SELECT json_extract(metadata, '$.ocr_text') FROM files WHERE id = ?", arguments: [screenshotID]) == nil)
                #expect(try TranscriptRecord.current(meetingID, in: db)?.id == transcriptID)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations") == 0)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
                #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
                #expect(try AppDatabaseManager.hasExpectedCurrentSchema(db))
            }
        }

        @Test
        func freshDatabaseRegistersOnlyOnePostReleaseMigration() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let identifiers = AppDatabaseManager.migrationIdentifiers
            let releaseIndex = try #require(identifiers.firstIndex(of: "v41_vaultAISettingsBackfill"))
            #expect(Array(identifiers.dropFirst(releaseIndex + 1)) == ["v42_localFirstSchema"])
            try database.dbQueue.read { db throws in
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
                #expect(try !db.columns(in: "vaults").contains { $0.name == "appearance" })
                #expect(try !db.columns(in: "projects").contains { $0.name == "appearance" })
                #expect(try AppDatabaseManager.hasExpectedCurrentSchema(db))
            }
        }
    }
#endif
