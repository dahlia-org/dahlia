#if canImport(Testing)
    import DahliaMeetingAccess
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct TranscriptActivityTests {
        @Test
        func activityIsComputedAtReadTimeIncludingTheExactBoundary() throws {
            let generated = Date(timeIntervalSince1970: 1000)
            var info = TranscriptInfo(id: .v7(), startedAt: generated, endedAt: nil, metadata: nil)
            #expect(info.status(at: generated) == "unknown")
            info.latestSegmentCreatedAt = generated
            #expect(info.status(at: generated) == "active")
            #expect(info.status(at: generated.addingTimeInterval(TranscriptInfo.activityWindow)) == "active")
            #expect(info.status(at: generated.addingTimeInterval(TranscriptInfo.activityWindow + 0.001)) == "inactive")
            info.endedAt = generated
            info.latestSegmentCreatedAt = nil
            #expect(info.status(at: generated) == "ended")
            let record = try TranscriptRecord(meetingId: .v7(), info: info)
            let stored = try SyncJSON.decoder.decode([String: DahliaRuntimeSupport.JSONValue].self, from: Data(record.infoJSON.utf8))
            #expect(stored["status"] == nil)
            let published = try SyncJSON.decoder.decode([String: DahliaRuntimeSupport.JSONValue].self, from: SyncJSON.encoder.encode(info))
            #expect(published["status"] == .string("ended"))
        }

        @Test
        func liveAndBatchCreationTimeIsSeparateFromSpeechTimeAndSurvivesPersistence() throws {
            let fixture = try BatchAudioTestFixture(name: "TranscriptCreation")
            defer { fixture.removeFiles() }
            let yesterday = Date.now.addingTimeInterval(-86400)
            let before = Date.now
            let live = TranscriptSegment(startTime: yesterday, text: "live", isConfirmed: true)
            let batch = try #require(BatchSpeechTranscriberService.transcriptSegments(
                from: [.init(startSeconds: 3, endSeconds: 4, text: "batch")],
                recordingSessionId: fixture.session.id, recordingStartTime: yesterday,
                sessionOffsetSeconds: 10, source: .microphone
            ).first)
            let after = Date.now
            for segment in [live, batch] {
                let createdAt = try #require(segment.createdAt)
                #expect(createdAt >= before && createdAt <= after)
                #expect(createdAt > segment.startTime)
                try fixture.database.dbQueue.write { db in
                    let content = TranscriptContent(from: segment, meetingId: fixture.meeting.id, defaultSessionId: fixture.session.id)
                    try content.insert(db)
                    let persisted = try #require(try fetchTranscriptContent(id: segment.id, in: db))
                    #expect(try abs(#require(persisted.createdAt).timeIntervalSince(createdAt)) < 0.001)
                    #expect(abs(persisted.startTime.timeIntervalSince(segment.startTime)) < 0.001)
                    let patch = SyncTranscriptPatchSegment(persisted)
                    #expect(patch.createdAt == persisted.createdAt)
                }
            }
            #expect(batch.startTime == yesterday.addingTimeInterval(13))
            #expect(batch.endTime == yesterday.addingTimeInterval(14))
            let regenerated = try #require(BatchSpeechTranscriberService.transcriptSegments(
                from: [.init(startSeconds: 3, endSeconds: 4, text: "regenerated")],
                recordingSessionId: fixture.session.id, recordingStartTime: yesterday,
                sessionOffsetSeconds: 10, source: .microphone
            ).first)
            #expect(regenerated.id != batch.id)
            #expect(try #require(regenerated.createdAt) >= #require(batch.createdAt))
            let preview = TranscriptSegment(startTime: yesterday, text: "preview")
            try fixture.database.dbQueue.write { db in
                try TranscriptContent(from: preview, meetingId: fixture.meeting.id).insert(db)
                #expect(try TranscriptSegmentRecord.fetchOne(db, key: preview.id) == nil)
            }
        }

        @Test
        func releasedMigrationPreservesAbsoluteTimesAndPlayback() throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v41_vaultAISettingsBackfill")
            let base = Date(timeIntervalSince1970: 1000)
            let end = base.addingTimeInterval(120)
            let workspaceId = UUID.v7(), meetingId = UUID.v7(), segmentId = UUID.v7()
            let session = RecordingSessionRecord(
                id: .v7(),
                meetingId: meetingId,
                startedAt: base.addingTimeInterval(100),
                endedAt: end,
                duration: 20,
                offsetSeconds: 10,
                createdAt: base,
                updatedAt: end
            )
            let speechStart = session.startedAt.addingTimeInterval(3)
            let speechEnd = session.startedAt.addingTimeInterval(4)
            try queue.write { db in
                try db.execute(
                    sql: "INSERT INTO vaults(id, path, name, createdAt, lastOpenedAt) VALUES (?, '/tmp/activity', 'Legacy', ?, ?)",
                    arguments: [workspaceId, base, base]
                )
                try db.execute(
                    sql: "INSERT INTO meetings(id, vaultId, name, status, duration, createdAt, updatedAt, recordingStartedAt) VALUES (?, ?, 'Legacy', 'READY', 30, ?, ?, ?)",
                    arguments: [meetingId, workspaceId, base, end, base]
                )
                try db.execute(sql: """
                INSERT INTO recording_sessions(id, meetingId, startedAt, endedAt, duration, offsetSeconds, createdAt, updatedAt, transcriptionMode,
                    batchCompletedAt, batchAttemptCount) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    session.id,
                    session.meetingId,
                    session.startedAt,
                    session.endedAt,
                    session.duration,
                    session.offsetSeconds,
                    session.createdAt,
                    session.updatedAt,
                    session.transcriptionMode.rawValue,
                    session.batchCompletedAt,
                    session.batchAttemptCount,
                ])
                try db.execute(
                    sql: "INSERT INTO transcript_segments(id, meetingId, sessionId, startTime, endTime, text, isConfirmed) VALUES (?, ?, ?, ?, ?, 'preserved 日本語', 1)",
                    arguments: [segmentId, meetingId, session.id, speechStart, speechEnd]
                )

            }
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.read { db in
                let content = try #require(try fetchTranscriptContent(id: segmentId, in: db))
                #expect(content.text == "preserved 日本語")
                #expect(content.startTime == speechStart && content.endTime == speechEnd)
                #expect(content.createdAt == end)
                #expect(Formatters.elapsedSeconds(
                    at: content.startTime,
                    sessionId: content.sessionId,
                    sessions: [.init(from: session)],
                    fallbackTimeBase: base
                ) == 13)
                #expect(try RecordingSessionRecord.fetchOne(db, key: session.id) == session)
                #expect(try TranscriptRecord.current(meetingId, in: db) != nil)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions") == 0)
                let columns = try Set(db.columns(in: "transcript_segments").map(\.name))
                #expect(columns.contains("startedAt") && columns.contains("endedAt") && columns.contains("createdAt"))
                #expect(!columns.contains("startTime") && !columns.contains("isConfirmed"))
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }
    }
#endif
