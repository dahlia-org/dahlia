import Foundation
import GRDB

enum MeetingSpeakerClusterer {
    struct MatchPolicy: Equatable, Sendable {
        /// P6 calibration is still pending. Requiring near-identical direction plus clear separation
        /// intentionally favors visible duplicate labels over attributing one person's words to another.
        static let conservativeInitial = Self(minimumSimilarity: 0.97, minimumMargin: 0.10)

        let minimumSimilarity: Float
        let minimumMargin: Float
    }

    private struct SpeakerRow {
        let id: UUID
        let meetingId: UUID
        let sessionId: UUID
        let audioSource: RecordingAudioSource
        let embeddingSpaceId: UUID
        let dimensionCount: Int
        let representative: Data
        let assignment: SpeakerContactAssignmentRecord?
    }

    private struct Candidate {
        let cluster: MeetingSpeakerClusterRecord
        let score: Float
        let assignment: SpeakerClusterContactAssignmentRecord?
    }

    static func assignUnclusteredSpeakers(
        meetingId: UUID?,
        now: Date,
        policy: MatchPolicy = .conservativeInitial,
        in db: Database
    ) throws {
        for speaker in try unclusteredSpeakers(meetingId: meetingId, in: db) {
            let values = try SpeakerEmbeddingBlobCodec.decode(
                speaker.representative,
                dimensionCount: speaker.dimensionCount
            )
            let candidates = try compatibleCandidates(for: speaker, values: values, in: db)
            let cluster = matchedCluster(from: candidates, policy: policy)
                ?? MeetingSpeakerClusterRecord(
                    id: .v7(),
                    meetingId: speaker.meetingId,
                    audioSource: speaker.audioSource,
                    embeddingSpaceId: speaker.embeddingSpaceId,
                    representative: speaker.representative,
                    createdAt: now,
                    updatedAt: now
                )
            if candidates.allSatisfy({ $0.cluster.id != cluster.id }) {
                try cluster.insert(db)
            }
            try MeetingSpeakerClusterMemberRecord(
                meetingSpeakerId: speaker.id,
                clusterId: cluster.id,
                createdAt: now
            ).insert(db)
            try mergeAssignment(speaker.assignment, into: cluster.id, now: now, in: db)
            try projectAssignment(clusterId: cluster.id, now: now, in: db)
        }
    }

    private static func matchedCluster(from candidates: [Candidate], policy: MatchPolicy) -> MeetingSpeakerClusterRecord? {
        guard let first = candidates.first,
              first.score >= policy.minimumSimilarity
        else {
            return nil
        }
        if let second = candidates.dropFirst().first,
           first.score - second.score < policy.minimumMargin {
            return nil
        }
        return first.cluster
    }

    private static func compatibleCandidates(
        for speaker: SpeakerRow,
        values: [Float],
        in db: Database
    ) throws -> [Candidate] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT meeting_speaker_clusters.*,
                   speaker_cluster_contact_assignments.contactId,
                   speaker_cluster_contact_assignments.origin,
                   speaker_cluster_contact_assignments.createdAt AS assignmentCreatedAt,
                   speaker_cluster_contact_assignments.updatedAt AS assignmentUpdatedAt
            FROM meeting_speaker_clusters
            LEFT JOIN speaker_cluster_contact_assignments
              ON speaker_cluster_contact_assignments.clusterId = meeting_speaker_clusters.id
            WHERE meeting_speaker_clusters.meetingId = ?
              AND meeting_speaker_clusters.audioSource = ?
              AND meeting_speaker_clusters.embeddingSpaceId = ?
              AND NOT EXISTS (
                  SELECT 1
                  FROM meeting_speaker_cluster_members
                  JOIN meeting_speakers
                    ON meeting_speakers.id = meeting_speaker_cluster_members.meetingSpeakerId
                  JOIN speaker_analyses ON speaker_analyses.id = meeting_speakers.analysisId
                  WHERE meeting_speaker_cluster_members.clusterId = meeting_speaker_clusters.id
                    AND speaker_analyses.recordingSessionId = ?
              )
            ORDER BY meeting_speaker_clusters.id
            """,
            arguments: [speaker.meetingId, speaker.audioSource, speaker.embeddingSpaceId, speaker.sessionId]
        )
        return try rows.compactMap { row -> Candidate? in
            let cluster = try MeetingSpeakerClusterRecord(row: row)
            let assignment = clusterAssignment(row: row, clusterId: cluster.id)
            guard assignment?.contactId == nil || speaker.assignment?.contactId == nil
                || assignment?.contactId == speaker.assignment?.contactId,
                let score = try SpeakerMatcher.similarity(
                    values,
                    SpeakerEmbeddingBlobCodec.decode(
                        cluster.representative,
                        dimensionCount: speaker.dimensionCount
                    )
                )
            else {
                return nil
            }
            return Candidate(cluster: cluster, score: score, assignment: assignment)
        }.sorted {
            if $0.score == $1.score { return $0.cluster.id.uuidString < $1.cluster.id.uuidString }
            return $0.score > $1.score
        }
    }

    private static func clusterAssignment(row: Row, clusterId: UUID) -> SpeakerClusterContactAssignmentRecord? {
        guard let contactId: UUID = row["contactId"] else { return nil }
        return SpeakerClusterContactAssignmentRecord(
            clusterId: clusterId,
            contactId: contactId,
            origin: row["origin"],
            createdAt: row["assignmentCreatedAt"],
            updatedAt: row["assignmentUpdatedAt"]
        )
    }

    private static func mergeAssignment(
        _ incoming: SpeakerContactAssignmentRecord?,
        into clusterId: UUID,
        now: Date,
        in db: Database
    ) throws {
        guard let incoming else { return }
        let existing = try SpeakerClusterContactAssignmentRecord.fetchOne(db, key: clusterId)
        guard existing?.contactId == nil || existing?.contactId == incoming.contactId else { return }
        try SpeakerClusterContactAssignmentRecord(
            clusterId: clusterId,
            contactId: incoming.contactId,
            origin: stronger(existing?.origin, incoming.origin),
            createdAt: min(existing?.createdAt ?? incoming.createdAt, incoming.createdAt),
            updatedAt: now
        ).save(db)
    }

    private static func projectAssignment(clusterId: UUID, now: Date, in db: Database) throws {
        guard let assignment = try SpeakerClusterContactAssignmentRecord.fetchOne(db, key: clusterId) else { return }
        let meetingSpeakerIds = try UUID.fetchAll(
            db,
            sql: "SELECT meetingSpeakerId FROM meeting_speaker_cluster_members WHERE clusterId = ?",
            arguments: [clusterId]
        )
        for meetingSpeakerId in meetingSpeakerIds {
            try SpeakerContactAssignmentRecord(
                meetingSpeakerId: meetingSpeakerId,
                contactId: assignment.contactId,
                origin: assignment.origin,
                createdAt: assignment.createdAt,
                updatedAt: now
            ).save(db)
        }
    }

    private static func stronger(_ lhs: SpeakerAssignmentOrigin?, _ rhs: SpeakerAssignmentOrigin) -> SpeakerAssignmentOrigin {
        guard let lhs else { return rhs }
        func rank(_ origin: SpeakerAssignmentOrigin) -> Int {
            switch origin {
            case .manual: 3
            case .suggestionApproved: 2
            case .ownerChannelConfirmation: 1
            }
        }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }

    private static func unclusteredSpeakers(meetingId: UUID?, in db: Database) throws -> [SpeakerRow] {
        let predicate = meetingId == nil ? "" : " AND recording_sessions.meetingId = ?"
        let arguments = meetingId.map { StatementArguments([$0]) } ?? StatementArguments()
        return try Row.fetchAll(
            db,
            sql: """
            SELECT meeting_speakers.id,
                   recording_sessions.meetingId,
                   recording_sessions.id AS sessionId,
                   speaker_analyses.audioSource,
                   speaker_analyses.embeddingSpaceId,
                   speaker_embedding_spaces.dimensionCount,
                   meeting_speakers.representative,
                   speaker_contact_assignments.contactId,
                   speaker_contact_assignments.origin,
                   speaker_contact_assignments.createdAt AS assignmentCreatedAt,
                   speaker_contact_assignments.updatedAt AS assignmentUpdatedAt
            FROM meeting_speakers
            JOIN speaker_analyses ON speaker_analyses.id = meeting_speakers.analysisId
            JOIN recording_sessions ON recording_sessions.id = speaker_analyses.recordingSessionId
            JOIN speaker_embedding_spaces ON speaker_embedding_spaces.id = speaker_analyses.embeddingSpaceId
            LEFT JOIN meeting_speaker_cluster_members
              ON meeting_speaker_cluster_members.meetingSpeakerId = meeting_speakers.id
            LEFT JOIN speaker_contact_assignments
              ON speaker_contact_assignments.meetingSpeakerId = meeting_speakers.id
            WHERE meeting_speaker_cluster_members.meetingSpeakerId IS NULL\(predicate)
            ORDER BY recording_sessions.meetingId, recording_sessions.startedAt,
                     speaker_analyses.audioSource, meeting_speakers.localSpeakerId, meeting_speakers.id
            """,
            arguments: arguments
        ).map { row in
            let id: UUID = row["id"]
            let assignment: SpeakerContactAssignmentRecord? = if let contactId: UUID = row["contactId"] {
                SpeakerContactAssignmentRecord(
                    meetingSpeakerId: id,
                    contactId: contactId,
                    origin: row["origin"],
                    createdAt: row["assignmentCreatedAt"],
                    updatedAt: row["assignmentUpdatedAt"]
                )
            } else {
                nil
            }
            return SpeakerRow(
                id: id,
                meetingId: row["meetingId"],
                sessionId: row["sessionId"],
                audioSource: row["audioSource"],
                embeddingSpaceId: row["embeddingSpaceId"],
                dimensionCount: row["dimensionCount"],
                representative: row["representative"],
                assignment: assignment
            )
        }
    }
}
