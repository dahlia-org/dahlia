import Foundation
import GRDB

extension MeetingRepository {
    nonisolated func fetchSpeakerCandidates(
        vaultId: UUID,
        meetingId: UUID? = nil
    ) throws -> [SpeakerCandidate] {
        try dbQueue.read { db in
            guard try VaultRecord.fetchOne(db, key: vaultId) != nil else {
                throw SpeakerIdentityError.vaultNotFound
            }
            var arguments: StatementArguments = [vaultId]
            var meetingPredicate = ""
            if let meetingId {
                meetingPredicate = " AND meetings.id = ?"
                arguments += [meetingId]
            }
            return try Row.fetchAll(
                db,
                sql: """
                SELECT meeting_speakers.id AS meetingSpeakerId,
                       meetings.id AS meetingId,
                       speaker_analyses.audioSource,
                       meeting_speakers.localSpeakerId,
                       meeting_speakers.revision,
                       speaker_contact_assignments.contactId AS assignedContactId,
                       speaker_contact_assignments.origin AS assignmentOrigin,
                       speaker_match_observations.top1ContactId,
                       speaker_match_observations.top1Score,
                       speaker_match_observations.top2ContactId,
                       speaker_match_observations.top2Score,
                       speaker_match_observations.margin,
                       speaker_match_observations.state AS matchState,
                       speaker_match_observations.unknownReason
                FROM meeting_speakers
                JOIN speaker_analyses ON speaker_analyses.id = meeting_speakers.analysisId
                JOIN recording_sessions ON recording_sessions.id = speaker_analyses.recordingSessionId
                JOIN meetings ON meetings.id = recording_sessions.meetingId
                LEFT JOIN speaker_contact_assignments
                  ON speaker_contact_assignments.meetingSpeakerId = meeting_speakers.id
                LEFT JOIN speaker_match_observations
                  ON speaker_match_observations.meetingSpeakerId = meeting_speakers.id
                WHERE meetings.vaultId = ?\(meetingPredicate)
                ORDER BY meetings.createdAt DESC, speaker_analyses.audioSource, meeting_speakers.localSpeakerId
                """,
                arguments: arguments
            ).map(Self.speakerCandidate(row:))
        }
    }

    @discardableResult
    nonisolated func manuallyAssignSpeaker(
        meetingSpeakerId: UUID,
        contactId: UUID,
        vaultId: UUID,
        expectedRevision: Int,
        now: Date = .now
    ) async throws -> SpeakerCandidate {
        try await assignSpeaker(
            meetingSpeakerId: meetingSpeakerId,
            contactId: contactId,
            vaultId: vaultId,
            origin: .manual,
            expectedRevision: expectedRevision,
            now: now
        )
    }

    @discardableResult
    nonisolated func changeSpeakerAssignment(
        meetingSpeakerId: UUID,
        contactId: UUID,
        vaultId: UUID,
        expectedRevision: Int,
        now: Date = .now
    ) async throws -> SpeakerCandidate {
        try await manuallyAssignSpeaker(
            meetingSpeakerId: meetingSpeakerId,
            contactId: contactId,
            vaultId: vaultId,
            expectedRevision: expectedRevision,
            now: now
        )
    }

    @discardableResult
    nonisolated func approveSpeakerSuggestion(
        meetingSpeakerId: UUID,
        contactId: UUID,
        vaultId: UUID,
        expectedRevision: Int,
        now: Date = .now
    ) async throws -> SpeakerCandidate {
        try await assignSpeaker(
            meetingSpeakerId: meetingSpeakerId,
            contactId: contactId,
            vaultId: vaultId,
            origin: .suggestionApproved,
            requiresSuggestion: true,
            expectedRevision: expectedRevision,
            now: now
        )
    }

    @discardableResult
    nonisolated func rejectSpeakerSuggestion(
        meetingSpeakerId: UUID,
        vaultId: UUID,
        expectedRevision: Int,
        now: Date = .now
    ) async throws -> SpeakerCandidate {
        try await dbQueue.write { db in
            let context = try Self.speakerContext(
                meetingSpeakerId: meetingSpeakerId,
                vaultId: vaultId,
                in: db
            )
            guard var observation = try SpeakerMatchObservationRecord.fetchOne(db, key: meetingSpeakerId),
                  observation.state == .suggested || observation.state == .rejected
            else {
                throw SpeakerIdentityError.invalidSuggestion
            }
            if observation.state == .rejected {
                return try Self.fetchSpeakerCandidate(id: meetingSpeakerId, vaultId: vaultId, in: db)
            }
            guard context.revision == expectedRevision else {
                throw SpeakerIdentityError.revisionConflict
            }
            observation.state = .rejected
            observation.unknownReason = nil
            observation.revision += 1
            observation.updatedAt = now
            try observation.update(db)
            try Self.incrementSpeakerRevision(id: meetingSpeakerId, now: now, in: db)
            return try Self.fetchSpeakerCandidate(id: meetingSpeakerId, vaultId: vaultId, in: db)
        }
    }

    @discardableResult
    nonisolated func clearSpeakerAssignment(
        meetingSpeakerId: UUID,
        vaultId: UUID,
        expectedRevision: Int,
        now: Date = .now
    ) async throws -> SpeakerCandidate {
        let result = try await dbQueue.write { db -> (SpeakerCandidate, Set<SpeakerProfileCacheKey>) in
            let context = try Self.speakerContext(
                meetingSpeakerId: meetingSpeakerId,
                vaultId: vaultId,
                in: db
            )
            guard let assignment = try SpeakerContactAssignmentRecord.fetchOne(db, key: meetingSpeakerId) else {
                return try (Self.fetchSpeakerCandidate(id: meetingSpeakerId, vaultId: vaultId, in: db), [])
            }
            guard context.revision == expectedRevision else {
                throw SpeakerIdentityError.revisionConflict
            }
            _ = try assignment.delete(db)
            try Self.incrementSpeakerRevision(id: meetingSpeakerId, now: now, in: db)
            try SpeakerProfileRecalculator.recompute(
                contactId: assignment.contactId,
                vaultId: vaultId,
                embeddingSpace: context.embeddingSpace,
                now: now,
                in: db
            )
            let key = SpeakerProfileCacheKey(vaultId: vaultId, embeddingSpaceId: context.embeddingSpace.id)
            return try (Self.fetchSpeakerCandidate(id: meetingSpeakerId, vaultId: vaultId, in: db), [key])
        }
        await speakerProfileCache.invalidate(result.1)
        return result.0
    }

    nonisolated func deleteVaultSpeakerProfiles(vaultId: UUID) async throws {
        try await dbQueue.write { db in
            guard try VaultRecord.fetchOne(db, key: vaultId) != nil else {
                throw SpeakerIdentityError.vaultNotFound
            }
            _ = try SpeakerProfileRecord.filter(Column("vaultId") == vaultId).deleteAll(db)
        }
        await speakerProfileCache.invalidate(vaultId: vaultId)
    }

    @discardableResult
    nonisolated func evaluateSpeakerMatch(
        meetingSpeakerId: UUID,
        vaultId: UUID,
        expectedRevision: Int,
        now: Date = .now
    ) async throws -> SpeakerCandidate {
        let input = try await dbQueue.read { db -> (SpeakerContext, SpeakerEmbedding, SpeakerMatchPolicy) in
            let context = try Self.speakerContext(
                meetingSpeakerId: meetingSpeakerId,
                vaultId: vaultId,
                in: db
            )
            guard context.revision == expectedRevision else {
                throw SpeakerIdentityError.revisionConflict
            }
            let values = try SpeakerEmbeddingBlobCodec.decode(
                context.representative,
                dimensionCount: context.embeddingSpace.dimensionCount
            )
            let policy = try SpeakerMatchPolicyRecord.fetchOne(db, key: 1)?.policy ?? .calibrationRequired
            return (context, SpeakerEmbedding(space: context.embeddingSpace.space, values: values), policy)
        }
        let key = SpeakerProfileCacheKey(vaultId: vaultId, embeddingSpaceId: input.0.embeddingSpace.id)
        let dbQueue = dbQueue
        let space = input.0.embeddingSpace
        let profiles = try await speakerProfileCache.profiles(for: key) {
            try await Self.loadProfiles(vaultId: vaultId, embeddingSpace: space, dbQueue: dbQueue)
        }
        let cachedRanking = SpeakerMatcher.rank(embedding: input.1, profiles: profiles, policy: input.2)
        return try await dbQueue.write { db in
            let current = try Self.speakerContext(
                meetingSpeakerId: meetingSpeakerId,
                vaultId: vaultId,
                in: db
            )
            guard current.revision == expectedRevision else {
                throw SpeakerIdentityError.revisionConflict
            }
            let currentProfiles = try Self.loadProfiles(
                vaultId: vaultId,
                embeddingSpace: space,
                in: db
            )
            let currentPolicy = try SpeakerMatchPolicyRecord.fetchOne(db, key: 1)?.policy ?? .calibrationRequired
            let ranking = currentProfiles == profiles && currentPolicy == input.2
                ? cachedRanking
                : SpeakerMatcher.rank(embedding: input.1, profiles: currentProfiles, policy: currentPolicy)
            let existing = try SpeakerMatchObservationRecord.fetchOne(db, key: meetingSpeakerId)
            let state = existing?.state == .rejected ? SpeakerMatchObservationState.rejected : ranking.state
            try SpeakerMatchObservationRecord(
                meetingSpeakerId: meetingSpeakerId,
                embeddingSpaceId: space.id,
                top1ContactId: ranking.top1ContactId,
                top1Score: ranking.top1Score.map(Double.init),
                top2ContactId: ranking.top2ContactId,
                top2Score: ranking.top2Score.map(Double.init),
                margin: ranking.margin.map(Double.init),
                state: state,
                unknownReason: state == .rejected ? nil : ranking.unknownReason,
                revision: (existing?.revision ?? 0) + 1,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            ).save(db)
            try Self.incrementSpeakerRevision(id: meetingSpeakerId, now: now, in: db)
            return try Self.fetchSpeakerCandidate(id: meetingSpeakerId, vaultId: vaultId, in: db)
        }
    }

    private nonisolated func assignSpeaker(
        meetingSpeakerId: UUID,
        contactId: UUID,
        vaultId: UUID,
        origin: SpeakerAssignmentOrigin,
        requiresSuggestion: Bool = false,
        expectedRevision: Int,
        now: Date
    ) async throws -> SpeakerCandidate {
        let result = try await dbQueue.write { db -> (SpeakerCandidate, Set<SpeakerProfileCacheKey>) in
            let context = try Self.speakerContext(
                meetingSpeakerId: meetingSpeakerId,
                vaultId: vaultId,
                in: db
            )
            guard try ContactRecord
                .filter(Column("id") == contactId && Column("vaultId") == vaultId)
                .fetchOne(db) != nil
            else {
                throw SpeakerIdentityError.contactNotFound
            }
            let existing = try SpeakerContactAssignmentRecord.fetchOne(db, key: meetingSpeakerId)
            if existing?.contactId == contactId, existing?.origin == origin {
                return try (Self.fetchSpeakerCandidate(id: meetingSpeakerId, vaultId: vaultId, in: db), [])
            }
            if requiresSuggestion {
                guard let observation = try SpeakerMatchObservationRecord.fetchOne(db, key: meetingSpeakerId),
                      observation.state == .suggested,
                      observation.top1ContactId == contactId
                else {
                    throw SpeakerIdentityError.invalidSuggestion
                }
            }
            guard context.revision == expectedRevision else {
                throw SpeakerIdentityError.revisionConflict
            }
            try SpeakerContactAssignmentRecord(
                meetingSpeakerId: meetingSpeakerId,
                contactId: contactId,
                origin: origin,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            ).save(db)
            if requiresSuggestion,
               var observation = try SpeakerMatchObservationRecord.fetchOne(db, key: meetingSpeakerId) {
                observation.state = .referenceOnly
                observation.unknownReason = nil
                observation.revision += 1
                observation.updatedAt = now
                try observation.update(db)
            }
            try Self.incrementSpeakerRevision(id: meetingSpeakerId, now: now, in: db)
            let affectedContactIds = Set([existing?.contactId, contactId].compactMap(\.self))
            for affectedContactId in affectedContactIds {
                try SpeakerProfileRecalculator.recompute(
                    contactId: affectedContactId,
                    vaultId: vaultId,
                    embeddingSpace: context.embeddingSpace,
                    now: now,
                    in: db
                )
            }
            let key = SpeakerProfileCacheKey(vaultId: vaultId, embeddingSpaceId: context.embeddingSpace.id)
            return try (Self.fetchSpeakerCandidate(id: meetingSpeakerId, vaultId: vaultId, in: db), [key])
        }
        await speakerProfileCache.invalidate(result.1)
        return result.0
    }

    private struct SpeakerContext {
        let revision: Int
        let representative: Data
        let embeddingSpace: SpeakerEmbeddingSpaceRecord
    }

    private nonisolated static func speakerContext(
        meetingSpeakerId: UUID,
        vaultId: UUID,
        in db: Database
    ) throws -> SpeakerContext {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT meeting_speakers.revision AS speakerRevision,
                   meeting_speakers.representative,
                   speaker_embedding_spaces.id AS spaceId,
                   speaker_embedding_spaces.provider,
                   speaker_embedding_spaces.modelName,
                   speaker_embedding_spaces.revision AS spaceRevision,
                   speaker_embedding_spaces.assetFingerprint,
                   speaker_embedding_spaces.fluidAudioVersion,
                   speaker_embedding_spaces.dimensionCount,
                   speaker_embedding_spaces.sampleRate,
                   speaker_embedding_spaces.preprocessing,
                   speaker_embedding_spaces.excludesOverlap,
                   speaker_embedding_spaces.normalization,
                   speaker_embedding_spaces.similarityDefinition,
                   speaker_embedding_spaces.createdAt AS spaceCreatedAt
            FROM meeting_speakers
            JOIN speaker_analyses ON speaker_analyses.id = meeting_speakers.analysisId
            JOIN speaker_embedding_spaces ON speaker_embedding_spaces.id = speaker_analyses.embeddingSpaceId
            JOIN recording_sessions ON recording_sessions.id = speaker_analyses.recordingSessionId
            JOIN meetings ON meetings.id = recording_sessions.meetingId
            WHERE meeting_speakers.id = ? AND meetings.vaultId = ?
            """,
            arguments: [meetingSpeakerId, vaultId]
        ) else {
            throw SpeakerIdentityError.candidateNotFound
        }
        let embeddingSpace = SpeakerEmbeddingSpace(
            provider: row["provider"],
            modelName: row["modelName"],
            revision: row["spaceRevision"],
            assetFingerprint: row["assetFingerprint"],
            fluidAudioVersion: row["fluidAudioVersion"],
            dimensionCount: row["dimensionCount"],
            sampleRate: row["sampleRate"],
            preprocessing: row["preprocessing"],
            excludesOverlap: row["excludesOverlap"],
            normalization: row["normalization"],
            similarityDefinition: row["similarityDefinition"]
        )
        return SpeakerContext(
            revision: row["speakerRevision"],
            representative: row["representative"],
            embeddingSpace: SpeakerEmbeddingSpaceRecord(
                id: row["spaceId"],
                space: embeddingSpace,
                createdAt: row["spaceCreatedAt"]
            )
        )
    }

    private nonisolated static func incrementSpeakerRevision(id: UUID, now: Date, in db: Database) throws {
        try db.execute(
            sql: "UPDATE meeting_speakers SET revision = revision + 1, updatedAt = ? WHERE id = ?",
            arguments: [now, id]
        )
    }

    private nonisolated static func fetchSpeakerCandidate(
        id: UUID,
        vaultId: UUID,
        in db: Database
    ) throws -> SpeakerCandidate {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT meeting_speakers.id AS meetingSpeakerId,
                   meetings.id AS meetingId,
                   speaker_analyses.audioSource,
                   meeting_speakers.localSpeakerId,
                   meeting_speakers.revision,
                   speaker_contact_assignments.contactId AS assignedContactId,
                   speaker_contact_assignments.origin AS assignmentOrigin,
                   speaker_match_observations.top1ContactId,
                   speaker_match_observations.top1Score,
                   speaker_match_observations.top2ContactId,
                   speaker_match_observations.top2Score,
                   speaker_match_observations.margin,
                   speaker_match_observations.state AS matchState,
                   speaker_match_observations.unknownReason
            FROM meeting_speakers
            JOIN speaker_analyses ON speaker_analyses.id = meeting_speakers.analysisId
            JOIN recording_sessions ON recording_sessions.id = speaker_analyses.recordingSessionId
            JOIN meetings ON meetings.id = recording_sessions.meetingId
            LEFT JOIN speaker_contact_assignments
              ON speaker_contact_assignments.meetingSpeakerId = meeting_speakers.id
            LEFT JOIN speaker_match_observations
              ON speaker_match_observations.meetingSpeakerId = meeting_speakers.id
            WHERE meeting_speakers.id = ? AND meetings.vaultId = ?
            """,
            arguments: [id, vaultId]
        ) else {
            throw SpeakerIdentityError.candidateNotFound
        }
        return speakerCandidate(row: row)
    }

    private nonisolated static func speakerCandidate(row: Row) -> SpeakerCandidate {
        SpeakerCandidate(
            meetingSpeakerId: row["meetingSpeakerId"],
            meetingId: row["meetingId"],
            audioSource: row["audioSource"],
            localSpeakerId: row["localSpeakerId"],
            revision: row["revision"],
            assignedContactId: row["assignedContactId"],
            assignmentOrigin: row["assignmentOrigin"],
            top1ContactId: row["top1ContactId"],
            top1Score: (row["top1Score"] as Double?).map(Float.init),
            top2ContactId: row["top2ContactId"],
            top2Score: (row["top2Score"] as Double?).map(Float.init),
            margin: (row["margin"] as Double?).map(Float.init),
            matchState: row["matchState"],
            unknownReason: row["unknownReason"]
        )
    }

    private nonisolated static func loadProfiles(
        vaultId: UUID,
        embeddingSpace: SpeakerEmbeddingSpaceRecord,
        dbQueue: DatabaseQueue
    ) async throws -> [CachedSpeakerProfile] {
        try await dbQueue.read { db in
            try loadProfiles(vaultId: vaultId, embeddingSpace: embeddingSpace, in: db)
        }
    }

    private nonisolated static func loadProfiles(
        vaultId: UUID,
        embeddingSpace: SpeakerEmbeddingSpaceRecord,
        in db: Database
    ) throws -> [CachedSpeakerProfile] {
        try SpeakerProfileRecord
            .filter(Column("vaultId") == vaultId && Column("embeddingSpaceId") == embeddingSpace.id)
            .order(Column("contactId"))
            .fetchAll(db)
            .map { profile in
                try CachedSpeakerProfile(
                    contactId: profile.contactId,
                    embedding: SpeakerEmbedding(
                        space: embeddingSpace.space,
                        values: SpeakerEmbeddingBlobCodec.decode(
                            profile.representative,
                            dimensionCount: embeddingSpace.dimensionCount
                        )
                    )
                )
            }
    }
}
