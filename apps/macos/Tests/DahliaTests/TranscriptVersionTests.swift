#if canImport(Testing)
    import DahliaMeetingAccess
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct TranscriptVersionTests {
        @Test(arguments: ["covered", "missing", "checksum", "source", "changedDuringWork", "noProvenance", "localAppend", "foreignRun"])
        func cloudReplacementRequiresAllOriginalAudioAtPreparationAndCommit(scenario: String) throws {
            let fixture = try BatchAudioTestFixture(name: "CloudCoverage", endedAt: .now)
            defer { fixture.removeFiles() }
            let checksum = "SHA-256:" + String(repeating: "0", count: 64)
            var run = TranscriptMetadata.Run(generatedBy: "server", startedAt: .now)
            if scenario != "noProvenance" {
                run.audioInputs = [.init(
                    recordingNumber: scenario == "missing" ? 2 : 1,
                    source: scenario == "source" ? "system" : "mic",
                    checksum: checksum
                )]
            }
            var runs = [run]
            if scenario == "localAppend" || scenario == "foreignRun" {
                runs.append(.init(startedAt: .now, recordingSessionId: scenario == "localAppend" ? fixture.session.id : .v7()))
            }
            let info = TranscriptInfo(
                id: .v7(),
                startedAt: fixture.now,
                endedAt: .now,
                metadata: .init(provider: "gemini", model: "gemini", runs: runs)
            )
            let audio = RecordingArchivedAudio(
                contentType: "audio/mp4", size: 1, checksum: scenario == "checksum" ? "different" : checksum,
                contentURL: "/recording", manifest: .init(sampleRate: 16000, frameCount: 16000, ranges: [])
            )
            let old = TranscriptContent(
                from: .init(startTime: fixture.now, text: "cloud", isConfirmed: true),
                meetingId: fixture.meeting.id,
                defaultSessionId: nil
            )
            try fixture.database.dbQueue.write { db in
                try TranscriptRecord(meetingId: fixture.meeting.id, info: info).insert(db)
                try old.insert(db)
                try RecordingArchiveRecord(
                    sessionId: fixture.session.id,
                    meetingId: fixture.meeting.id,
                    workspaceId: fixture.meeting.workspaceId,
                    number: 1,
                    audioJSON: String(decoding: SyncJSON.encoder.encode(["mic": audio]), as: UTF8.self)
                ).insert(db)
            }
            let prepare = {
                try fixture.database.dbQueue.read { db in
                    try BatchTranscriptionPersistence.validateReplacementCoverage(
                        meetingID: fixture.meeting.id, sessions: [fixture.session], in: db
                    )
                }
            }
            let covered = scenario == "covered" || scenario == "changedDuringWork" || scenario == "localAppend"
            if covered { try prepare() } else { #expect(throws: TranscriptVersionError.self) { try prepare() } }
            if scenario == "changedDuringWork" {
                try fixture.database.dbQueue.write { db in
                    try db.execute(sql: "UPDATE recording_archives SET audioJSON = '{}' WHERE sessionId = ?", arguments: [fixture.session.id])
                }
            }
            let replacement = TranscriptContent(
                from: .init(startTime: fixture.now, text: "apple", isConfirmed: true),
                meetingId: fixture.meeting.id,
                defaultSessionId: fixture.session.id
            )
            let sessions = try fixture.database.dbQueue.read { db in try RecordingSessionRecord.fetchAll(db) }
            let complete = {
                try BatchTranscriptionPersistence.complete(
                    sessionId: fixture.session.id, meetingId: fixture.meeting.id, records: [replacement], completedAt: .now,
                    dbQueue: fixture.database.dbQueue, replacingMeeting: true,
                    expectedTranscriptId: info.id, expectedSessions: sessions
                )
            }
            if scenario == "covered" || scenario == "localAppend" { try complete() } else {
                #expect(throws: TranscriptVersionError.self) { try complete() }
                #expect(try fixture.database.dbQueue.read { try fetchTranscriptContent(id: old.id, in: $0)?.text } == "cloud")
            }
        }

        @Test
        func liveVersionSealsAndNextRunPreservesBody() throws {
            let fixture = try BatchAudioTestFixture(name: "TranscriptVersions")
            defer { fixture.removeFiles() }
            try fixture.database.dbQueue.write { db in
                var session = fixture.session
                session.transcriptionMode = .realtime
                try session.update(db)
                try TranscriptRecord.beginLive(session, in: db)
                let first = try #require(try TranscriptRecord.current(fixture.meeting.id, in: db))
                try TranscriptContent(
                    from: TranscriptSegment(startTime: fixture.now, text: "retained", isConfirmed: true),
                    meetingId: fixture.meeting.id,
                    defaultSessionId: session.id
                ).insert(db)
                var acknowledged = first
                acknowledged.version = 1
                try TranscriptRecord.applyCanonical(meetingId: fixture.meeting.id, info: acknowledged, in: db)
                #expect(try TranscriptRecord.fetchOne(db, key: fixture.meeting.id)?.sessionId == session.id)
                try TranscriptRecord.finishLive(meetingId: fixture.meeting.id, sessionId: session.id, at: fixture.now, in: db)
                #expect(try TranscriptRecord.current(fixture.meeting.id, in: db)?.id == first.id)
                #expect(try TranscriptRecord.current(fixture.meeting.id, in: db)?.status == "ended")
                session.endedAt = fixture.now
                try session.update(db)
                session.id = .v7()
                session.endedAt = nil
                try session.insert(db)
                try TranscriptRecord.beginLive(session, in: db)
                let next = try #require(try TranscriptRecord.current(fixture.meeting.id, in: db))
                #expect(next.id != first.id)
                #expect(next.metadata?.runs.count == 2)
                #expect(try TranscriptSegmentRecord.fetchCount(db) == 1)
                try TranscriptRecord.finishLive(
                    meetingId: fixture.meeting.id,
                    sessionId: session.id,
                    at: nil,
                    in: db
                )
                #expect(try TranscriptRecord.current(fixture.meeting.id, in: db)?.status == "active")
                #expect(try TranscriptRecord.current(fixture.meeting.id, in: db)?.endedAt == nil)
                #expect(try TranscriptRecord.fetchCount(db) == 1)
            }
        }

        @Test
        func batchReplacementIsAtomicAndRejectsStaleCompletion() throws {
            let fixture = try BatchAudioTestFixture(name: "TranscriptAtomic", endedAt: Date())
            defer { fixture.removeFiles() }
            let prior = TranscriptInfo(
                id: .v7(),
                status: "completed",
                startedAt: nil,
                completedAt: nil,
                metadata: .init(provider: "apple", model: "apple-speech", runs: [])
            )
            let old = TranscriptContent(
                from: TranscriptSegment(startTime: fixture.now, text: "old", isConfirmed: true),
                meetingId: fixture.meeting.id,
                defaultSessionId: fixture.session.id
            )
            let new = TranscriptContent(
                from: TranscriptSegment(startTime: fixture.now, text: "new", isConfirmed: true),
                meetingId: fixture.meeting.id,
                defaultSessionId: fixture.session.id
            )
            try fixture.database.dbQueue.write { db in
                try TranscriptRecord(meetingId: fixture.meeting.id, info: prior).insert(db)
                try old.insert(db)
            }
            #expect(throws: (any Error).self) {
                try BatchTranscriptionPersistence.complete(
                    sessionId: fixture.session.id,
                    meetingId: fixture.meeting.id,
                    records: [new],
                    completedAt: .now,
                    dbQueue: fixture.database.dbQueue,
                    replacingMeeting: true,
                    expectedTranscriptId: .v7()
                )
            }
            #expect(throws: (any Error).self) {
                try BatchTranscriptionPersistence.complete(
                    sessionId: fixture.session.id,
                    meetingId: fixture.meeting.id,
                    records: [new, new],
                    completedAt: .now,
                    dbQueue: fixture.database.dbQueue,
                    replacingMeeting: true,
                    expectedTranscriptId: prior.id
                )
            }
            #expect(try fixture.database.dbQueue.read { try fetchTranscriptContent(id: old.id, in: $0)?.text } == "old")
            try BatchTranscriptionPersistence.complete(
                sessionId: fixture.session.id,
                meetingId: fixture.meeting.id,
                records: [new],
                completedAt: .now,
                dbQueue: fixture.database.dbQueue,
                replacingMeeting: true,
                expectedTranscriptId: prior.id,
                expectedSessions: fixture.database.dbQueue.read { try RecordingSessionRecord.fetchAll($0) }
            )
            try fixture.database.dbQueue.read { db throws in
                #expect(try fetchTranscriptContent(id: old.id, in: db) == nil)
                #expect(try fetchTranscriptContent(id: new.id, in: db)?.text == "new")
                #expect(try TranscriptRecord.current(fixture.meeting.id, in: db)?.metadata?.request.model == "apple-speech")
                #expect(try TranscriptRecord.current(fixture.meeting.id, in: db)?.id != prior.id)
            }
        }

        @Test
        func batchAppendFreezesFullBodiesAndConflictReapplyCreatesANewVersion() async throws {
            let fixture = try BatchAudioTestFixture(name: "TranscriptSnapshots", endedAt: Date())
            defer { fixture.removeFiles() }
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://snapshot.invalid", clientID: "test", createdAt: .now)
            try await fixture.database.dbQueue.write { db in
                try connection.insert(db)
                try db.execute(
                    sql: """
                    UPDATE workspaces SET accountConnectionId = ?, organizationId = COALESCE(organizationId, id),
                    syncRole = COALESCE(syncRole, 'admin'), syncConfirmedConnectionId = ? WHERE id = ?
                    """,
                    arguments: [connection.id, connection.id, fixture.meeting.workspaceId]
                )
            }
            let first = TranscriptContent(
                from: TranscriptSegment(startTime: fixture.now, text: "first", isConfirmed: true),
                meetingId: fixture.meeting.id,
                defaultSessionId: fixture.session.id
            )
            try BatchTranscriptionPersistence.complete(
                sessionId: fixture.session.id,
                meetingId: fixture.meeting.id,
                records: [first],
                completedAt: .now,
                dbQueue: fixture.database.dbQueue
            )
            let firstInfo = try await fixture.database.dbQueue.read { try #require(try TranscriptRecord.current(fixture.meeting.id, in: $0)) }
            var nextSession = fixture.session
            nextSession.id = .v7()
            let next = nextSession
            try await fixture.database.dbQueue.write { try next.insert($0) }
            let second = TranscriptContent(
                from: TranscriptSegment(startTime: fixture.now, text: "second", isConfirmed: true),
                meetingId: fixture.meeting.id,
                defaultSessionId: next.id
            )
            try BatchTranscriptionPersistence.complete(
                sessionId: next.id,
                meetingId: fixture.meeting.id,
                records: [second],
                completedAt: .now,
                dbQueue: fixture.database.dbQueue,
                expectedTranscriptId: firstInfo.id
            )
            let secondInfo = try await fixture.database.dbQueue.write { db in
                let counts = try Int.fetchAll(db, sql: """
                SELECT count(*) FROM sync_transcript_patch_items p JOIN sync_operations o ON o.id = p.operationId
                JOIN sync_transactions t ON t.id = o.transactionId GROUP BY o.id ORDER BY t.sequence
                """)
                #expect(counts == [1, 2])
                #expect(try TranscriptSegmentRecord.fetchCount(db) == 2)
                try db
                    .execute(
                        sql: "UPDATE sync_transactions SET blockedReason = 'conflict' WHERE sequence = (SELECT MIN(sequence) FROM sync_transactions)"
                    )
                return try #require(try TranscriptRecord.current(fixture.meeting.id, in: db))
            }
            try await SyncTransactionQueue.reapplyLocalVersion(workspaceId: fixture.meeting.workspaceId, dbQueue: fixture.database.dbQueue)
            try await fixture.database.dbQueue.read { db throws in
                #expect(try TranscriptRecord.current(fixture.meeting.id, in: db)?.id != secondInfo.id)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations WHERE entity = 'transcript'") == 1)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transcript_patch_items") == 2)
            }
        }

        @Test
        func oldWriterCannotAppendToANewerLiveVersion() async throws {
            let fixture = try BatchAudioTestFixture(name: "TranscriptWriter")
            defer { fixture.removeFiles() }
            try await fixture.database.dbQueue.write { db in
                var session = fixture.session
                session.endedAt = fixture.now
                try session.update(db)
                session.id = .v7()
                session.endedAt = nil
                session.transcriptionMode = .realtime
                try session.insert(db)
                try TranscriptRecord.beginLive(session, in: db)
            }
            let writer = TranscriptPersistenceWriter(
                dbQueue: fixture.database.dbQueue,
                meetingId: fixture.meeting.id,
                recordingSessionId: fixture.session.id,
                persistencePolicy: .streaming
            )
            await #expect(throws: TextContentError.changed) {
                try await writer.persist(.finalized(TranscriptSegment(startTime: fixture.now, text: "stale", isConfirmed: true)))
            }
            #expect(try await fixture.database.dbQueue.read { try TranscriptSegmentRecord.fetchCount($0) } == 0)
        }

        @Test
        func recoveryInterruptsOldLiveVersionButLeavesNewRecordingActive() async throws {
            let fixture = try BatchAudioTestFixture(name: "TranscriptRecovery")
            defer { fixture.removeFiles() }
            try await fixture.database.dbQueue.write { db in
                var session = fixture.session
                session.transcriptionMode = .realtime
                try session.update(db)
                try TranscriptRecord.beginLive(session, in: db)
            }
            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                onStateChange: { _ in }
            )
            try await coordinator.recoverAndEnqueue()
            try await fixture.database.dbQueue.write { db in
                #expect(try TranscriptRecord.current(fixture.meeting.id, in: db)?.status == "unknown")
                #expect(try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)?.endedAt != nil)
                var next = fixture.session
                next.id = .v7()
                next.startedAt = .distantFuture
                next.transcriptionMode = .realtime
                try next.insert(db)
                try TranscriptRecord.beginLive(next, in: db)
            }
            try await coordinator.recoverAndEnqueue()
            #expect(try await fixture.database.dbQueue.read { try TranscriptRecord.current(fixture.meeting.id, in: $0)?.status } == "unknown")
            try await coordinator.shutdown()
        }

    }
#endif
