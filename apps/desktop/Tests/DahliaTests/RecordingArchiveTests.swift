@preconcurrency import AVFoundation
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct RecordingArchiveTests {
        @Test
        func localArchiveRoundTripPreservesShortTailRangesAndOriginal() async throws {
            let fixture = try BatchAudioTestFixture(name: "ArchiveRoundTrip")
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            try await fixture.database.dbQueue.write { db in
                try RecordingArchiveRecord.enqueue(fixture.session, in: db)
                try db.execute(
                    sql: "UPDATE recording_sessions SET endedAt = ?, batchCompletedAt = ? WHERE id = ?",
                    arguments: [fixture.now, fixture.now, fixture.session.id]
                )
            }
            let service = RecordingArchiveService(dbQueue: fixture.database.dbQueue, root: fixture.managedRootURL)
            try await service.runNext(localOnly: true)
            let archive = try await fixture.database.dbQueue.read { db in
                try #require(try RecordingArchiveRecord.fetchOne(db, key: fixture.session.id))
            }
            #expect(archive.state == "saved")
            #expect(archive.failureCode == nil)
            let prepared = try SyncJSON.decoder.decode([String: RecordingArchiveEncoder.Prepared].self, from: Data(archive.preparedJSON.utf8))
            let file = try #require(prepared["mic"])
            #expect(file.manifest.frameCount == 160)
            #expect(file.manifest.ranges.count == 1)
            #expect(file.manifest.ranges.first?.localeIdentifier == "ja_JP")
            try await service.withArchivedSegments(sessionId: fixture.session.id) { segments in
                let segment = try #require(segments.first)
                #expect(segments.count == 1)
                #expect(try AVAudioFile(forReading: segment.url).length == 160)
                #expect(segment.ranges.first?.frameCount == 160)
            }
            let count = try await fixture.database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recording_audio_segments WHERE state = 'ready'")
            }
            #expect(count == 1)
            #expect(!RecordingArchiveEncoder.qualityValidatedForSourceDeletion)
            let store = try RecordingAudioStore(dbQueue: fixture.database.dbQueue, managedRootURL: fixture.managedRootURL)
            // Simulate source release in disposable storage to exercise the real retranscription entry point.
            try await store.requestPurge(sessionId: fixture.session.id)
            _ = try await BatchTranscriptionConfirmationService.confirmRetranscription(
                sessionIds: [fixture.session.id], languageSelection: .manual(localeIdentifier: "en_US"),
                automaticLanguageCandidates: nil, dbQueue: fixture.database.dbQueue
            )
            try await service.withArchivedSegments(sessionId: fixture.session.id) { segments in
                #expect(segments.first?.ranges.first?.localeIdentifier == "en_US")
                await #expect(throws: RecordingAudioStoreError.self) { try await store.requestPurge(sessionId: fixture.session.id) }
            }
            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                speechRecognizer: TestBatchSpeechRecognizer(),
                audioRetentionPeriod: .forever,
                supportedLocalesProvider: { testSupportedSpeechLocales },
                onStateChange: { _ in }
            )
            await coordinator.enqueue(sessionId: fixture.session.id)
            #expect(await pollUntil {
                await (try? fixture.database.dbQueue.read { db in
                    let session = try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)
                    return session?.batchCompletedAt.map { $0 > fixture.now } == true && session?.batchLastError == nil
                }) == true
            })
            try await coordinator.shutdown()
            try await store.requestRetentionPurge(sessionId: fixture.session.id, cutoff: Date.now.addingTimeInterval(1))
            #expect(!FileManager.default.fileExists(atPath: fixture.managedRootURL.appending(path: file.relativePath).path))
            #expect(try await fixture.database.dbQueue.read { try RecordingArchiveRecord.fetchOne($0, key: fixture.session.id)?.state } == "expired")
        }

        @Test
        func joinsPhysicalSegmentsPreservingGapAndLanguageBoundary() async throws {
            let fixture = try BatchAudioTestFixture(name: "ArchiveGap")
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            let store = try RecordingAudioStore(dbQueue: fixture.database.dbQueue, managedRootURL: fixture.managedRootURL)
            try await store.withVerifiedTranscribableSegments(sessionId: fixture.session.id) { verified in
                let first = try #require(verified.first)
                var second = first.segment
                second.id = .v7()
                second.segmentIndex += 1
                second.sessionStartOffsetSeconds = 0.1
                var range = try #require(first.ranges.first)
                range.audioSegmentId = second.id
                range.localeIdentifier = "en_US"
                range.sessionOffsetSeconds = 0.1
                let prepared = try RecordingArchiveEncoder.encode(
                    [first, .init(segment: second, url: first.url, ranges: [range])],
                    relativePath: "joined.m4a",
                    root: fixture.managedRootURL
                )
                #expect(prepared.manifest.frameCount == 1760)
                #expect(prepared.manifest.ranges.map(\.startFrame) == [0, 1600])
                #expect(prepared.manifest.ranges.map(\.sessionOffsetSeconds) == [0, 0.1])
                #expect(prepared.manifest.ranges.map(\.localeIdentifier) == ["ja_JP", "en_US"])
                try RecordingArchiveEncoder.validate(fixture.managedRootURL.appending(path: "joined.m4a"), manifest: prepared.manifest)
                second.sessionStartOffsetSeconds = 0.005
                #expect(throws: RecordingAudioStoreError.self) {
                    try RecordingArchiveEncoder.encode(
                        [first, .init(segment: second, url: first.url, ranges: [range])],
                        relativePath: "overlap.m4a",
                        root: fixture.managedRootURL
                    )
                }
            }
        }

        @Test
        func remoteMetadataEnablesOwnerRetranscriptionAndDeletionAbandonsUploads() async throws {
            let fixture = try BatchAudioTestFixture(name: "RemoteArchive")
            defer { fixture.removeFiles() }
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://archive.invalid", clientID: "test", createdAt: fixture.now)
            let sessionId = UUID.v7()
            let payload = try SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: JSONSerialization.data(withJSONObject: [
                "id": 12, "recordingNumber": 12, "meetingId": fixture.meeting.id.uuidString, "sessionId": sessionId.uuidString,
                "startedAt": "2026-09-07T00:00:00Z", "endedAt": "2026-09-07T00:00:01Z",
                "audio": ["mic": [
                    "content_type": "audio/mp4",
                    "size": 128,
                    "checksum": "SHA-256:" + String(repeating: "0", count: 64),
                    "contentURL": "/api/v1/meetings/example/recordings/12/audio/mic",
                    "manifest": [
                        "sampleRate": 16000,
                        "frameCount": 16000,
                        "ranges": [["startFrame": 0, "frameCount": 16000, "sessionOffsetSeconds": 0, "localeIdentifier": "ja_JP"]],
                    ],
                ]],
            ]))
            try await fixture.database.dbQueue.write { db in
                try connection.insert(db)
                try db.execute(
                    sql: "UPDATE vaults SET accountConnectionId = ?, syncConfirmedConnectionId = ? WHERE id = ?",
                    arguments: [connection.id, connection.id, fixture.meeting.vaultId]
                )
                try SyncTransactionQueue.applyCanonical(.recording, id: sessionId, vaultId: fixture.meeting.vaultId, value: payload, in: db)
                #expect(try RecordingArchiveRecord.isAvailable(sessionId: sessionId, in: db))
                #expect(try RecordingArchiveRecord.fetchOne(db, key: sessionId)?.number == 12)
                #expect(try RecordingSessionRecord.fetchOne(db, key: sessionId)?.batchCompletedAt != nil)
                try SyncTransactionRecorder.record(vaultId: fixture.meeting.vaultId, operations: [
                    SyncOperationDraft(entity: .recording, action: .upsert, entityId: sessionId, payloadJSON: Data("{}".utf8)),
                ], in: db)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_operations WHERE entity = 'recording'") == 1)
                try SyncTransactionRecorder.record(vaultId: fixture.meeting.vaultId, operations: [
                    SyncOperationDraft(entity: .meeting, action: .delete, entityId: fixture.meeting.id),
                ], in: db)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_operations WHERE entity = 'recording'") == 0)
                try db.execute(sql: "UPDATE vaults SET syncRole = 'member' WHERE id = ?", arguments: [fixture.meeting.vaultId])
                #expect(try !RecordingArchiveRecord.isAvailable(sessionId: sessionId, in: db))
            }
        }

        @Test
        func migrationPreservesExistingMeetingAndDoesNotEnqueueHistory() throws {
            let queue = try DatabaseQueue(path: ":memory:")
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v47_meetingEvents")
            let transactionId = UUID.v7()
            let operationId = UUID.v7()
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://migration.invalid", clientID: "test", createdAt: .now)
            let fixture = try BatchAudioTestFixture(name: "ArchiveMigration")
            defer { fixture.removeFiles() }
            let vault = try fixture.database.dbQueue.read { try #require(try VaultRecord.fetchOne($0, key: fixture.meeting.vaultId)) }
            try queue.write { db in
                try vault.insert(db)
                try fixture.meeting.insert(db)
                try fixture.session.insert(db)
                try connection.insert(db)
                try db.execute(
                    sql: "INSERT INTO sync_transactions(id, vaultId, connectionId, createdAt, availableAt) VALUES (?, ?, ?, ?, ?)",
                    arguments: [transactionId, vault.id, connection.id, Date.now, Date.now]
                )
                try db.execute(
                    sql: "INSERT INTO sync_operations(transactionId, position, id, entity, action, entityId, payloadJSON) VALUES (?, 0, ?, 'transcript', 'patch', ?, ?)",
                    arguments: [transactionId, operationId, fixture.meeting.id, "immutable payload"]
                )
                try db.execute(
                    sql: "INSERT INTO sync_transcript_patch_items(operationId, position, action, segmentId, startTime, text, isConfirmed) VALUES (?, 0, 'upsert', ?, ?, 'pending transcript', 1)",
                    arguments: [operationId, UUID.v7(), Date.now]
                )
            }
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.read { db in
                let pendingText = try String.fetchOne(db, sql: "SELECT text FROM sync_transcript_patch_items")
                #expect(pendingText == "pending transcript")
                #expect(try UUID.fetchOne(db, sql: "SELECT id FROM sync_transactions") == transactionId)
                #expect(try String.fetchOne(db, sql: "SELECT payloadJSON FROM sync_operations") == "immutable payload")
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
            #expect(try queue.read { try MeetingRecord.fetchOne($0, key: fixture.meeting.id)?.name } == fixture.meeting.name)
            #expect(try queue.read { try RecordingSessionRecord.fetchOne($0, key: fixture.session.id)?.meetingId } == fixture.meeting.id)
            let columns = try queue.read { try $0.columns(in: "recording_archives").map(\.name) }
            #expect(columns.contains("preparedJSON"))
            #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM recording_archives") } == 0)
        }
    }
#endif
