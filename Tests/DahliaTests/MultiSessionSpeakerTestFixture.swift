import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct MultiSessionSpeakerTestFixture {
        struct PersistedSpeakerSession {
            let speakerId: UUID
            let segmentId: UUID
        }

        let database: AppDatabaseManager
        let meetingId: UUID
        let sessions: [RecordingSessionRecord]
        let recordingStartTime: Date

        static func make(
            name: String,
            sessionDurations: [TimeInterval] = [10, 10, 10]
        ) async throws -> Self {
            let database = try AppDatabaseManager(path: ":memory:")
            let recordingStartTime = Date(timeIntervalSince1970: 1_776_384_000)
            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/dahlia-\(name)-vault",
                name: "Test",
                createdAt: recordingStartTime,
                lastOpenedAt: recordingStartTime
            )
            try await database.dbQueue.write { db in
                try vault.insert(db)
            }

            let initialStore = TranscriptStore()
            initialStore.recordingStartTime = recordingStartTime
            let initialService = try await MeetingPersistenceService.createNew(
                store: initialStore,
                dbQueue: database.dbQueue,
                vaultId: vault.id,
                projectId: nil,
                initialName: name,
                transcriptionMode: .batch,
                persistencePolicy: .deferred,
                retainAudioAfterBatch: true,
                now: { recordingStartTime.addingTimeInterval(sessionDurations[0]) }
            )
            try await stop(initialService)

            var nextStartTime = recordingStartTime.addingTimeInterval(sessionDurations[0] + 60)
            for duration in sessionDurations.dropFirst() {
                let store = TranscriptStore()
                store.recordingStartTime = recordingStartTime
                let endTime = nextStartTime.addingTimeInterval(duration)
                let service = try await MeetingPersistenceService.createAppending(
                    store: store,
                    dbQueue: database.dbQueue,
                    existingMeetingId: initialService.meetingId,
                    recordingStartDate: nextStartTime,
                    transcriptionMode: .batch,
                    persistencePolicy: .deferred,
                    retainAudioAfterBatch: true,
                    now: { endTime }
                )
                try await stop(service)
                nextStartTime = endTime.addingTimeInterval(60)
            }

            let sessions = try await database.dbQueue.read { db in
                try RecordingSessionRecord
                    .filter(Column("meetingId") == initialService.meetingId)
                    .order(Column("offsetSeconds").asc, Column("startedAt").asc)
                    .fetchAll(db)
            }
            return Self(
                database: database,
                meetingId: initialService.meetingId,
                sessions: sessions,
                recordingStartTime: recordingStartTime
            )
        }

        func persistSpeakerAnalysis(
            sessionIndex: Int,
            relativeStartSeconds: TimeInterval = 1,
            relativeEndSeconds: TimeInterval = 2,
            embeddingSpace: SpeakerEmbeddingSpace = multiSessionSpeakerSpace,
            representativeValues: [Float] = multiSessionUnitVector,
            audioSource: RecordingAudioSource = .microphone,
            identityVariant: Int = 0
        ) throws -> PersistedSpeakerSession {
            let session = sessions[sessionIndex]
            let segment = TranscriptSegment(
                sessionId: session.id,
                startTime: session.startedAt.addingTimeInterval(relativeStartSeconds),
                endTime: session.startedAt.addingTimeInterval(relativeEndSeconds),
                text: "Speaker session \(sessionIndex + 1)",
                isConfirmed: true,
                speakerLabel: RecordingAudioSource.microphone.speakerLabel
            )
            let speakerAnalysis = makeSpeakerAnalysis(
                sessionIndex: sessionIndex,
                relativeStartSeconds: relativeStartSeconds,
                relativeEndSeconds: relativeEndSeconds,
                embeddingSpace: embeddingSpace,
                representativeValues: representativeValues,
                audioSource: audioSource,
                identityVariant: identityVariant
            )
            let analysis = speakerAnalysis.analysis
            let speakerId = speakerAnalysis.speakerId
            let assignments = BatchTranscriptionCoordinator.mapSpeakers(
                to: [segment],
                analysis: analysis,
                recordingStartTime: session.startedAt
            )
            let output = BatchProcessingOutput(
                transcriptSegments: [segment],
                speakerAnalysis: analysis,
                transcriptSpeakerAssignments: assignments
            )
            _ = try BatchTranscriptionPersistence.complete(
                sessionId: session.id,
                meetingId: meetingId,
                output: output,
                completedAt: session.endedAt ?? session.startedAt,
                dbQueue: database.dbQueue
            )
            return PersistedSpeakerSession(speakerId: speakerId, segmentId: segment.id)
        }

        func makeSpeakerAnalysis(
            sessionIndex: Int,
            relativeStartSeconds: TimeInterval,
            relativeEndSeconds: TimeInterval,
            embeddingSpace: SpeakerEmbeddingSpace = multiSessionSpeakerSpace,
            representativeValues: [Float] = multiSessionUnitVector,
            audioSource: RecordingAudioSource = .microphone,
            identityVariant: Int = 0
        ) -> (analysis: BatchProcessingOutput.SpeakerAnalysis, speakerId: UUID) {
            let identityOffset = identityVariant * 1_000
            let speakerId = orderedUUID(ordinal: identityOffset + sessionIndex + 1)
            let speaker = BatchProcessingOutput.Speaker(
                id: speakerId,
                localSpeakerId: "speaker-0",
                representative: SpeakerEmbedding(space: embeddingSpace, values: representativeValues),
                representativeQuality: 1,
                representativeSource: .diarization,
                profileUpdateEligible: true,
                exemplars: [],
                spans: [
                    SpeakerDiarizationSpan(
                        speakerID: "speaker-0",
                        startTimeSeconds: relativeStartSeconds,
                        endTimeSeconds: relativeEndSeconds
                    ),
                ]
            )
            let analysis = BatchProcessingOutput.SpeakerAnalysis(sources: [
                BatchProcessingOutput.SourceAnalysis(
                    id: orderedUUID(ordinal: identityOffset + sessionIndex + 101),
                    audioSource: audioSource,
                    embeddingSpace: embeddingSpace,
                    speakers: [speaker],
                    failureReason: nil
                ),
            ])
            return (analysis, speakerId)
        }

        private static func stop(_ service: MeetingPersistenceService) async throws {
            guard case .success = await service.stop() else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        func embeddingSpace(assetFingerprint: String) -> SpeakerEmbeddingSpace {
            SpeakerEmbeddingSpace(
                provider: multiSessionSpeakerSpace.provider,
                modelName: multiSessionSpeakerSpace.modelName,
                revision: multiSessionSpeakerSpace.revision,
                assetFingerprint: assetFingerprint,
                fluidAudioVersion: multiSessionSpeakerSpace.fluidAudioVersion,
                dimensionCount: multiSessionSpeakerSpace.dimensionCount,
                sampleRate: multiSessionSpeakerSpace.sampleRate,
                preprocessing: multiSessionSpeakerSpace.preprocessing,
                excludesOverlap: multiSessionSpeakerSpace.excludesOverlap,
                normalization: multiSessionSpeakerSpace.normalization,
                similarityDefinition: multiSessionSpeakerSpace.similarityDefinition
            )
        }

        func unitVector(axis: Int) -> [Float] {
            var values = [Float](repeating: 0, count: SpeakerEmbeddingValidation.dimensionCount)
            values[axis] = 1
            return values
        }

        private func orderedUUID(ordinal: Int) -> UUID {
            let suffix = String(format: "%012x", ordinal)
            return UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
        }
    }

    private let multiSessionSpeakerSpace = SpeakerEmbeddingSpace(
        provider: "Test",
        modelName: "multi-session-speaker",
        revision: "1",
        assetFingerprint: "multi-session-fingerprint",
        fluidAudioVersion: "0.15.5",
        dimensionCount: SpeakerEmbeddingValidation.dimensionCount,
        sampleRate: 16_000,
        preprocessing: "mono-float32",
        excludesOverlap: true,
        normalization: "L2 unit norm",
        similarityDefinition: "cosine dot product"
    )

    private let multiSessionUnitVector: [Float] = {
        var values = [Float](repeating: 0, count: SpeakerEmbeddingValidation.dimensionCount)
        values[0] = 1
        return values
    }()
#endif
