#if canImport(Testing)
    import DahliaMeetingAccess
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct TranscriptVersionTests {
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
                    sql: "UPDATE vaults SET accountConnectionId = ?, syncConfirmedConnectionId = ? WHERE id = ?",
                    arguments: [connection.id, connection.id, fixture.meeting.vaultId]
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
            try await SyncTransactionQueue.reapplyLocalVersion(vaultId: fixture.meeting.vaultId, dbQueue: fixture.database.dbQueue)
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

        @Test
        func migrationPreservesBodyAndFreezesPendingSnapshot() throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v48_recordingArchives")
            let vaultId = UUID.v7(), meetingId = UUID.v7(), operationId = UUID.v7(), transactionId = UUID.v7()
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://migration.invalid", clientID: "test", createdAt: .now)
            try queue.write { db in
                try connection.insert(db)
                try insertLegacyVault(VaultRecord(id: vaultId, path: nil, name: "Existing", createdAt: .now, lastOpenedAt: .now), in: db)
                try MeetingRecord(id: meetingId, vaultId: vaultId, projectId: nil, name: "Existing", createdAt: .now, updatedAt: .now).insert(db)
                let segmentId = UUID.v7()
                try db.execute(
                    sql: "INSERT INTO transcript_segments(id, meetingId, startTime, isConfirmed) VALUES (?, ?, ?, 1)",
                    arguments: [segmentId, meetingId, Date()]
                )
                try db.execute(sql: "INSERT INTO transcript_segment_bodies(segmentId, text) VALUES (?, 'preserved 日本語')", arguments: [segmentId])
                try db.execute(
                    sql: "INSERT INTO sync_transactions(id, vaultId, connectionId, createdAt, availableAt) VALUES (?, ?, ?, ?, ?)",
                    arguments: [transactionId, vaultId, connection.id, Date(), Date()]
                )
                try db.execute(
                    sql: "INSERT INTO sync_operations(transactionId, position, id, entity, action, entityId, baseRevision) VALUES (?, 0, ?, 'transcript', 'patch', ?, 0)",
                    arguments: [transactionId, operationId, meetingId]
                )
            }
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.read { db in
                #expect(try String.fetchOne(db, sql: "SELECT text FROM transcript_segment_bodies") == "preserved 日本語")
                #expect(try String.fetchOne(db, sql: "SELECT text FROM sync_transcript_patch_items") == "preserved 日本語")
                let payload = try #require(try String.fetchOne(
                    db,
                    sql: "SELECT payloadJSON FROM sync_operations WHERE id = ?",
                    arguments: [operationId]
                ))
                let mutation = try SyncJSON.decoder.decode(TranscriptMutation.self, from: Data(payload.utf8))
                #expect(mutation.mode == "replace")
                #expect(mutation.transcript.metadata == nil)
                #expect(try TranscriptRecord.current(meetingId, in: db)?.id == mutation.transcript.id)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }
    }
#endif
