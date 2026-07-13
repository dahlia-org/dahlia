import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct BatchTranscriptionConfirmationServiceTests {
        private struct ConfirmationResult {
            let session: RecordingSessionRecord?
            let files: [RecordingAudioFileRecord]
            let ranges: [RecordingAudioRangeRecord]
            let unrelatedRange: RecordingAudioRangeRecord?
        }

        @Test
        func confirmationPreservesMultilingualRangesAndMarksSessionForRecovery() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "BatchConfirmation",
                endedAt: Date(timeIntervalSince1970: 1_776_384_060),
                duration: 60
            )
            defer { fixture.removeFiles() }
            let otherFileId = try await insertConfirmationScenario(in: fixture)

            let confirmation = try await BatchTranscriptionConfirmationService.confirm(
                sessionId: fixture.session.id,
                localeIdentifier: "en_US",
                retainAudioAfterBatch: true,
                dbQueue: fixture.database.dbQueue
            )

            let result = try await loadConfirmationResult(
                sessionId: fixture.session.id,
                otherFileId: otherFileId,
                from: fixture.database.dbQueue
            )
            let session = try #require(result.session)
            #expect(confirmation.meetingId == fixture.meeting.id)
            #expect(confirmation.sessionIds == [fixture.session.id])
            #expect(result.files.count == 2)
            #expect(result.ranges.count == 3)
            #expect(result.ranges.map(\.localeIdentifier).sorted() == ["fr_FR", "ja_JP", "ja_JP"])
            #expect(result.unrelatedRange?.localeIdentifier == "ja_JP")
            #expect(session.batchLastAttemptAt != nil)
            #expect(session.batchAttemptCount == 0)
            #expect(session.retainAudioAfterBatch)
            #expect(BatchTranscriptionState.derive(from: session) == .queued(sessionId: session.id))
            #expect(BatchTranscriptionCoordinator.shouldAutomaticallyRetry(session))
        }

        @Test
        func confirmationReplacesSingleRecordedLocale() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "BatchSingleLocaleConfirmation",
                endedAt: Date(timeIntervalSince1970: 1_776_384_060),
                duration: 60,
                retainAudioAfterBatch: true
            )
            defer { fixture.removeFiles() }
            let file = fixture.makeAudioRecord(finalizedAt: fixture.now, totalFrameCount: 320)
            let ranges = [
                makeRange(audioFileId: file.id, startFrame: 0, localeIdentifier: "ja_JP", now: fixture.now),
                makeRange(audioFileId: file.id, startFrame: 160, localeIdentifier: "ja_JP", now: fixture.now),
            ]
            try await fixture.database.dbQueue.write { db in
                try file.insert(db)
                for range in ranges {
                    try range.insert(db)
                }
            }

            _ = try await BatchTranscriptionConfirmationService.confirm(
                sessionId: fixture.session.id,
                localeIdentifier: "en_US",
                retainAudioAfterBatch: false,
                dbQueue: fixture.database.dbQueue
            )

            let result = try await fixture.database.dbQueue.read { db in
                let ranges = try RecordingAudioRangeRecord.order(Column("startFrame").asc).fetchAll(db)
                let session = try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)
                return (ranges, session)
            }
            #expect(result.0.map(\.localeIdentifier) == ["en_US", "en_US"])
            #expect(result.1?.retainAudioAfterBatch == false)
        }

        @Test
        func confirmationIncludesEveryEarlierUnconfirmedSessionInTheMeeting() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "BatchMultipleRecordingConfirmation",
                endedAt: Date(timeIntervalSince1970: 1_776_384_060),
                duration: 60
            )
            defer { fixture.removeFiles() }
            let earlierSession = makeSession(
                meetingId: fixture.meeting.id,
                startedAt: fixture.now.addingTimeInterval(-120),
                endedAt: fixture.now.addingTimeInterval(-60),
                now: fixture.now
            )
            let earlierFile = makeAudioFile(
                sessionId: earlierSession.id,
                source: .microphone,
                name: "earlier.caf",
                now: fixture.now
            )
            let earlierRange = makeRange(
                audioFileId: earlierFile.id,
                startFrame: 0,
                localeIdentifier: "ja_JP",
                now: fixture.now
            )
            let currentFile = fixture.makeAudioRecord(finalizedAt: fixture.now, totalFrameCount: 160)
            let currentRange = makeRange(
                audioFileId: currentFile.id,
                startFrame: 0,
                localeIdentifier: "ja_JP",
                now: fixture.now
            )
            try await fixture.database.dbQueue.write { db in
                try earlierSession.insert(db)
                try earlierFile.insert(db)
                try earlierRange.insert(db)
                try currentFile.insert(db)
                try currentRange.insert(db)
            }

            let confirmation = try await BatchTranscriptionConfirmationService.confirm(
                sessionId: fixture.session.id,
                localeIdentifier: "en_US",
                retainAudioAfterBatch: true,
                dbQueue: fixture.database.dbQueue
            )

            let sessions = try await fixture.database.dbQueue.read { db in
                try RecordingSessionRecord
                    .filter([earlierSession.id, fixture.session.id].contains(Column("id")))
                    .order(Column("startedAt").asc)
                    .fetchAll(db)
            }
            let locales = try await fixture.database.dbQueue.read { db in
                try RecordingAudioRangeRecord
                    .filter([earlierFile.id, currentFile.id].contains(Column("audioFileId")))
                    .fetchAll(db)
                    .map(\.localeIdentifier)
            }
            #expect(confirmation.sessionIds == [earlierSession.id, fixture.session.id])
            #expect(sessions.allSatisfy { $0.batchLastAttemptAt != nil })
            #expect(sessions.allSatisfy { $0.retainAudioAfterBatch })
            #expect(locales.sorted() == ["en_US", "en_US"])
        }

        private func insertConfirmationScenario(in fixture: BatchAudioTestFixture) async throws -> UUID {
            let microphoneFile = fixture.makeAudioRecord(finalizedAt: fixture.now, totalFrameCount: 320)
            let systemFile = makeAudioFile(sessionId: fixture.session.id, source: .system, name: "system.caf", now: fixture.now)
            let otherMeeting = MeetingRecord(
                id: .v7(),
                vaultId: fixture.meeting.vaultId,
                projectId: nil,
                name: "Other Meeting",
                status: .transcriptNotFound,
                duration: 60,
                createdAt: fixture.now,
                updatedAt: fixture.now
            )
            let otherSession = makeSession(
                meetingId: otherMeeting.id,
                startedAt: fixture.now.addingTimeInterval(-120),
                endedAt: fixture.now.addingTimeInterval(-60),
                now: fixture.now
            )
            let otherFile = makeAudioFile(sessionId: otherSession.id, source: .microphone, name: "other.caf", now: fixture.now)
            let ranges = [
                makeRange(audioFileId: microphoneFile.id, startFrame: 0, localeIdentifier: "ja_JP", now: fixture.now),
                makeRange(audioFileId: microphoneFile.id, startFrame: 160, localeIdentifier: "fr_FR", now: fixture.now),
                makeRange(audioFileId: systemFile.id, startFrame: 0, localeIdentifier: "ja_JP", now: fixture.now),
            ]
            let otherRange = makeRange(audioFileId: otherFile.id, startFrame: 0, localeIdentifier: "ja_JP", now: fixture.now)
            try await fixture.database.dbQueue.write { db in
                try otherMeeting.insert(db)
                try otherSession.insert(db)
                try microphoneFile.insert(db)
                try systemFile.insert(db)
                try otherFile.insert(db)
                for range in ranges {
                    try range.insert(db)
                }
                try otherRange.insert(db)
            }
            return otherFile.id
        }

        private func loadConfirmationResult(
            sessionId: UUID,
            otherFileId: UUID,
            from dbQueue: DatabaseQueue
        ) async throws -> ConfirmationResult {
            try await dbQueue.read { db in
                let session = try RecordingSessionRecord.fetchOne(db, key: sessionId)
                let files = try RecordingAudioFileRecord.filter(Column("recordingSessionId") == sessionId).fetchAll(db)
                let ranges = try RecordingAudioRangeRecord
                    .filter(files.map(\.id).contains(Column("audioFileId")))
                    .order(Column("startFrame").asc)
                    .fetchAll(db)
                let otherRange = try RecordingAudioRangeRecord.filter(Column("audioFileId") == otherFileId).fetchOne(db)
                return ConfirmationResult(session: session, files: files, ranges: ranges, unrelatedRange: otherRange)
            }
        }

        private func makeSession(
            meetingId: UUID,
            startedAt: Date,
            endedAt: Date,
            now: Date
        ) -> RecordingSessionRecord {
            RecordingSessionRecord(
                id: .v7(),
                meetingId: meetingId,
                startedAt: startedAt,
                endedAt: endedAt,
                duration: 60,
                offsetSeconds: 0,
                createdAt: now,
                updatedAt: now,
                transcriptionMode: .batch
            )
        }

        private func makeAudioFile(
            sessionId: UUID,
            source: RecordingAudioSource,
            name: String,
            now: Date
        ) -> RecordingAudioFileRecord {
            RecordingAudioFileRecord(
                id: .v7(),
                recordingSessionId: sessionId,
                source: source,
                relativePath: name,
                sampleRate: 16000,
                channelCount: 1,
                finalizedAt: now,
                totalFrameCount: 160,
                createdAt: now,
                updatedAt: now
            )
        }

        private func makeRange(
            audioFileId: UUID,
            startFrame: Int64,
            localeIdentifier: String,
            now: Date
        ) -> RecordingAudioRangeRecord {
            RecordingAudioRangeRecord(
                id: .v7(),
                audioFileId: audioFileId,
                startFrame: startFrame,
                frameCount: 160,
                sessionOffsetSeconds: Double(startFrame) / 16000,
                localeIdentifier: localeIdentifier,
                createdAt: now,
                updatedAt: now
            )
        }
    }
#endif
