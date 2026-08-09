import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SpeakerDeletionEvidence {
        let contactId: UUID
        let embeddingSpaceId: UUID
    }

    // The complete fixture transaction is kept together so the profile can never observe partial evidence.
    // swiftlint:disable:next function_body_length
    func insertSpeakerDeletionEvidence(
        sessionId: UUID,
        dbQueue: DatabaseQueue
    ) throws -> SpeakerDeletionEvidence {
        let contactId = UUID.v7()
        let embeddingSpaceId = UUID.v7()
        let analysisId = UUID.v7()
        let speakerId = UUID.v7()
        let now = Date.now
        let space = SpeakerEmbeddingSpace(
            provider: "Test",
            modelName: "speaker-deletion",
            revision: "1",
            assetFingerprint: "deletion-fingerprint",
            fluidAudioVersion: "0.15.5",
            dimensionCount: SpeakerEmbeddingValidation.dimensionCount,
            sampleRate: 16_000,
            preprocessing: "mono-float32",
            excludesOverlap: true,
            normalization: "L2 unit norm",
            similarityDefinition: "cosine dot product"
        )
        var values = [Float](repeating: 0, count: SpeakerEmbeddingValidation.dimensionCount)
        values[0] = 1
        try dbQueue.write { db in
            let session = try #require(try RecordingSessionRecord.fetchOne(db, key: sessionId))
            let meeting = try #require(try MeetingRecord.fetchOne(db, key: session.meetingId))
            try ContactRecord(
                id: contactId,
                vaultId: meeting.vaultId,
                email: nil,
                displayName: "Deletion evidence",
                revision: 1,
                createdAt: now,
                updatedAt: now
            ).insert(db)
            let spaceRecord = SpeakerEmbeddingSpaceRecord(id: embeddingSpaceId, space: space, createdAt: now)
            try spaceRecord.insert(db)
            try SpeakerAnalysisRecord(
                id: analysisId,
                recordingSessionId: sessionId,
                audioSource: .microphone,
                embeddingSpaceId: embeddingSpaceId,
                state: .succeeded,
                failureReason: nil,
                createdAt: now,
                updatedAt: now
            ).insert(db)
            try MeetingSpeakerRecord(
                id: speakerId,
                analysisId: analysisId,
                localSpeakerId: "speaker-0",
                representative: SpeakerEmbeddingBlobCodec.encode(values, dimensionCount: values.count),
                representativeQuality: 1,
                representativeSource: .diarization,
                profileUpdateEligible: true,
                revision: 1,
                createdAt: now,
                updatedAt: now
            ).insert(db)
            try SpeakerContactAssignmentRecord(
                meetingSpeakerId: speakerId,
                contactId: contactId,
                origin: .manual,
                createdAt: now,
                updatedAt: now
            ).insert(db)
            try SpeakerProfileRecalculator.recompute(
                contactId: contactId,
                vaultId: meeting.vaultId,
                embeddingSpace: spaceRecord,
                now: now,
                in: db
            )
        }
        return SpeakerDeletionEvidence(contactId: contactId, embeddingSpaceId: embeddingSpaceId)
    }

    func speakerProfileCount(
        for evidence: SpeakerDeletionEvidence,
        dbQueue: DatabaseQueue
    ) throws -> Int {
        try dbQueue.read { db in
            try SpeakerProfileRecord
                .filter(
                    Column("contactId") == evidence.contactId
                        && Column("embeddingSpaceId") == evidence.embeddingSpaceId
                )
                .fetchCount(db)
        }
    }
#endif
