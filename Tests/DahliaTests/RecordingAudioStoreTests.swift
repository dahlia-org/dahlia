@preconcurrency import AVFoundation
import Darwin
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    @Suite(.serialized)
    struct RecordingAudioStoreTests {
        @Test
        func recoversRecordingPartialToReady() async throws {
            let fixture = try BatchAudioTestFixture(name: "RecoverRecordingPartial")
            defer { fixture.removeFiles() }
            let ready = try await makeReadySegment(fixture: fixture)
            let finalURL = fixture.managedRootURL.appending(path: ready.finalRelativePath)
            let partialURL = fixture.managedRootURL.appending(path: ready.partialRelativePath)
            try FileManager.default.moveItem(at: finalURL, to: partialURL)
            try await fixture.database.dbQueue.write { db in
                guard var record = try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id) else { return }
                record.state = .recording
                record.sealedFrameCount = nil
                record.byteCount = nil
                record.sha256 = nil
                record.finalizationStartedAt = nil
                record.integrityVerifiedAt = nil
                record.finalizedAt = nil
                try record.update(db)
                try db.execute(
                    sql: "UPDATE recording_audio_segment_ranges SET frameCount = NULL WHERE audioSegmentId = ?",
                    arguments: [ready.id]
                )
            }

            let store = try makeStore(fixture)
            let result = await store.reconcileStartup()
            let recovered = try await fixture.database.dbQueue.read { db in
                try (
                    RecordingAudioSegmentRecord.fetchOne(db, key: ready.id),
                    RecordingSessionRecord.fetchOne(db, key: fixture.session.id)
                )
            }

            #expect(result.recoveredSegmentCount == 1)
            #expect(recovered.0?.state == .ready)
            #expect(recovered.0?.sealedFrameCount == 320)
            #expect(recovered.0?.sha256?.count == 32)
            #expect(recovered.1?.endedAt == fixture.now.addingTimeInterval(0.02))
            #expect(recovered.1?.duration == 0.02)
            #expect(FileManager.default.fileExists(atPath: finalURL.path))
            #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        }

        @Test
        func unreadableRecordingPartialIsPreservedAndMarkedFailed() async throws {
            let fixture = try BatchAudioTestFixture(name: "UnreadableRecordingPartial")
            defer { fixture.removeFiles() }
            let ready = try await makeReadySegment(fixture: fixture)
            let finalURL = fixture.managedRootURL.appending(path: ready.finalRelativePath)
            let partialURL = fixture.managedRootURL.appending(path: ready.partialRelativePath)
            try FileManager.default.moveItem(at: finalURL, to: partialURL)
            try Data("not a caf".utf8).write(to: partialURL)
            try await fixture.database.dbQueue.write { db in
                guard var record = try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id) else { return }
                record.state = .recording
                record.sealedFrameCount = nil
                record.byteCount = nil
                record.sha256 = nil
                record.integrityVerifiedAt = nil
                record.finalizedAt = nil
                try record.update(db)
            }

            let store = try makeStore(fixture)
            let result = await store.reconcileStartup()
            let failed = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id)
            }
            #expect(result.failedSegmentCount == 1)
            #expect(failed?.state == .failed)
            #expect(failed?.failureCode == "unreadablePartial")
            #expect(FileManager.default.fileExists(atPath: partialURL.path))
        }

        @Test
        func renameBeforeReadyCommitRollsForwardOnlyWithCommittedIntegrity() async throws {
            let fixture = try BatchAudioTestFixture(name: "RecoverPublishedFinal")
            defer { fixture.removeFiles() }
            let ready = try await makeReadySegment(fixture: fixture)
            try await fixture.database.dbQueue.write { db in
                guard var record = try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id) else { return }
                record.state = .finalizing
                record.finalizedAt = nil
                try record.update(db)
            }

            let store = try makeStore(fixture)
            let result = await store.reconcileStartup()
            let recovered = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id)
            }
            #expect(result.recoveredSegmentCount == 1)
            #expect(recovered?.state == .ready)

            try await fixture.database.dbQueue.write { db in
                guard var record = try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id) else { return }
                record.state = .finalizing
                record.byteCount = nil
                record.sha256 = nil
                record.integrityVerifiedAt = nil
                record.finalizedAt = nil
                try record.update(db)
                guard var session = try RecordingSessionRecord.fetchOne(db, key: fixture.session.id) else { return }
                session.endedAt = nil
                session.duration = nil
                session.batchLastError = nil
                session.batchFailureKind = nil
                try session.update(db)
            }
            let secondResult = await store.reconcileStartup()
            let failed = try await fixture.database.dbQueue.read { db in
                try (
                    RecordingAudioSegmentRecord.fetchOne(db, key: ready.id),
                    RecordingSessionRecord.fetchOne(db, key: fixture.session.id)
                )
            }
            #expect(secondResult.failedSegmentCount == 1)
            #expect(failed.0?.state == .failed)
            #expect(failed.0?.failureCode == "missingIntegrityMetadata")
            #expect(failed.1?.batchFailureKind == .recordingRecovery)
            #expect(failed.1?.batchLastError?.nilIfBlank != nil)
            #expect(FileManager.default.fileExists(
                atPath: fixture.managedRootURL.appending(path: ready.finalRelativePath).path
            ))
        }

        @Test
        func digestMismatchStopsReadingAndMarksSegmentFailed() async throws {
            let fixture = try BatchAudioTestFixture(name: "DigestMismatch")
            defer { fixture.removeFiles() }
            let ready = try await makeReadySegment(fixture: fixture)
            let finalURL = fixture.managedRootURL.appending(path: ready.finalRelativePath)
            var bytes = try Data(contentsOf: finalURL)
            let index = try #require(bytes.indices.dropLast(8).last)
            bytes[index] ^= 0x01
            try bytes.write(to: finalURL)

            let store = try makeStore(fixture)
            await #expect(throws: (any Error).self) {
                try await store.withVerifiedReadySegments(sessionId: fixture.session.id) { _ in true }
            }
            let failed = try await fixture.database.dbQueue.read { db in
                try (
                    RecordingAudioSegmentRecord.fetchOne(db, key: ready.id),
                    RecordingAudioSourceProgressRecord.fetchOne(db)
                )
            }
            #expect(failed.0?.state == .failed)
            #expect(failed.0?.failureCode == "integrityMismatch")
            #expect(failed.1?.durableThroughOffsetSeconds == 0)
            #expect(failed.1?.lastContiguousReadySegmentIndex == nil)
            #expect(FileManager.default.fileExists(atPath: finalURL.path))
        }

        @Test
        func startupIntegrityFailureMarksAlreadyEndedSessionAsPermanentFailure() async throws {
            let endedAt = Date(timeIntervalSince1970: 1_776_384_001)
            let fixture = try BatchAudioTestFixture(
                name: "EndedSessionIntegrityFailure",
                endedAt: endedAt,
                duration: 1
            )
            defer { fixture.removeFiles() }
            let ready = try await makeReadySegment(fixture: fixture)
            let finalURL = fixture.managedRootURL.appending(path: ready.finalRelativePath)
            var bytes = try Data(contentsOf: finalURL)
            let index = try #require(bytes.indices.dropLast(8).last)
            bytes[index] ^= 0x01
            try bytes.write(to: finalURL)

            let store = try makeStore(fixture)
            let result = await store.reconcileStartup()
            let session = try await fixture.database.dbQueue.read { db in
                try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)
            }

            #expect(result.failedSegmentCount == 1)
            #expect(session?.endedAt == endedAt)
            #expect(session?.batchFailureKind == .recordingRecovery)
            #expect(session?.batchLastError?.nilIfBlank != nil)
            #expect(session.map(BatchTranscriptionCoordinator.shouldAutomaticallyRetry) == false)
        }

        @Test
        func sessionLeaseRejectsDeletionUntilWriterFinishes() async throws {
            let fixture = try BatchAudioTestFixture(name: "LeaseGuard")
            defer { fixture.removeFiles() }
            let recorder = try makeRecorder(fixture)
            let writer = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now
            )
            writer.appendBuffer(try makeBuffer(format: recorder.targetFormat, frameCount: 160))

            let competingStore = try makeStore(fixture)
            await #expect(throws: RecordingAudioStoreError.activeSession) {
                try await competingStore.requestPurge(sessionId: fixture.session.id)
            }

            try await recorder.finish()
            try await competingStore.requestPurge(sessionId: fixture.session.id)
            let purged = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.fetchOne(db)
            }
            #expect(purged?.state == .purged)
            #expect(purged?.purgedAt != nil)
            if let finalPath = purged?.finalRelativePath {
                #expect(!FileManager.default.fileExists(
                    atPath: fixture.managedRootURL.appending(path: finalPath).path
                ))
            }
        }

        @Test
        func destructiveOperationRejectsSymlinkOutsideManagedRoot() async throws {
            let fixture = try BatchAudioTestFixture(name: "SymlinkGuard")
            defer { fixture.removeFiles() }
            let ready = try await makeReadySegment(fixture: fixture)
            let outsideURL = fixture.testRootURL.appending(path: "outside.caf")
            try Data("preserve".utf8).write(to: outsideURL)
            let sessionDirectory = fixture.managedRootURL
                .appending(path: fixture.meeting.id.uuidString)
                .appending(path: fixture.session.id.uuidString)
            let linkURL = sessionDirectory.appending(path: "escape")
            try FileManager.default.createSymbolicLink(
                at: linkURL,
                withDestinationURL: fixture.testRootURL
            )
            try await fixture.database.dbQueue.write { db in
                guard var record = try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id) else { return }
                record.state = .purgePending
                record.finalRelativePath = "\(fixture.meeting.id.uuidString)/\(fixture.session.id.uuidString)/escape/outside.caf"
                record.purgeRequestedAt = .now
                try record.update(db)
            }

            let store = try makeStore(fixture)
            await #expect(throws: RecordingAudioStoreError.invalidPath) {
                try await store.purgePending(sessionId: fixture.session.id)
            }
            #expect(FileManager.default.fileExists(atPath: outsideURL.path))
            let state = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id)?.state
            }
            #expect(state == .purgePending)
        }

        @Test
        func appliesPrivatePermissionsToManagedAudio() async throws {
            let fixture = try BatchAudioTestFixture(name: "Permissions")
            defer { fixture.removeFiles() }
            let ready = try await makeReadySegment(fixture: fixture)
            let finalURL = fixture.managedRootURL.appending(path: ready.finalRelativePath)
            let rootMode = try posixMode(fixture.managedRootURL)
            let fileMode = try posixMode(finalURL)
            #expect(rootMode == 0o700)
            #expect(fileMode == 0o600)
        }

        @Test
        func meetingDeletionRequiresTombstoneBeforeCascade() async throws {
            let fixture = try BatchAudioTestFixture(name: "MeetingDeletion")
            defer { fixture.removeFiles() }
            let ready = try await makeReadySegment(fixture: fixture)
            let finalURL = fixture.managedRootURL.appending(path: ready.finalRelativePath)
            let repository = MeetingRepository(dbQueue: fixture.database.dbQueue)

            #expect(throws: RecordingAudioStoreError.invalidState) {
                try repository.deleteMeeting(id: fixture.meeting.id)
            }
            #expect(FileManager.default.fileExists(atPath: finalURL.path))
            #expect(try repository.fetchMeeting(id: fixture.meeting.id) != nil)

            try await repository.deleteMeetingSafely(
                id: fixture.meeting.id,
                managedRootURL: fixture.managedRootURL
            )
            #expect(!FileManager.default.fileExists(atPath: finalURL.path))
            #expect(try repository.fetchMeeting(id: fixture.meeting.id) == nil)
        }

        @Test
        func finalizingPartialWithCommittedIntegrityResumesPublish() async throws {
            let fixture = try BatchAudioTestFixture(name: "ResumeFinalizingPartial")
            defer { fixture.removeFiles() }
            let ready = try await makeReadySegment(fixture: fixture)
            let finalURL = fixture.managedRootURL.appending(path: ready.finalRelativePath)
            let partialURL = fixture.managedRootURL.appending(path: ready.partialRelativePath)
            try FileManager.default.moveItem(at: finalURL, to: partialURL)
            try await fixture.database.dbQueue.write { db in
                guard var record = try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id) else { return }
                record.state = .finalizing
                record.finalizedAt = nil
                try record.update(db)
            }

            let store = try makeStore(fixture)
            let result = await store.reconcileStartup()
            let current = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id)
            }
            #expect(result.recoveredSegmentCount == 1)
            #expect(current?.state == .ready)
            #expect(FileManager.default.fileExists(atPath: finalURL.path))
            #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        }

        @Test
        func duplicateMatchingPartialIsPreservedAndAudited() async throws {
            let fixture = try BatchAudioTestFixture(name: "DuplicatePartial")
            defer { fixture.removeFiles() }
            let ready = try await makeReadySegment(fixture: fixture)
            let finalURL = fixture.managedRootURL.appending(path: ready.finalRelativePath)
            let partialURL = fixture.managedRootURL.appending(path: ready.partialRelativePath)
            try FileManager.default.copyItem(at: finalURL, to: partialURL)
            try await fixture.database.dbQueue.write { db in
                guard var record = try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id) else { return }
                record.state = .finalizing
                record.finalizedAt = nil
                try record.update(db)
            }

            let store = try makeStore(fixture)
            let result = await store.reconcileStartup()
            let databaseState = try await fixture.database.dbQueue.read { db in
                try (
                    RecordingAudioSegmentRecord.fetchOne(db, key: ready.id),
                    RecordingAudioReconciliationIssueRecord.fetchAll(db)
                )
            }
            #expect(result.recoveredSegmentCount == 1)
            #expect(databaseState.0?.state == .ready)
            #expect(databaseState.1.map(\.reason).contains("duplicatePartialPreserved"))
            #expect(FileManager.default.fileExists(atPath: finalURL.path))
            #expect(FileManager.default.fileExists(atPath: partialURL.path))

            try await store.requestPurge(sessionId: fixture.session.id)
            let purged = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id)
            }
            #expect(purged?.state == .purged)
            #expect(!FileManager.default.fileExists(atPath: finalURL.path))
            #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        }

        @Test
        func purgePreservesMismatchedPartialWhenFinalIsMissing() async throws {
            let fixture = try BatchAudioTestFixture(name: "PurgeUnexpectedPartial")
            defer { fixture.removeFiles() }
            let ready = try await makeReadySegment(fixture: fixture)
            let finalURL = fixture.managedRootURL.appending(path: ready.finalRelativePath)
            let partialURL = fixture.managedRootURL.appending(path: ready.partialRelativePath)
            try FileManager.default.moveItem(at: finalURL, to: partialURL)
            var bytes = try Data(contentsOf: partialURL)
            let index = try #require(bytes.indices.dropLast(8).last)
            bytes[index] ^= 0x01
            try bytes.write(to: partialURL)
            try await fixture.database.dbQueue.write { db in
                guard var record = try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id) else { return }
                record.state = .purgePending
                record.purgeRequestedAt = .now
                try record.update(db)
            }

            let store = try makeStore(fixture)
            await #expect(throws: RecordingAudioStoreError.ambiguousFiles) {
                try await store.purgePending(sessionId: fixture.session.id)
            }
            let failed = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id)
            }
            #expect(failed?.state == .failed)
            #expect(FileManager.default.fileExists(atPath: partialURL.path))
        }

        @Test
        func purgePendingDeletesVerifiedPartialAfterFinalWasAlreadyUnlinked() async throws {
            let fixture = try BatchAudioTestFixture(name: "PurgeVerifiedPartial")
            defer { fixture.removeFiles() }
            let ready = try await makeReadySegment(fixture: fixture)
            let finalURL = fixture.managedRootURL.appending(path: ready.finalRelativePath)
            let partialURL = fixture.managedRootURL.appending(path: ready.partialRelativePath)
            try FileManager.default.moveItem(at: finalURL, to: partialURL)
            try await fixture.database.dbQueue.write { db in
                guard var record = try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id) else { return }
                record.state = .purgePending
                record.purgeRequestedAt = .now
                try record.update(db)
            }

            let store = try makeStore(fixture)
            try await store.purgePending(sessionId: fixture.session.id)
            let purged = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id)
            }
            #expect(purged?.state == .purged)
            #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        }

        @Test
        func purgePendingConvergesWhenPayloadAlreadyAbsent() async throws {
            let fixture = try BatchAudioTestFixture(name: "PurgeAfterUnlinkCrash")
            defer { fixture.removeFiles() }
            let ready = try await makeReadySegment(fixture: fixture)
            let finalURL = fixture.managedRootURL.appending(path: ready.finalRelativePath)
            try FileManager.default.removeItem(at: finalURL)
            try await fixture.database.dbQueue.write { db in
                guard var record = try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id) else { return }
                record.state = .purgePending
                record.purgeRequestedAt = .now
                try record.update(db)
            }

            let store = try makeStore(fixture)
            let result = await store.reconcileStartup()
            let current = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id)
            }
            #expect(result.purgedSegmentCount == 1)
            #expect(current?.state == .purged)
            #expect(current?.purgedAt != nil)
        }

        @Test
        func finalizingBarrierFailureNeverPublishesPartial() async throws {
            let fixture = try BatchAudioTestFixture(name: "FinalizingBarrierFailure")
            defer { fixture.removeFiles() }
            let recorder = try makeRecorder(fixture)
            let writer = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now
            )
            writer.appendBuffer(try makeBuffer(format: recorder.targetFormat, frameCount: 160))
            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: """
                CREATE TRIGGER reject_finalizing_barrier
                BEFORE UPDATE ON recording_audio_segments
                WHEN NEW.state = 'finalizing'
                BEGIN SELECT RAISE(ABORT, 'fault before finalizing barrier'); END
                """)
            }
            await #expect(throws: (any Error).self) { try await recorder.finish() }
            let state = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.fetchOne(db)
            }
            let segment = try #require(state)
            #expect(segment.state == .recording)
            #expect(FileManager.default.fileExists(
                atPath: fixture.managedRootURL.appending(path: segment.partialRelativePath).path
            ))
            #expect(!FileManager.default.fileExists(
                atPath: fixture.managedRootURL.appending(path: segment.finalRelativePath).path
            ))
        }

        @Test
        func integrityBarrierFailureLeavesRetryableFinalizingPartial() async throws {
            let fixture = try BatchAudioTestFixture(name: "IntegrityBarrierFailure")
            defer { fixture.removeFiles() }
            let recorder = try makeRecorder(fixture)
            let writer = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now
            )
            writer.appendBuffer(try makeBuffer(format: recorder.targetFormat, frameCount: 160))
            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: """
                CREATE TRIGGER reject_integrity_barrier
                BEFORE UPDATE ON recording_audio_segments
                WHEN NEW.integrityVerifiedAt IS NOT NULL AND OLD.integrityVerifiedAt IS NULL
                BEGIN SELECT RAISE(ABORT, 'fault before integrity barrier'); END
                """)
            }
            await #expect(throws: (any Error).self) { try await recorder.finish() }
            let interrupted = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.fetchOne(db)
            }
            let segment = try #require(interrupted)
            #expect(segment.state == .finalizing)
            #expect(segment.sha256 == nil)
            #expect(FileManager.default.fileExists(
                atPath: fixture.managedRootURL.appending(path: segment.partialRelativePath).path
            ))
            #expect(!FileManager.default.fileExists(
                atPath: fixture.managedRootURL.appending(path: segment.finalRelativePath).path
            ))

            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: "DROP TRIGGER reject_integrity_barrier")
            }
            let store = try makeStore(fixture)
            let result = await store.reconcileStartup()
            #expect(result.recoveredSegmentCount == 1)
        }

        @Test
        func readyCommitFailureLeavesAuthenticatedFinalForRecovery() async throws {
            let fixture = try BatchAudioTestFixture(name: "ReadyCommitFailure")
            defer { fixture.removeFiles() }
            let recorder = try makeRecorder(fixture)
            let writer = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now
            )
            writer.appendBuffer(try makeBuffer(format: recorder.targetFormat, frameCount: 160))
            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: """
                CREATE TRIGGER reject_ready_commit
                BEFORE UPDATE ON recording_audio_segments
                WHEN NEW.state = 'ready'
                BEGIN SELECT RAISE(ABORT, 'fault before ready commit'); END
                """)
            }
            await #expect(throws: (any Error).self) { try await recorder.finish() }
            let interrupted = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.fetchOne(db)
            }
            let segment = try #require(interrupted)
            #expect(segment.state == .finalizing)
            #expect(segment.sha256?.count == 32)
            #expect(segment.integrityVerifiedAt != nil)
            #expect(!FileManager.default.fileExists(
                atPath: fixture.managedRootURL.appending(path: segment.partialRelativePath).path
            ))
            #expect(FileManager.default.fileExists(
                atPath: fixture.managedRootURL.appending(path: segment.finalRelativePath).path
            ))

            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: "DROP TRIGGER reject_ready_commit")
            }
            let store = try makeStore(fixture)
            let result = await store.reconcileStartup()
            let recovered = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.fetchOne(db, key: segment.id)
            }
            #expect(result.recoveredSegmentCount == 1)
            #expect(recovered?.state == .ready)
        }

        private func makeReadySegment(fixture: BatchAudioTestFixture) async throws -> RecordingAudioSegmentRecord {
            let recorder = try makeRecorder(fixture)
            let writer = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now
            )
            writer.appendBuffer(try makeBuffer(format: recorder.targetFormat, frameCount: 320))
            try await recorder.finish()
            return try await fixture.database.dbQueue.read { db in
                try #require(try RecordingAudioSegmentRecord.fetchOne(db))
            }
        }

        private func makeRecorder(_ fixture: BatchAudioTestFixture) throws -> BatchAudioRecordingSession {
            try BatchAudioRecordingSession(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                meetingId: fixture.meeting.id,
                recordingSessionId: fixture.session.id,
                recordingStartTime: fixture.now,
                sampleRate: 16000,
                configuration: configuration
            )
        }

        private func makeStore(_ fixture: BatchAudioTestFixture) throws -> RecordingAudioStore {
            try RecordingAudioStore(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                configuration: configuration
            )
        }

        private var configuration: RecordingAudioStore.Configuration {
            RecordingAudioStore.Configuration(
                targetSegmentDuration: .seconds(60),
                maximumFinalizingSegmentCountPerSource: 2,
                maximumActiveSegmentDuration: .seconds(600),
                maximumActiveSegmentByteCount: 64 * 1_024 * 1_024,
                minimumAvailableCapacity: 0,
                capacityCheckInterval: .seconds(5)
            )
        }

        private func makeBuffer(
            format: AVAudioFormat,
            frameCount: AVAudioFrameCount
        ) throws -> AVAudioPCMBuffer {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
            buffer.frameLength = frameCount
            let channel = try #require(buffer.int16ChannelData?[0])
            for index in 0 ..< Int(frameCount) {
                channel[index] = Int16(index)
            }
            return buffer
        }

        private func posixMode(_ url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return try #require(attributes[.posixPermissions] as? NSNumber).intValue
        }
    }
#endif
