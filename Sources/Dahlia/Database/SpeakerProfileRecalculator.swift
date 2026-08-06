import Foundation
import GRDB

enum SpeakerProfileRecalculator {
    private struct Evidence {
        let meetingSpeakerId: UUID
        let meetingId: UUID
        let audioSource: RecordingAudioSource
        let values: [Float]
        let quality: Double
    }

    static func recompute(
        contactId: UUID,
        vaultId: UUID,
        embeddingSpace: SpeakerEmbeddingSpaceRecord,
        now: Date,
        in db: Database
    ) throws {
        let evidence = try fetchEvidence(
            contactId: contactId,
            vaultId: vaultId,
            embeddingSpace: embeddingSpace,
            in: db
        )
        guard !evidence.isEmpty else {
            _ = try SpeakerProfileRecord
                .filter(Column("contactId") == contactId && Column("embeddingSpaceId") == embeddingSpace.id)
                .deleteAll(db)
            return
        }

        let evidenceByMeeting = Dictionary(grouping: evidence, by: \Evidence.meetingId)
        let meetingIds = evidenceByMeeting.keys.sorted { $0.uuidString < $1.uuidString }
        let perMeeting = try meetingIds.map { meetingId in
            let meetingEvidence = evidenceByMeeting[meetingId, default: []]
            guard let mean = SpeakerEmbeddingValidation.normalizedMean(meetingEvidence.map { ($0.values, Float(1)) }) else {
                throw SpeakerIdentityError.invalidEmbedding
            }
            return mean
        }
        guard let representative = SpeakerEmbeddingValidation.normalizedMean(perMeeting.map { ($0, Float(1)) }) else {
            throw SpeakerIdentityError.invalidEmbedding
        }
        let blob = try SpeakerEmbeddingBlobCodec.encode(representative, dimensionCount: embeddingSpace.dimensionCount)
        let existing = try SpeakerProfileRecord
            .filter(Column("contactId") == contactId && Column("embeddingSpaceId") == embeddingSpace.id)
            .fetchOne(db)
        let profile = SpeakerProfileRecord(
            id: existing?.id ?? .v7(),
            vaultId: vaultId,
            contactId: contactId,
            embeddingSpaceId: embeddingSpace.id,
            representative: blob,
            contributingMeetingCount: perMeeting.count,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        try profile.save(db)
        _ = try SpeakerProfileExemplarRecord
            .filter(Column("profileId") == profile.id)
            .deleteAll(db)
        for (ordinal, exemplar) in diverseExemplars(from: evidence).enumerated() {
            try SpeakerProfileExemplarRecord(
                profileId: profile.id,
                ordinal: ordinal,
                meetingSpeakerId: exemplar.meetingSpeakerId,
                embedding: SpeakerEmbeddingBlobCodec.encode(
                    exemplar.values,
                    dimensionCount: embeddingSpace.dimensionCount
                ),
                quality: exemplar.quality
            ).insert(db)
        }
    }

    private static func fetchEvidence(
        contactId: UUID,
        vaultId: UUID,
        embeddingSpace: SpeakerEmbeddingSpaceRecord,
        in db: Database
    ) throws -> [Evidence] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT meeting_speakers.id AS meetingSpeakerId,
                   recording_sessions.meetingId,
                   speaker_analyses.audioSource,
                   meeting_speakers.representative,
                   meeting_speakers.representativeQuality
            FROM speaker_contact_assignments
            JOIN meeting_speakers
              ON meeting_speakers.id = speaker_contact_assignments.meetingSpeakerId
            JOIN speaker_analyses ON speaker_analyses.id = meeting_speakers.analysisId
            JOIN recording_sessions ON recording_sessions.id = speaker_analyses.recordingSessionId
            JOIN meetings ON meetings.id = recording_sessions.meetingId
            WHERE speaker_contact_assignments.contactId = ?
              AND speaker_contact_assignments.origin IN ('manual', 'suggestionApproved')
              AND meeting_speakers.profileUpdateEligible = 1
              AND meeting_speakers.representativeSource = 'diarization'
              AND speaker_analyses.embeddingSpaceId = ?
              AND meetings.vaultId = ?
            ORDER BY meetings.createdAt DESC, meeting_speakers.representativeQuality DESC, meeting_speakers.id
            """,
            arguments: [contactId, embeddingSpace.id, vaultId]
        ).map { row in
            let blob: Data = row["representative"]
            return try Evidence(
                meetingSpeakerId: row["meetingSpeakerId"],
                meetingId: row["meetingId"],
                audioSource: row["audioSource"],
                values: SpeakerEmbeddingBlobCodec.decode(blob, dimensionCount: embeddingSpace.dimensionCount),
                quality: row["representativeQuality"]
            )
        }
    }

    private static func diverseExemplars(from evidence: [Evidence]) -> [Evidence] {
        var remaining = evidence
        var selected: [Evidence] = []
        var meetingIds: Set<UUID> = []
        var audioSources: Set<RecordingAudioSource> = []
        while selected.count < 5, !remaining.isEmpty {
            remaining.sort { lhs, rhs in
                let lhsRank = diversityRank(lhs, meetingIds: meetingIds, audioSources: audioSources)
                let rhsRank = diversityRank(rhs, meetingIds: meetingIds, audioSources: audioSources)
                if lhsRank != rhsRank { return lhsRank > rhsRank }
                if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
                return lhs.meetingSpeakerId.uuidString < rhs.meetingSpeakerId.uuidString
            }
            let exemplar = remaining.removeFirst()
            selected.append(exemplar)
            meetingIds.insert(exemplar.meetingId)
            audioSources.insert(exemplar.audioSource)
        }
        return selected
    }

    private static func diversityRank(
        _ evidence: Evidence,
        meetingIds: Set<UUID>,
        audioSources: Set<RecordingAudioSource>
    ) -> Int {
        (meetingIds.contains(evidence.meetingId) ? 0 : 2)
            + (audioSources.contains(evidence.audioSource) ? 0 : 1)
    }
}
