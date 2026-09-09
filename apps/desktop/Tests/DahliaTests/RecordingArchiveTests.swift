@preconcurrency import AVFoundation
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct RecordingArchiveTests {
        @Test(arguments: ["pending", "saved", "corrupt"])
        func localArchiveReplacesCAFOnlyAfterVerification(initialState: String) async throws {
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
            let store = try RecordingAudioStore(dbQueue: fixture.database.dbQueue, managedRootURL: fixture.managedRootURL)
            let originals = try await store.withVerifiedTranscribableSegments(sessionId: fixture.session.id) { $0.map(\.url) }
            if initialState != "pending" {
                let prepared = try await store.withVerifiedTranscribableSegments(sessionId: fixture.session.id) { segments in
                    try RecordingArchiveEncoder.encode(segments, relativePath: "archives/existing.m4a", root: fixture.managedRootURL)
                }
                let json = try String(decoding: SyncJSON.encoder.encode(["mic": prepared]), as: UTF8.self)
                try await fixture.database.dbQueue.write { db in
                    try db.execute(
                        sql: "UPDATE recording_archives SET state = 'saved', preparedJSON = ? WHERE sessionId = ?",
                        arguments: [json, fixture.session.id]
                    )
                }
                if initialState == "corrupt" {
                    try Data("broken audio".utf8).write(to: fixture.managedRootURL.appending(path: prepared.relativePath))
                }
            }
            let service = RecordingArchiveService(dbQueue: fixture.database.dbQueue, root: fixture.managedRootURL)
            try await service.runNext(localOnly: true)
            let archive = try await fixture.database.dbQueue.read { db in
                try #require(try RecordingArchiveRecord.fetchOne(db, key: fixture.session.id))
            }
            if initialState == "corrupt" {
                #expect(archive.state == "failed")
                #expect(originals.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
                return
            }
            #expect(archive.state == "saved")
            #expect(originals.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
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
            #expect(count == 0)
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

        @Test(arguments: [false, true])
        func interruptedSourcePurgeKeepsArchiveReadableAndRetries(serverRetry: Bool) async throws {
            let fixture = try BatchAudioTestFixture(name: "ArchivePurgeRetry")
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            let recorder = try BatchAudioRecordingSession(
                dbQueue: fixture.database.dbQueue, managedRootURL: fixture.managedRootURL,
                meetingId: fixture.meeting.id, recordingSessionId: fixture.session.id,
                recordingStartTime: fixture.now, sampleRate: 16000,
                configuration: .init(
                    targetSegmentDuration: .seconds(30),
                    maximumFinalizingSegmentCountPerSource: 2,
                    maximumActiveSegmentDuration: .seconds(600),
                    maximumActiveSegmentByteCount: 64 * 1024 * 1024,
                    minimumAvailableCapacity: 0,
                    capacityCheckInterval: .seconds(5)
                )
            )
            let writer = try await recorder.beginRange(source: .system, locale: Locale(identifier: "ja_JP"), at: fixture.now)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: recorder.targetFormat, frameCapacity: 160))
            buffer.frameLength = 160
            writer.appendBuffer(buffer)
            try await recorder.finish()
            let sources = try await fixture.database.dbQueue.write { db in
                try RecordingArchiveRecord.enqueue(fixture.session, in: db)
                try db.execute(
                    sql: "UPDATE recording_sessions SET endedAt = ?, batchCompletedAt = ? WHERE id = ?",
                    arguments: [fixture.now, fixture.now, fixture.session.id]
                )
                return try RecordingAudioSegmentRecord.fetchAll(db)
            }
            let system = try #require(sources.first { $0.source == .system })
            let systemURL = fixture.managedRootURL.appending(path: system.finalRelativePath)
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: systemURL.path)
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: systemURL.path) }
            let service = RecordingArchiveService(dbQueue: fixture.database.dbQueue, root: fixture.managedRootURL)
            try await service.runNext(localOnly: true)
            try await fixture.database.dbQueue.read { db in
                let archive = try #require(try RecordingArchiveRecord.fetchOne(db, key: fixture.session.id))
                #expect(archive.state == "saved")
                #expect(archive.retryAt != nil)
                #expect(try RecordingArchiveRecord.isAvailable(sessionId: fixture.session.id, in: db))
                let segments = try RecordingAudioSegmentRecord.fetchAll(db)
                #expect(segments.contains { $0.state == .purgePending })
                #expect(segments.contains { $0.state == .purged })
            }
            try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: systemURL.path)
            _ = try await BatchTranscriptionConfirmationService.confirmRetranscription(
                sessionIds: [fixture.session.id], languageSelection: .manual(localeIdentifier: "en_US"),
                automaticLanguageCandidates: nil, dbQueue: fixture.database.dbQueue
            )
            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: fixture.database.dbQueue, managedRootURL: fixture.managedRootURL,
                speechRecognizer: TestBatchSpeechRecognizer(), audioRetentionPeriod: .forever,
                supportedLocalesProvider: { testSupportedSpeechLocales }, onStateChange: { _ in }
            )
            await coordinator.enqueue(sessionId: fixture.session.id)
            #expect(await pollUntil {
                await (try? fixture.database.dbQueue.read { db in
                    let session = try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)
                    return session?.batchCompletedAt.map { $0 > fixture.now } == true && session?.batchLastError == nil
                }) == true
            })
            try await coordinator.shutdown()
            var retryService = service
            if serverRetry {
                let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://archive.invalid", clientID: "test", createdAt: fixture.now)
                try await fixture.database.dbQueue.write { db in
                    try connection.insert(db)
                    try db.execute(
                        sql: "UPDATE vaults SET accountConnectionId = ?, syncConfirmedConnectionId = ? WHERE id = ?",
                        arguments: [connection.id, connection.id, fixture.meeting.vaultId]
                    )
                    let archive = try #require(try RecordingArchiveRecord.fetchOne(db, key: fixture.session.id))
                    let files = try SyncJSON.decoder.decode([String: RecordingArchiveEncoder.Prepared].self, from: Data(archive.preparedJSON.utf8))
                    let audio = files.mapValues {
                        RecordingArchivedAudio(contentType: "audio/mp4", size: $0.size, checksum: $0.checksum, contentURL: "", manifest: $0.manifest)
                    }
                    let json = try String(decoding: SyncJSON.encoder.encode(audio), as: UTF8.self)
                    try db.execute(
                        sql: "UPDATE recording_archives SET connectionId = ?, number = 1, audioJSON = ? WHERE sessionId = ?",
                        arguments: [connection.id, json, fixture.session.id]
                    )
                }
                retryService = RecordingArchiveService(
                    dbQueue: fixture.database.dbQueue,
                    api: SyncAPIClient(session: .shared, tokenProvider: { _, _ in throw URLError(.notConnectedToInternet) }),
                    root: fixture.managedRootURL
                )
            }
            // Repeated unlink failure must stay in cleanup, including when Server access is unavailable.
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: systemURL.path)
            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: "UPDATE recording_archives SET retryAt = NULL WHERE sessionId = ?", arguments: [fixture.session.id])
            }
            try await retryService.runNext(localOnly: !serverRetry)
            try await fixture.database.dbQueue.read { db in
                let archive = try #require(try RecordingArchiveRecord.fetchOne(db, key: fixture.session.id))
                #expect(archive.state == "saved")
                #expect(archive.failureCode == "source_purge_failed")
                #expect(archive.retryAt != nil)
                #expect(try RecordingArchiveRecord.isAvailable(sessionId: fixture.session.id, in: db))
            }
            try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: systemURL.path)
            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: "UPDATE recording_archives SET retryAt = NULL WHERE sessionId = ?", arguments: [fixture.session.id])
            }
            try await retryService.runNext(localOnly: !serverRetry)
            try await fixture.database.dbQueue.read { db in
                let archive = try #require(try RecordingArchiveRecord.fetchOne(db, key: fixture.session.id))
                #expect(archive.state == "saved")
                #expect(archive.retryAt == nil)
                #expect(archive.failureCode == nil)
                #expect(try RecordingAudioSegmentRecord.fetchAll(db).allSatisfy { $0.state == .purged })
            }
            #expect(sources.allSatisfy { !FileManager.default.fileExists(atPath: fixture.managedRootURL.appending(path: $0.finalRelativePath).path) })
        }

        @Test
        func archiveRemainsTranscribableAfterAmbiguousCAFCleanup() async throws {
            let fixture = try BatchAudioTestFixture(name: "ArchiveAmbiguousCleanup")
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            let segment = try await fixture.database.dbQueue.write { db in
                try RecordingArchiveRecord.enqueue(fixture.session, in: db)
                try db.execute(
                    sql: "UPDATE recording_sessions SET endedAt = ?, batchCompletedAt = ? WHERE id = ?",
                    arguments: [fixture.now, fixture.now, fixture.session.id]
                )
                return try #require(try RecordingAudioSegmentRecord.fetchOne(db))
            }
            let partial = fixture.managedRootURL.appending(path: segment.partialRelativePath)
            try Data("mismatched partial".utf8).write(to: partial)
            let service = RecordingArchiveService(dbQueue: fixture.database.dbQueue, root: fixture.managedRootURL)
            try await service.runNext(localOnly: true)
            try await fixture.database.dbQueue.read { db in
                let source = try #require(try RecordingAudioSegmentRecord.fetchOne(db, key: segment.id))
                #expect(source.state == .failed)
                #expect(source.failureCode == "ambiguousFiles")
                #expect(source.purgeRequestedAt != nil)
                #expect(try RecordingArchiveRecord.isAvailable(sessionId: fixture.session.id, in: db))
            }
            #expect(FileManager.default.fileExists(atPath: partial.path))
            _ = try await BatchTranscriptionConfirmationService.confirmRetranscription(
                sessionIds: [fixture.session.id], languageSelection: .manual(localeIdentifier: "en_US"),
                automaticLanguageCandidates: nil, dbQueue: fixture.database.dbQueue
            )
            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: fixture.database.dbQueue, managedRootURL: fixture.managedRootURL,
                speechRecognizer: TestBatchSpeechRecognizer(), audioRetentionPeriod: .forever,
                supportedLocalesProvider: { testSupportedSpeechLocales }, onStateChange: { _ in }
            )
            await coordinator.enqueue(sessionId: fixture.session.id)
            #expect(await pollUntil {
                await (try? fixture.database.dbQueue.read { db in
                    let session = try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)
                    return session?.batchCompletedAt.map { $0 > fixture.now } == true && session?.batchLastError == nil
                }) == true
            })
            try await coordinator.shutdown()
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
                #expect(try RemoteChangePolicy.permits(.recording, id: sessionId, record: payload, vaultId: fixture.meeting.vaultId, in: db))
                try SyncTransactionQueue.applyCanonical(.recording, id: sessionId, vaultId: fixture.meeting.vaultId, value: payload, in: db)
                #expect(try RecordingArchiveRecord.isAvailable(sessionId: sessionId, in: db))
                #expect(try RecordingArchiveRecord.fetchOne(db, key: sessionId)?.number == 12)
                #expect(try RecordingSessionRecord.fetchOne(db, key: sessionId)?.batchCompletedAt != nil)
                try SyncTransactionRecorder.record(vaultId: fixture.meeting.vaultId, operations: [
                    SyncOperationDraft(entity: .recording, action: .upsert, entityId: sessionId, payloadJSON: Data("{}".utf8)),
                ], in: db)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_operations WHERE entity = 'recording'") == 1)
                #expect(try !RemoteChangePolicy.permits(.meeting, id: fixture.meeting.id, action: "delete", vaultId: fixture.meeting.vaultId, in: db))
                try SyncTransactionRecorder.record(vaultId: fixture.meeting.vaultId, operations: [
                    SyncOperationDraft(entity: .meeting, action: .delete, entityId: fixture.meeting.id),
                ], in: db)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_operations WHERE entity = 'recording'") == 0)
                #expect(try !RemoteChangePolicy.permits(.recording, id: sessionId, record: payload, vaultId: fixture.meeting.vaultId, in: db))
                #expect(try !RemoteChangePolicy.permits(.recording, id: sessionId, action: "delete", vaultId: fixture.meeting.vaultId, in: db))
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
                try insertLegacyVault(vault, in: db)
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
