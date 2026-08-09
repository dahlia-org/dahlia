import Foundation
import GRDB

extension MeetingRepository {
    struct SpeakerProfileRecalculationTarget: Hashable {
        let contactId: UUID
        let vaultId: UUID
        let embeddingSpaceId: UUID
    }

    nonisolated static func speakerProfileTargets(
        meetingIds: Set<UUID>,
        in db: Database
    ) throws -> Set<SpeakerProfileRecalculationTarget> {
        guard !meetingIds.isEmpty else { return [] }
        let placeholders = meetingIds.map { _ in "?" }.joined(separator: ",")
        return try Set(Row.fetchAll(
            db,
            sql: """
            SELECT DISTINCT speaker_contact_assignments.contactId,
                            meetings.vaultId,
                            speaker_analyses.embeddingSpaceId
            FROM speaker_contact_assignments
            JOIN meeting_speakers
              ON meeting_speakers.id = speaker_contact_assignments.meetingSpeakerId
            JOIN speaker_analyses ON speaker_analyses.id = meeting_speakers.analysisId
            JOIN recording_sessions ON recording_sessions.id = speaker_analyses.recordingSessionId
            JOIN meetings ON meetings.id = recording_sessions.meetingId
            WHERE meetings.id IN (\(placeholders))
              AND speaker_analyses.embeddingSpaceId IS NOT NULL
            """,
            arguments: StatementArguments(meetingIds)
        ).map { row in
            SpeakerProfileRecalculationTarget(
                contactId: row["contactId"],
                vaultId: row["vaultId"],
                embeddingSpaceId: row["embeddingSpaceId"]
            )
        })
    }

    nonisolated static func recomputeSpeakerProfiles(
        _ targets: Set<SpeakerProfileRecalculationTarget>,
        now: Date,
        in db: Database
    ) throws -> Set<SpeakerProfileCacheKey> {
        for target in targets {
            guard let space = try SpeakerEmbeddingSpaceRecord.fetchOne(db, key: target.embeddingSpaceId),
                  try ContactRecord.fetchOne(db, key: target.contactId) != nil
            else {
                continue
            }
            try SpeakerProfileRecalculator.recompute(
                contactId: target.contactId,
                vaultId: target.vaultId,
                embeddingSpace: space,
                now: now,
                in: db
            )
        }
        return Set(targets.map {
            SpeakerProfileCacheKey(vaultId: $0.vaultId, embeddingSpaceId: $0.embeddingSpaceId)
        })
    }

    nonisolated func invalidateSpeakerProfilesAfterCommit(_ keys: Set<SpeakerProfileCacheKey>) {
        guard !keys.isEmpty else { return }
        speakerProfileCache.invalidateAfterCommit(keys)
    }
}
