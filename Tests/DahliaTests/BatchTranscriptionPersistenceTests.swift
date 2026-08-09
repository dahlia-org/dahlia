import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    // swiftlint:disable:next type_body_length
    struct BatchTranscriptionPersistenceTests {
        private typealias PersistenceState = (
            records: [TranscriptSegmentRecord],
            session: RecordingSessionRecord,
            meeting: MeetingRecord
        )

        @Test
        func completionIsAtomicAndRetryReplacesOnlyItsSession() throws {
            let now = Date(timeIntervalSince1970: 1_776_384_000)
            let fixture = try BatchAudioTestFixture(
                name: "Batch",
                endedAt: now.addingTimeInterval(10),
                duration: 10
            )
            defer { fixture.removeFiles() }
            let staleRecord = makeRecord(
                id: .v7(),
                meetingId: fixture.meeting.id,
                sessionId: fixture.session.id,
                text: "stale",
                now: now
            )
            try fixture.database.dbQueue.write { db in
                try staleRecord.insert(db)
            }

            let duplicateId = UUID.v7()
            let duplicateRecords = [
                makeRecord(id: duplicateId, meetingId: fixture.meeting.id, sessionId: fixture.session.id, text: "first", now: now),
                makeRecord(id: duplicateId, meetingId: fixture.meeting.id, sessionId: fixture.session.id, text: "duplicate", now: now),
            ]
            #expect(throws: (any Error).self) {
                try BatchTranscriptionPersistence.complete(
                    sessionId: fixture.session.id,
                    meetingId: fixture.meeting.id,
                    records: duplicateRecords,
                    completedAt: now.addingTimeInterval(20),
                    dbQueue: fixture.database.dbQueue
                )
            }

            let rolledBack = try fetchState(fixture)
            #expect(rolledBack.records.map(\.text) == ["stale"])
            #expect(rolledBack.session.batchCompletedAt == nil)
            #expect(rolledBack.meeting.status == .transcriptNotFound)

            let completedAt = now.addingTimeInterval(30)
            let finalRecord = makeRecord(
                id: .v7(),
                meetingId: fixture.meeting.id,
                sessionId: fixture.session.id,
                text: "final",
                now: now
            )
            let expectedAudioFeatures = sampleAudioFeatures
            _ = try BatchTranscriptionPersistence.complete(
                sessionId: fixture.session.id,
                meetingId: fixture.meeting.id,
                records: [record(finalRecord, with: expectedAudioFeatures)],
                completedAt: completedAt,
                dbQueue: fixture.database.dbQueue
            )

            let completed = try fetchState(fixture)
            #expect(completed.records.map(\.text) == ["final"])
            #expect(completed.records.first?.audioFeatures == expectedAudioFeatures)
            #expect(completed.session.batchCompletedAt == completedAt)
            #expect(completed.meeting.status == .ready)
        }

        @Test
        // swiftlint:disable:next function_body_length
        func speakerPersistenceFailureRollsBackTranscriptAndSpeakerRowsTogether() throws {
            let fixture = try BatchAudioTestFixture(
                name: "BatchSpeakerRollback",
                endedAt: Date(timeIntervalSince1970: 1_776_384_010),
                duration: 10
            )
            defer { fixture.removeFiles() }
            let segment = TranscriptSegment(
                sessionId: fixture.session.id,
                startTime: fixture.now,
                endTime: fixture.now.addingTimeInterval(1),
                text: "Atomic",
                isConfirmed: true,
                speakerLabel: RecordingAudioSource.microphone.speakerLabel
            )
            let speakerId = UUID.v7()
            let duplicateSpan = SpeakerDiarizationSpan(
                speakerID: "speaker-0",
                startTimeSeconds: 0,
                endTimeSeconds: 1
            )
            let speaker = BatchProcessingOutput.Speaker(
                id: speakerId,
                localSpeakerId: "speaker-0",
                representative: SpeakerEmbedding(space: testSpeakerSpace, values: unitSpeakerVector),
                representativeQuality: 1,
                representativeSource: .diarization,
                profileUpdateEligible: true,
                exemplars: [],
                spans: [duplicateSpan, duplicateSpan]
            )
            let output = BatchProcessingOutput(
                transcriptSegments: [segment],
                speakerAnalysis: BatchProcessingOutput.SpeakerAnalysis(sources: [
                    BatchProcessingOutput.SourceAnalysis(
                        id: .v7(),
                        audioSource: .microphone,
                        embeddingSpace: testSpeakerSpace,
                        speakers: [speaker],
                        failureReason: nil
                    ),
                ]),
                transcriptSpeakerAssignments: [segment.id: speakerId]
            )

            #expect(throws: (any Error).self) {
                try BatchTranscriptionPersistence.complete(
                    sessionId: fixture.session.id,
                    meetingId: fixture.meeting.id,
                    output: output,
                    completedAt: fixture.now.addingTimeInterval(20),
                    dbQueue: fixture.database.dbQueue
                )
            }

            let counts = try fixture.database.dbQueue.read { db in
                try (
                    TranscriptSegmentRecord.fetchCount(db),
                    SpeakerAnalysisRecord.fetchCount(db),
                    MeetingSpeakerRecord.fetchCount(db),
                    SpeakerDiarizationSpanRecord.fetchCount(db)
                )
            }
            #expect(counts == (0, 0, 0, 0))
        }

        @Test
        func speakerQualityIsPersistedForRepresentativesAndExemplars() throws {
            let fixture = try BatchAudioTestFixture(
                name: "BatchSpeakerQuality",
                endedAt: Date(timeIntervalSince1970: 1_776_384_010),
                duration: 10
            )
            defer { fixture.removeFiles() }
            let embedding = SpeakerEmbedding(space: testSpeakerSpace, values: unitSpeakerVector)
            let speakers = [
                makeSpeaker(localId: "high", embedding: embedding, quality: 0.75),
                makeSpeaker(localId: "low", embedding: embedding, quality: 0.25),
                makeSpeaker(localId: "policy-ineligible", embedding: embedding, quality: 0, profileUpdateEligible: false),
            ]
            let output = BatchProcessingOutput(
                transcriptSegments: [],
                speakerAnalysis: BatchProcessingOutput.SpeakerAnalysis(sources: [
                    BatchProcessingOutput.SourceAnalysis(
                        id: .v7(),
                        audioSource: .microphone,
                        embeddingSpace: testSpeakerSpace,
                        speakers: speakers,
                        failureReason: nil
                    ),
                ]),
                transcriptSpeakerAssignments: [:]
            )

            _ = try BatchTranscriptionPersistence.complete(
                sessionId: fixture.session.id,
                meetingId: fixture.meeting.id,
                output: output,
                completedAt: fixture.now.addingTimeInterval(20),
                dbQueue: fixture.database.dbQueue
            )

            let persisted = try fixture.database.dbQueue.read { db in
                let speakers = try MeetingSpeakerRecord.order(Column("localSpeakerId")).fetchAll(db)
                let exemplars = try MeetingSpeakerExemplarRecord.fetchAll(db)
                return (speakers, exemplars)
            }
            #expect(persisted.0.map(\.localSpeakerId) == ["high", "low", "policy-ineligible"])
            #expect(persisted.0.map(\.representativeQuality) == [0.75, 0.25, 0])
            #expect(Set(persisted.1.map(\.quality)) == [0.75, 0.25])
        }

        @Test
        // swiftlint:disable:next function_body_length
        func retranscribingWithSpeakerIdentificationOffRemovesEvidenceRecomputesProfilesAndInvalidatesCache() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "BatchSpeakerOnThenOff",
                endedAt: Date(timeIntervalSince1970: 1_776_384_010),
                duration: 10
            )
            defer { fixture.removeFiles() }
            let speaker = makeSpeaker(
                localId: "speaker-0",
                embedding: SpeakerEmbedding(space: testSpeakerSpace, values: unitSpeakerVector),
                quality: 0.75
            )
            let firstCompletedAt = fixture.now.addingTimeInterval(20)
            _ = try BatchTranscriptionPersistence.complete(
                sessionId: fixture.session.id,
                meetingId: fixture.meeting.id,
                output: BatchProcessingOutput(
                    transcriptSegments: [],
                    speakerAnalysis: BatchProcessingOutput.SpeakerAnalysis(sources: [
                        BatchProcessingOutput.SourceAnalysis(
                            id: .v7(),
                            audioSource: .microphone,
                            embeddingSpace: testSpeakerSpace,
                            speakers: [speaker],
                            failureReason: nil
                        ),
                    ]),
                    transcriptSpeakerAssignments: [:]
                ),
                completedAt: firstCompletedAt,
                dbQueue: fixture.database.dbQueue
            )
            let identity = try attachSpeakerToProfile(
                speakerId: speaker.id,
                fixture: fixture,
                updatedAt: firstCompletedAt
            )
            let cache = SpeakerProfileCache()
            let cacheKey = SpeakerProfileCacheKey(
                vaultId: fixture.meeting.vaultId,
                embeddingSpaceId: identity.embeddingSpaceId
            )
            let counter = BatchCompletionCacheLoadCounter()
            _ = try await cache.profiles(for: cacheKey) {
                await counter.increment()
                return []
            }
            try await fixture.database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE recording_sessions SET batchLastAttemptAt = ? WHERE id = ?",
                    arguments: [firstCompletedAt.addingTimeInterval(1), fixture.session.id]
                )
            }

            let cacheKeys = try BatchTranscriptionPersistence.complete(
                sessionId: fixture.session.id,
                meetingId: fixture.meeting.id,
                records: [],
                completedAt: firstCompletedAt.addingTimeInterval(2),
                dbQueue: fixture.database.dbQueue
            )
            MeetingRepository(dbQueue: fixture.database.dbQueue, speakerProfileCache: cache)
                .invalidateSpeakerProfilesAfterCommit(cacheKeys)
            _ = try await cache.profiles(for: cacheKey) {
                await counter.increment()
                return []
            }

            let counts = try await fixture.database.dbQueue.read { db in
                try (
                    SpeakerAnalysisRecord.fetchCount(db),
                    MeetingSpeakerRecord.fetchCount(db),
                    MeetingSpeakerExemplarRecord.fetchCount(db),
                    SpeakerDiarizationSpanRecord.fetchCount(db),
                    SpeakerContactAssignmentRecord.fetchCount(db)
                )
            }
            #expect(counts == (0, 0, 0, 0, 0))
            #expect(try speakerProfileCount(for: identity.evidence, dbQueue: fixture.database.dbQueue) == 0)
            #expect(await counter.value == 2)
        }

        private var sampleAudioFeatures: TranscriptAudioFeatures {
            TranscriptAudioFeatures(
                activeRmsDecibels: -16,
                medianPitchHertz: 210,
                voicedFrameRatio: 0.8,
                pitchSpreadHertz: 35
            )
        }

        private func makeSpeaker(
            localId: String,
            embedding: SpeakerEmbedding,
            quality: Float,
            profileUpdateEligible: Bool = true
        ) -> BatchProcessingOutput.Speaker {
            BatchProcessingOutput.Speaker(
                id: .v7(),
                localSpeakerId: localId,
                representative: embedding,
                representativeQuality: quality,
                representativeSource: profileUpdateEligible ? .diarization : .speakerDatabase,
                profileUpdateEligible: profileUpdateEligible,
                exemplars: profileUpdateEligible
                    ? [SpeakerEmbeddingExemplar(embedding: embedding, quality: quality)]
                    : [],
                spans: []
            )
        }

        private func attachSpeakerToProfile(
            speakerId: UUID,
            fixture: BatchAudioTestFixture,
            updatedAt: Date
        ) throws -> (embeddingSpaceId: UUID, evidence: SpeakerDeletionEvidence) {
            try fixture.database.dbQueue.write { db in
                let analysis = try #require(try SpeakerAnalysisRecord.fetchOne(db))
                let embeddingSpaceId = try #require(analysis.embeddingSpaceId)
                let contactId = UUID.v7()
                try ContactRecord(
                    id: contactId,
                    vaultId: fixture.meeting.vaultId,
                    email: nil,
                    displayName: "Speaker",
                    revision: 1,
                    createdAt: updatedAt,
                    updatedAt: updatedAt
                ).insert(db)
                try SpeakerContactAssignmentRecord(
                    meetingSpeakerId: speakerId,
                    contactId: contactId,
                    origin: .manual,
                    createdAt: updatedAt,
                    updatedAt: updatedAt
                ).insert(db)
                let space = try #require(try SpeakerEmbeddingSpaceRecord.fetchOne(db, key: embeddingSpaceId))
                try SpeakerProfileRecalculator.recompute(
                    contactId: contactId,
                    vaultId: fixture.meeting.vaultId,
                    embeddingSpace: space,
                    now: updatedAt,
                    in: db
                )
                return (
                    embeddingSpaceId,
                    SpeakerDeletionEvidence(contactId: contactId, embeddingSpaceId: embeddingSpaceId)
                )
            }
        }

        private func record(
            _ record: TranscriptSegmentRecord,
            with audioFeatures: TranscriptAudioFeatures
        ) -> TranscriptSegmentRecord {
            var record = record
            record.audioFeatureVersion = audioFeatures.version
            record.audioActiveRmsDecibels = audioFeatures.activeRmsDecibels
            record.audioMedianPitchHertz = audioFeatures.medianPitchHertz
            record.audioVoicedFrameRatio = audioFeatures.voicedFrameRatio
            record.audioPitchSpreadHertz = audioFeatures.pitchSpreadHertz
            return record
        }

        private func fetchState(_ fixture: BatchAudioTestFixture) throws -> PersistenceState {
            try fixture.database.dbQueue.read { db in
                let records = try TranscriptSegmentRecord
                    .filter(Column("sessionId") == fixture.session.id)
                    .fetchAll(db)
                let currentSession = try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)
                let currentMeeting = try MeetingRecord.fetchOne(db, key: fixture.meeting.id)
                let session = try #require(currentSession)
                let meeting = try #require(currentMeeting)
                return (records, session, meeting)
            }
        }

        private func makeRecord(
            id: UUID,
            meetingId: UUID,
            sessionId: UUID,
            text: String,
            now: Date
        ) -> TranscriptSegmentRecord {
            TranscriptSegmentRecord(
                id: id,
                meetingId: meetingId,
                sessionId: sessionId,
                startTime: now,
                endTime: now.addingTimeInterval(1),
                text: text,
                translatedText: nil,
                isConfirmed: true,
                speakerLabel: "mic"
            )
        }
    }

    private actor BatchCompletionCacheLoadCounter {
        private(set) var value = 0

        func increment() {
            value += 1
        }
    }
#endif

private let testSpeakerSpace = SpeakerEmbeddingSpace(
    provider: "Test",
    modelName: "speaker",
    revision: "1",
    assetFingerprint: "fingerprint",
    fluidAudioVersion: "0.15.5",
    dimensionCount: SpeakerEmbeddingValidation.dimensionCount,
    sampleRate: 16_000,
    preprocessing: "mono-float32",
    excludesOverlap: true,
    normalization: "L2 unit norm",
    similarityDefinition: "cosine dot product"
)

private let unitSpeakerVector: [Float] = {
    var values = [Float](repeating: 0, count: SpeakerEmbeddingValidation.dimensionCount)
    values[0] = 1
    return values
}()
