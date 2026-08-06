import DahliaRuntimeSupport
import Foundation
import GRDB
@testable import Dahlia

// swiftlint:disable file_length
#if canImport(Testing)
    import Testing

    struct SpeakerIdentityMigrationTests {
        @Test
        func upgradesV33PreservingMeetingsTranscriptsAndContacts() throws {
            let url = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-speaker-v33-\(UUID.v7())")
                .appendingPathExtension("sqlite")
            defer { try? FileManager.default.removeItem(at: url) }
            let queue = try DatabaseQueue(path: url.path)
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v33_sharedOrganizationDomains")
            let ids = try insertLegacyRows(in: queue)

            let migrated = try AppDatabaseManager(path: url.path)
            let preserved = try migrated.dbQueue.read { db in
                try (
                    MeetingRecord.fetchOne(db, key: ids.meetingId),
                    String.fetchOne(
                        db,
                        sql: "SELECT text FROM transcript_segments WHERE id = ?",
                        arguments: [ids.transcriptId]
                    ),
                    ContactRecord.fetchOne(db, key: ids.contactId),
                    String.fetchOne(
                        db,
                        sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"
                    )
                )
            }
            let validation = try migrated.dbQueue.read { db in
                try (
                    String.fetchOne(db, sql: "PRAGMA integrity_check"),
                    Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
                )
            }

            #expect(preserved.0?.name == "Preserved meeting")
            #expect(preserved.1 == "Preserved transcript")
            #expect(preserved.2?.email == "person@example.com")
            #expect(preserved.3 == "v34_speakerIdentityTriggerRefresh")
            #expect(validation.0 == "ok")
            #expect(validation.1.isEmpty)
        }

        @Test
        func emptyDatabaseAppliesAllMigrationsAndCalibrationRequiredPolicy() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let result = try database.dbQueue.read { db in
                try (
                    AppDatabaseManager.hasExpectedCurrentSchema(db),
                    SpeakerMatchPolicyRecord.fetchOne(db, key: 1),
                    String.fetchAll(
                        db,
                        sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'speaker_%' ORDER BY name"
                    )
                )
            }
            let validation = try database.dbQueue.read { db in
                try (
                    String.fetchOne(db, sql: "PRAGMA integrity_check"),
                    Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
                )
            }

            #expect(result.0)
            #expect(result.1?.formatVersion == SpeakerMatchPolicy.formatVersion)
            #expect(result.1?.state == .calibrationRequired)
            #expect(result.1?.minimumSimilarity == nil)
            #expect(result.1?.minimumMargin == nil)
            #expect(result.2.count == 8)
            #expect(validation.0 == "ok")
            #expect(validation.1.isEmpty)
        }

        @Test
        func upgradingPreviouslyAppliedV34ReplacesTriggerDefinitions() throws {
            let upgraded = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(upgraded, upTo: "v34_speakerIdentity")
            try upgraded.write { db in
                try installPreviousV34Triggers(in: db)
            }
            try AppDatabaseManager.migrator.migrate(upgraded)
            let fresh = try AppDatabaseManager(path: ":memory:")

            let upgradedTriggers = try upgraded.read(v34TriggerDefinitions)
            let freshTriggers = try fresh.dbQueue.read(v34TriggerDefinitions)
            let appliedMigration = try upgraded.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"
                )
            }

            #expect(upgradedTriggers == freshTriggers)
            #expect(upgradedTriggers.count == 9)
            #expect(appliedMigration == "v34_speakerIdentityTriggerRefresh")
        }

        @Test
        // swiftlint:disable:next function_body_length
        func schemaEnforcesNullableForeignKeysCascadesUniquenessAndPagingIndex() throws {
            let fixture = try MigrationFixture()
            try fixture.database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE transcript_segments SET meetingSpeakerId = ? WHERE id = ?",
                    arguments: [fixture.meetingSpeakerId, fixture.transcriptId]
                )
                #expect(throws: (any Error).self) {
                    try SpeakerAnalysisRecord(
                        id: .v7(),
                        recordingSessionId: fixture.sessionId,
                        audioSource: .microphone,
                        embeddingSpaceId: fixture.spaceId,
                        state: .succeeded,
                        failureReason: nil,
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                }
                #expect(throws: (any Error).self) {
                    try SpeakerEmbeddingSpaceRecord(
                        id: .v7(),
                        space: MigrationFixture.space,
                        createdAt: .now
                    ).insert(db)
                }
                let speaker = try #require(try MeetingSpeakerRecord.fetchOne(db, key: fixture.meetingSpeakerId))
                #expect(throws: (any Error).self) {
                    try MeetingSpeakerRecord(
                        id: .v7(),
                        analysisId: speaker.analysisId,
                        localSpeakerId: speaker.localSpeakerId,
                        representative: speaker.representative,
                        representativeQuality: 1,
                        representativeSource: .diarization,
                        profileUpdateEligible: true,
                        revision: 1,
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                }
                #expect(throws: (any Error).self) {
                    try MeetingSpeakerExemplarRecord(
                        meetingSpeakerId: fixture.meetingSpeakerId,
                        ordinal: 3,
                        embedding: speaker.representative,
                        quality: 1
                    ).insert(db)
                }
                let profile = SpeakerProfileRecord(
                    id: .v7(),
                    vaultId: fixture.vaultId,
                    contactId: fixture.contactId,
                    embeddingSpaceId: fixture.spaceId,
                    representative: speaker.representative,
                    contributingMeetingCount: 1,
                    createdAt: .now,
                    updatedAt: .now
                )
                try profile.insert(db)
                #expect(throws: (any Error).self) {
                    try SpeakerProfileRecord(
                        id: .v7(),
                        vaultId: fixture.vaultId,
                        contactId: fixture.contactId,
                        embeddingSpaceId: fixture.spaceId,
                        representative: speaker.representative,
                        contributingMeetingCount: 1,
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                }
                #expect(throws: (any Error).self) {
                    try SpeakerProfileExemplarRecord(
                        profileId: profile.id,
                        ordinal: 5,
                        meetingSpeakerId: fixture.meetingSpeakerId,
                        embedding: speaker.representative,
                        quality: 1
                    ).insert(db)
                }
                _ = try MeetingSpeakerRecord.deleteOne(db, key: fixture.meetingSpeakerId)
                let nullableSpeakerId = try UUID.fetchOne(
                    db,
                    sql: "SELECT meetingSpeakerId FROM transcript_segments WHERE id = ?",
                    arguments: [fixture.transcriptId]
                )
                #expect(nullableSpeakerId == nil)

                let indexColumns = try String.fetchAll(
                    db,
                    sql: """
                    SELECT name FROM pragma_index_info('transcript_segments_on_meetingSpeakerId_startTime_id')
                    ORDER BY seqno
                    """
                )
                #expect(indexColumns == ["meetingSpeakerId", "startTime", "id"])

                _ = try MeetingRecord.deleteOne(db, key: fixture.meetingId)
                #expect(try SpeakerAnalysisRecord.fetchCount(db) == 0)
            }
        }

        @Test
        func deletingTop2CandidatePreservesRejectedObservation() throws {
            let fixture = try MigrationFixture()
            let top2ContactId = UUID.v7()
            try fixture.database.dbQueue.write { db in
                try ContactRecord(
                    id: top2ContactId,
                    vaultId: fixture.vaultId,
                    email: "top2@example.com",
                    displayName: "Top 2",
                    revision: 1,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                try SpeakerMatchObservationRecord(
                    meetingSpeakerId: fixture.meetingSpeakerId,
                    embeddingSpaceId: fixture.spaceId,
                    top1ContactId: fixture.contactId,
                    top1Score: 0.91,
                    top2ContactId: top2ContactId,
                    top2Score: 0.55,
                    margin: 0.36,
                    state: .rejected,
                    unknownReason: nil,
                    revision: 1,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)

                _ = try ContactRecord.deleteOne(db, key: top2ContactId)
                let fetched = try SpeakerMatchObservationRecord.fetchOne(db, key: fixture.meetingSpeakerId)
                let observation = try #require(fetched)
                #expect(observation.state == .rejected)
                #expect(observation.top1ContactId == fixture.contactId)
                #expect(observation.top1Score == 0.91)
                #expect(observation.top2ContactId == nil)
                #expect(observation.top2Score == nil)
                #expect(observation.margin == nil)
            }
        }
    }

    struct SpeakerIdentityCandidateCleanupMigrationTests {
        @Test(arguments: [false, true])
        func deletingCandidateSurvivesStaleOrMissingAnalysisSpace(analysisSpaceIsNull: Bool) throws {
            let fixture = try MigrationFixture()
            try fixture.database.dbQueue.write { db in
                try SpeakerMatchObservationRecord(
                    meetingSpeakerId: fixture.meetingSpeakerId,
                    embeddingSpaceId: fixture.spaceId,
                    top1ContactId: fixture.contactId,
                    top1Score: 0.91,
                    top2ContactId: nil,
                    top2Score: nil,
                    margin: nil,
                    state: .rejected,
                    unknownReason: nil,
                    revision: 1,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                let replacementSpaceId: UUID?
                if analysisSpaceIsNull {
                    replacementSpaceId = nil
                } else {
                    let spaceId = UUID.v7()
                    try SpeakerEmbeddingSpaceRecord(
                        id: spaceId,
                        space: MigrationFixture.embeddingSpace(assetFingerprint: "replacement-fingerprint"),
                        createdAt: .now
                    ).insert(db)
                    replacementSpaceId = spaceId
                }
                try db.execute(
                    sql: """
                    UPDATE speaker_analyses
                    SET embeddingSpaceId = ?, state = 'failed', failureReason = 'configuration changed'
                    WHERE id = (SELECT analysisId FROM meeting_speakers WHERE id = ?)
                    """,
                    arguments: [replacementSpaceId, fixture.meetingSpeakerId]
                )

                _ = try ContactRecord.deleteOne(db, key: fixture.contactId)
                let observation = try #require(
                    try SpeakerMatchObservationRecord.fetchOne(db, key: fixture.meetingSpeakerId)
                )
                #expect(observation.state == .rejected)
                #expect(observation.top1ContactId == nil)
                #expect(observation.top1Score == nil)
                #expect(observation.top2ContactId == nil)
                #expect(observation.top2Score == nil)
                #expect(observation.margin == nil)
                #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }

        @Test
        func scopeValidationStillRejectsNewWrongVaultCandidateAndEmbeddingSpace() throws {
            let fixture = try MigrationFixture()
            let otherVaultId = UUID.v7()
            let otherContactId = UUID.v7()
            let otherSpaceId = UUID.v7()
            try fixture.database.dbQueue.write { db in
                try SpeakerMatchObservationRecord(
                    meetingSpeakerId: fixture.meetingSpeakerId,
                    embeddingSpaceId: fixture.spaceId,
                    top1ContactId: nil,
                    top1Score: nil,
                    top2ContactId: nil,
                    top2Score: nil,
                    margin: nil,
                    state: .referenceOnly,
                    unknownReason: nil,
                    revision: 1,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                try VaultRecord(
                    id: otherVaultId,
                    path: "/tmp/speaker-other-vault",
                    name: "Other",
                    createdAt: .now,
                    lastOpenedAt: .now
                ).insert(db)
                try ContactRecord(
                    id: otherContactId,
                    vaultId: otherVaultId,
                    email: "other@example.com",
                    displayName: "Other",
                    revision: 1,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                try SpeakerEmbeddingSpaceRecord(
                    id: otherSpaceId,
                    space: MigrationFixture.embeddingSpace(assetFingerprint: "other-fingerprint"),
                    createdAt: .now
                ).insert(db)

                #expect(throws: (any Error).self) {
                    try db.execute(
                        sql: "UPDATE speaker_match_observations SET top1ContactId = ?, top1Score = 0.9 WHERE meetingSpeakerId = ?",
                        arguments: [otherContactId, fixture.meetingSpeakerId]
                    )
                }
                #expect(throws: (any Error).self) {
                    try db.execute(
                        sql: "UPDATE speaker_match_observations SET embeddingSpaceId = ? WHERE meetingSpeakerId = ?",
                        arguments: [otherSpaceId, fixture.meetingSpeakerId]
                    )
                }
            }
        }
    }

    private extension SpeakerIdentityMigrationTests {
        func v34TriggerDefinitions(in db: Database) throws -> [String] {
            try String.fetchAll(
                db,
                sql: """
                SELECT name || char(10) || sql
                FROM sqlite_master
                WHERE type = 'trigger' AND name IN (
                    'speaker_contact_assignments_validate_vault',
                    'speaker_contact_assignments_validate_vault_update',
                    'speaker_profiles_validate_vault',
                    'speaker_profiles_validate_vault_update',
                    'speaker_match_observations_validate_scope',
                    'speaker_match_observations_validate_scope_update',
                    'contacts_clear_speaker_match_candidates',
                    'transcript_segments_validate_meetingSpeaker_insert',
                    'transcript_segments_validate_meetingSpeaker_update'
                )
                ORDER BY name
                """
            )
        }

        func installPreviousV34Triggers(in db: Database) throws {
            try db.execute(sql: """
            DROP TRIGGER speaker_match_observations_validate_scope_update;
            CREATE TRIGGER speaker_match_observations_validate_scope_update
            BEFORE UPDATE OF embeddingSpaceId, top1ContactId, top2ContactId ON speaker_match_observations
            BEGIN
                SELECT RAISE(ABORT, 'speaker match must use the analysis embedding space and meeting vault')
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM meeting_speakers
                    JOIN speaker_analyses ON speaker_analyses.id = meeting_speakers.analysisId
                    JOIN recording_sessions ON recording_sessions.id = speaker_analyses.recordingSessionId
                    JOIN meetings ON meetings.id = recording_sessions.meetingId
                    WHERE meeting_speakers.id = NEW.meetingSpeakerId
                      AND speaker_analyses.embeddingSpaceId = NEW.embeddingSpaceId
                      AND (NEW.top1ContactId IS NULL OR EXISTS (
                          SELECT 1 FROM contacts WHERE id = NEW.top1ContactId AND vaultId = meetings.vaultId
                      ))
                      AND (NEW.top2ContactId IS NULL OR EXISTS (
                          SELECT 1 FROM contacts WHERE id = NEW.top2ContactId AND vaultId = meetings.vaultId
                      ))
                );
            END;

            DROP TRIGGER contacts_clear_speaker_match_candidates;
            CREATE TRIGGER contacts_clear_speaker_match_candidates
            BEFORE DELETE ON contacts
            BEGIN
                UPDATE speaker_match_observations
                SET top1ContactId = CASE WHEN top1ContactId = OLD.id THEN NULL ELSE top1ContactId END,
                    top1Score = CASE WHEN top1ContactId = OLD.id THEN NULL ELSE top1Score END,
                    top2ContactId = CASE WHEN top2ContactId = OLD.id THEN NULL ELSE top2ContactId END,
                    top2Score = CASE WHEN top2ContactId = OLD.id THEN NULL ELSE top2Score END,
                    margin = CASE
                        WHEN top1ContactId = OLD.id OR top2ContactId = OLD.id THEN NULL
                        ELSE margin
                    END
                WHERE top1ContactId = OLD.id OR top2ContactId = OLD.id;
            END;
            """)
        }

        private func insertLegacyRows(in queue: DatabaseQueue) throws -> (meetingId: UUID, transcriptId: UUID, contactId: UUID) {
            let vaultId = UUID.v7()
            let meetingId = UUID.v7()
            let transcriptId = UUID.v7()
            let contactId = UUID.v7()
            try queue.write { db in
                try VaultRecord(
                    id: vaultId,
                    path: "/tmp/speaker-migration-vault",
                    name: "Vault",
                    createdAt: .now,
                    lastOpenedAt: .now
                ).insert(db)
                try MeetingRecord(
                    id: meetingId,
                    vaultId: vaultId,
                    projectId: nil,
                    name: "Preserved meeting",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                try db.execute(
                    sql: """
                    INSERT INTO transcript_segments (
                        id, meetingId, startTime, text, isConfirmed, speakerLabel
                    ) VALUES (?, ?, ?, ?, 1, 'mic')
                    """,
                    arguments: [transcriptId, meetingId, Date.now, "Preserved transcript"]
                )
                try ContactRecord(
                    id: contactId,
                    vaultId: vaultId,
                    email: "person@example.com",
                    displayName: "Person",
                    revision: 1,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            return (meetingId, transcriptId, contactId)
        }
    }

    private struct MigrationFixture {
        let database: AppDatabaseManager
        let vaultId: UUID
        let meetingId: UUID
        let sessionId: UUID
        let spaceId: UUID
        let meetingSpeakerId: UUID
        let transcriptId: UUID
        let contactId: UUID

        // swiftlint:disable:next function_body_length
        init() throws {
            database = try AppDatabaseManager(path: ":memory:")
            meetingId = .v7()
            sessionId = .v7()
            spaceId = .v7()
            meetingSpeakerId = .v7()
            transcriptId = .v7()
            contactId = .v7()
            vaultId = .v7()
            let now = Date.now
            let analysisId = UUID.v7()
            var values = [Float](repeating: 0, count: SpeakerEmbeddingValidation.dimensionCount)
            values[0] = 1
            try database.dbQueue.write { db in
                try VaultRecord(
                    id: vaultId,
                    path: "/tmp/speaker-schema-vault",
                    name: "Vault",
                    createdAt: now,
                    lastOpenedAt: now
                ).insert(db)
                try MeetingRecord(
                    id: meetingId,
                    vaultId: vaultId,
                    projectId: nil,
                    name: "Meeting",
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
                try ContactRecord(
                    id: contactId,
                    vaultId: vaultId,
                    email: "schema@example.com",
                    displayName: "Schema",
                    revision: 1,
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
                try RecordingSessionRecord(
                    id: sessionId,
                    meetingId: meetingId,
                    startedAt: now,
                    endedAt: now,
                    duration: 1,
                    offsetSeconds: 0,
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
                try TranscriptSegmentRecord(
                    id: transcriptId,
                    meetingId: meetingId,
                    startTime: now,
                    text: "Text",
                    translatedText: nil,
                    isConfirmed: true,
                    speakerLabel: "mic"
                ).insert(db)
                try SpeakerEmbeddingSpaceRecord(id: spaceId, space: Self.space, createdAt: now).insert(db)
                try SpeakerAnalysisRecord(
                    id: analysisId,
                    recordingSessionId: sessionId,
                    audioSource: .microphone,
                    embeddingSpaceId: spaceId,
                    state: .succeeded,
                    failureReason: nil,
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
                try MeetingSpeakerRecord(
                    id: meetingSpeakerId,
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
            }
        }

        static let space = embeddingSpace(assetFingerprint: "fingerprint")

        static func embeddingSpace(assetFingerprint: String) -> SpeakerEmbeddingSpace {
            SpeakerEmbeddingSpace(
                provider: "FluidAudio",
                modelName: "speaker-diarization",
                revision: "revision",
                assetFingerprint: assetFingerprint,
                fluidAudioVersion: "0.15.5",
                dimensionCount: SpeakerEmbeddingValidation.dimensionCount,
                sampleRate: 16000,
                preprocessing: "mono-float32",
                excludesOverlap: true,
                normalization: "l2",
                similarityDefinition: "cosine-dot-product"
            )
        }
    }
#endif
// swiftlint:enable file_length
