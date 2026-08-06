import Foundation
import GRDB

/// バッチ結果一式と完了事実を同じSQLiteトランザクションで確定する。
enum BatchTranscriptionPersistence {
    static func complete(
        sessionId: UUID,
        meetingId: UUID,
        output: BatchProcessingOutput,
        completedAt: Date,
        dbQueue: DatabaseQueue
    ) throws {
        let records = output.transcriptSegments.map { segment in
            var record = TranscriptSegmentRecord(
                from: segment,
                meetingId: meetingId,
                defaultSessionId: sessionId
            )
            record.meetingSpeakerId = output.transcriptSpeakerAssignments[segment.id]
            return record
        }
        try complete(
            sessionId: sessionId,
            meetingId: meetingId,
            records: records,
            speakerAnalysis: output.speakerAnalysis,
            completedAt: completedAt,
            dbQueue: dbQueue
        )
    }

    static func complete(
        sessionId: UUID,
        meetingId: UUID,
        records: [TranscriptSegmentRecord],
        completedAt: Date,
        dbQueue: DatabaseQueue
    ) throws {
        try complete(
            sessionId: sessionId,
            meetingId: meetingId,
            records: records,
            speakerAnalysis: nil,
            completedAt: completedAt,
            dbQueue: dbQueue
        )
    }

    private static func complete(
        sessionId: UUID,
        meetingId: UUID,
        records: [TranscriptSegmentRecord],
        speakerAnalysis: BatchProcessingOutput.SpeakerAnalysis?,
        completedAt: Date,
        dbQueue: DatabaseQueue
    ) throws {
        try dbQueue.write { db in
            guard let session = try RecordingSessionRecord.fetchOne(db, key: sessionId),
                  session.meetingId == meetingId,
                  try MeetingRecord.fetchOne(db, key: meetingId) != nil else {
                throw CocoaError(.fileNoSuchFile)
            }
            guard session.batchDiscardedAt == nil,
                  session.batchCompletedAt == nil || session.isBatchRetranscriptionPending else {
                throw CancellationError()
            }
            let persistedCompletedAt = max(completedAt, session.batchLastAttemptAt ?? completedAt)
            _ = try TranscriptSegmentRecord
                .filter(Column("sessionId") == sessionId)
                .deleteAll(db)
            let profileTargets = if speakerAnalysis == nil {
                Set<MeetingRepository.SpeakerProfileRecalculationTarget>()
            } else {
                try MeetingRepository.speakerProfileTargets(meetingIds: [meetingId], in: db)
            }
            if speakerAnalysis != nil {
                _ = try SpeakerAnalysisRecord
                    .filter(Column("recordingSessionId") == sessionId)
                    .deleteAll(db)
            }
            if let speakerAnalysis {
                try persist(speakerAnalysis, sessionId: sessionId, completedAt: completedAt, in: db)
            }
            for record in records {
                try record.insert(db)
            }
            _ = try MeetingRepository.recomputeSpeakerProfiles(
                profileTargets,
                now: completedAt,
                in: db
            )
            try db.execute(
                sql: """
                UPDATE recording_sessions
                SET batchCompletedAt = ?, batchLastError = NULL,
                    batchFailureKind = NULL, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [persistedCompletedAt, persistedCompletedAt, sessionId]
            )
            try db.execute(
                sql: "UPDATE meetings SET status = ?, updatedAt = ? WHERE id = ?",
                arguments: [MeetingStatus.ready.rawValue, persistedCompletedAt, meetingId]
            )
        }
    }

    private static func persist(
        _ analysis: BatchProcessingOutput.SpeakerAnalysis,
        sessionId: UUID,
        completedAt: Date,
        in db: Database
    ) throws {
        for source in analysis.sources {
            let embeddingSpaceId = try resolvedEmbeddingSpaceId(
                for: source.embeddingSpace,
                createdAt: completedAt,
                in: db
            )
            try SpeakerAnalysisRecord(
                id: source.id,
                recordingSessionId: sessionId,
                audioSource: source.audioSource,
                embeddingSpaceId: embeddingSpaceId,
                state: source.succeeded ? .succeeded : .failed,
                failureReason: source.failureReason?.rawValue,
                createdAt: completedAt,
                updatedAt: completedAt
            ).insert(db)
            for speaker in source.speakers {
                let dimensionCount = speaker.representative.space.dimensionCount
                try MeetingSpeakerRecord(
                    id: speaker.id,
                    analysisId: source.id,
                    localSpeakerId: speaker.localSpeakerId,
                    representative: SpeakerEmbeddingBlobCodec.encode(
                        speaker.representative.values,
                        dimensionCount: dimensionCount
                    ),
                    representativeQuality: 1,
                    representativeSource: speaker.representativeSource,
                    profileUpdateEligible: speaker.profileUpdateEligible,
                    revision: 1,
                    createdAt: completedAt,
                    updatedAt: completedAt
                ).insert(db)
                for (ordinal, exemplar) in speaker.exemplars.prefix(3).enumerated() {
                    try MeetingSpeakerExemplarRecord(
                        meetingSpeakerId: speaker.id,
                        ordinal: ordinal,
                        embedding: SpeakerEmbeddingBlobCodec.encode(
                            exemplar.values,
                            dimensionCount: dimensionCount
                        ),
                        quality: 1
                    ).insert(db)
                }
                for span in speaker.spans {
                    try SpeakerDiarizationSpanRecord(
                        id: .v7(),
                        meetingSpeakerId: speaker.id,
                        startSeconds: span.startTimeSeconds,
                        endSeconds: span.endTimeSeconds,
                        createdAt: completedAt
                    ).insert(db)
                }
            }
        }
    }

    private static func resolvedEmbeddingSpaceId(
        for space: SpeakerEmbeddingSpace?,
        createdAt: Date,
        in db: Database
    ) throws -> UUID? {
        guard let space else { return nil }
        return try embeddingSpaceId(for: space, createdAt: createdAt, in: db)
    }

    private static func embeddingSpaceId(
        for space: SpeakerEmbeddingSpace,
        createdAt: Date,
        in db: Database
    ) throws -> UUID {
        if let existing = try SpeakerEmbeddingSpaceRecord.fetchAll(db).first(where: { $0.space == space }) {
            return existing.id
        }
        let record = SpeakerEmbeddingSpaceRecord(id: .v7(), space: space, createdAt: createdAt)
        try record.insert(db)
        return record.id
    }
}
