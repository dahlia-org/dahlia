import GRDB

// The migration stays as one schema unit so its tables, indexes, and validation triggers are reviewed together.
// swiftlint:disable:next type_body_length
enum SpeakerIdentityMigration {
    static func migrate(in db: Database) throws {
        try createTables(in: db)
        try createIndexes(in: db)
        try createValidationTriggers(in: db)
        try addTranscriptMeetingSpeakerColumn(in: db)
    }

    // swiftlint:disable:next function_body_length
    private static func createTables(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS speaker_embedding_spaces (
            id BLOB PRIMARY KEY NOT NULL,
            provider TEXT NOT NULL,
            modelName TEXT NOT NULL,
            revision TEXT NOT NULL,
            assetFingerprint TEXT NOT NULL,
            fluidAudioVersion TEXT NOT NULL,
            dimensionCount INTEGER NOT NULL CHECK (dimensionCount > 0),
            sampleRate INTEGER NOT NULL CHECK (sampleRate > 0),
            preprocessing TEXT NOT NULL,
            excludesOverlap BOOLEAN NOT NULL CHECK (excludesOverlap IN (0, 1)),
            normalization TEXT NOT NULL,
            similarityDefinition TEXT NOT NULL,
            createdAt DATETIME NOT NULL,
            UNIQUE (
                provider, modelName, revision, assetFingerprint, fluidAudioVersion,
                dimensionCount, sampleRate, preprocessing, excludesOverlap,
                normalization, similarityDefinition
            )
        );

        CREATE TABLE IF NOT EXISTS speaker_analyses (
            id BLOB PRIMARY KEY NOT NULL,
            recordingSessionId BLOB NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE,
            audioSource TEXT NOT NULL CHECK (audioSource IN ('microphone', 'system')),
            embeddingSpaceId BLOB REFERENCES speaker_embedding_spaces(id),
            state TEXT NOT NULL CHECK (state IN ('succeeded', 'failed')),
            failureReason TEXT,
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL,
            UNIQUE (recordingSessionId, audioSource),
            CHECK (
                (state = 'succeeded' AND embeddingSpaceId IS NOT NULL AND failureReason IS NULL)
                OR (state = 'failed' AND failureReason IS NOT NULL)
            )
        );

        CREATE TABLE IF NOT EXISTS meeting_speakers (
            id BLOB PRIMARY KEY NOT NULL,
            analysisId BLOB NOT NULL REFERENCES speaker_analyses(id) ON DELETE CASCADE,
            localSpeakerId TEXT NOT NULL,
            representative BLOB NOT NULL,
            representativeQuality DOUBLE NOT NULL CHECK (representativeQuality >= 0),
            representativeSource TEXT NOT NULL CHECK (representativeSource IN ('diarization', 'speakerDatabase')),
            profileUpdateEligible BOOLEAN NOT NULL CHECK (profileUpdateEligible IN (0, 1)),
            revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0),
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL,
            UNIQUE (analysisId, localSpeakerId),
            CHECK (representativeSource <> 'speakerDatabase' OR profileUpdateEligible = 0)
        );

        CREATE TABLE IF NOT EXISTS meeting_speaker_exemplars (
            meetingSpeakerId BLOB NOT NULL REFERENCES meeting_speakers(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL CHECK (ordinal BETWEEN 0 AND 2),
            embedding BLOB NOT NULL,
            quality DOUBLE NOT NULL CHECK (quality >= 0),
            PRIMARY KEY (meetingSpeakerId, ordinal)
        );

        CREATE TABLE IF NOT EXISTS speaker_diarization_spans (
            id BLOB PRIMARY KEY NOT NULL,
            meetingSpeakerId BLOB NOT NULL REFERENCES meeting_speakers(id) ON DELETE CASCADE,
            startSeconds DOUBLE NOT NULL CHECK (startSeconds >= 0),
            endSeconds DOUBLE NOT NULL CHECK (endSeconds > startSeconds),
            createdAt DATETIME NOT NULL,
            UNIQUE (meetingSpeakerId, startSeconds, endSeconds)
        );

        CREATE TABLE IF NOT EXISTS speaker_contact_assignments (
            meetingSpeakerId BLOB PRIMARY KEY NOT NULL REFERENCES meeting_speakers(id) ON DELETE CASCADE,
            contactId BLOB NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
            origin TEXT NOT NULL CHECK (origin IN ('manual', 'suggestionApproved', 'ownerChannelConfirmation')),
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL
        );

        CREATE TABLE IF NOT EXISTS speaker_match_observations (
            meetingSpeakerId BLOB PRIMARY KEY NOT NULL REFERENCES meeting_speakers(id) ON DELETE CASCADE,
            embeddingSpaceId BLOB NOT NULL REFERENCES speaker_embedding_spaces(id),
            top1ContactId BLOB REFERENCES contacts(id) ON DELETE SET NULL,
            top1Score DOUBLE,
            top2ContactId BLOB REFERENCES contacts(id) ON DELETE SET NULL,
            top2Score DOUBLE,
            margin DOUBLE,
            state TEXT NOT NULL CHECK (state IN ('referenceOnly', 'suggested', 'rejected', 'undeterminable')),
            unknownReason TEXT,
            revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0),
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL,
            CHECK (top1ContactId IS NULL = (top1Score IS NULL)),
            CHECK (top2ContactId IS NULL = (top2Score IS NULL)),
            CHECK (margin IS NULL OR (top1Score IS NOT NULL AND top2Score IS NOT NULL)),
            CHECK ((state = 'undeterminable') = (unknownReason IS NOT NULL))
        );

        CREATE TABLE IF NOT EXISTS speaker_profiles (
            id BLOB PRIMARY KEY NOT NULL,
            vaultId BLOB NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            contactId BLOB NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
            embeddingSpaceId BLOB NOT NULL REFERENCES speaker_embedding_spaces(id),
            representative BLOB NOT NULL,
            contributingMeetingCount INTEGER NOT NULL CHECK (contributingMeetingCount > 0),
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL,
            UNIQUE (contactId, embeddingSpaceId)
        );

        CREATE TABLE IF NOT EXISTS speaker_profile_exemplars (
            profileId BLOB NOT NULL REFERENCES speaker_profiles(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL CHECK (ordinal BETWEEN 0 AND 4),
            meetingSpeakerId BLOB NOT NULL REFERENCES meeting_speakers(id) ON DELETE CASCADE,
            embedding BLOB NOT NULL,
            quality DOUBLE NOT NULL CHECK (quality >= 0),
            PRIMARY KEY (profileId, ordinal),
            UNIQUE (profileId, meetingSpeakerId)
        );

        CREATE TABLE IF NOT EXISTS speaker_match_policy (
            id INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
            formatVersion INTEGER NOT NULL CHECK (formatVersion > 0),
            state TEXT NOT NULL CHECK (state IN ('calibrationRequired', 'calibrated')),
            minimumSimilarity DOUBLE,
            minimumMargin DOUBLE,
            updatedAt DATETIME NOT NULL,
            CHECK (
                (state = 'calibrationRequired' AND minimumSimilarity IS NULL AND minimumMargin IS NULL)
                OR (state = 'calibrated' AND minimumSimilarity IS NOT NULL AND minimumMargin IS NOT NULL)
            )
        );

        INSERT OR IGNORE INTO speaker_match_policy (
            id, formatVersion, state, minimumSimilarity, minimumMargin, updatedAt
        ) VALUES (1, 1, 'calibrationRequired', NULL, NULL, CURRENT_TIMESTAMP);
        """)
    }

    private static func createIndexes(in db: Database) throws {
        try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS speaker_analyses_on_embeddingSpaceId
            ON speaker_analyses(embeddingSpaceId);
        CREATE INDEX IF NOT EXISTS meeting_speakers_on_analysisId_id
            ON meeting_speakers(analysisId, id);
        CREATE INDEX IF NOT EXISTS speaker_diarization_spans_on_meetingSpeakerId_startSeconds
            ON speaker_diarization_spans(meetingSpeakerId, startSeconds);
        CREATE INDEX IF NOT EXISTS speaker_contact_assignments_on_contactId_meetingSpeakerId
            ON speaker_contact_assignments(contactId, meetingSpeakerId);
        CREATE INDEX IF NOT EXISTS speaker_match_observations_on_embeddingSpaceId_state
            ON speaker_match_observations(embeddingSpaceId, state);
        CREATE INDEX IF NOT EXISTS speaker_profiles_on_vaultId_embeddingSpaceId_contactId
            ON speaker_profiles(vaultId, embeddingSpaceId, contactId);
        CREATE INDEX IF NOT EXISTS speaker_profile_exemplars_on_meetingSpeakerId
            ON speaker_profile_exemplars(meetingSpeakerId);
        """)
    }

    // swiftlint:disable:next function_body_length
    private static func createValidationTriggers(in db: Database) throws {
        try db.execute(sql: """
        DROP TRIGGER IF EXISTS speaker_contact_assignments_validate_vault;
        DROP TRIGGER IF EXISTS speaker_contact_assignments_validate_vault_update;
        DROP TRIGGER IF EXISTS speaker_profiles_validate_vault;
        DROP TRIGGER IF EXISTS speaker_profiles_validate_vault_update;
        DROP TRIGGER IF EXISTS speaker_match_observations_validate_scope;
        DROP TRIGGER IF EXISTS speaker_match_observations_validate_scope_update;
        DROP TRIGGER IF EXISTS contacts_clear_speaker_match_candidates;

        CREATE TRIGGER speaker_contact_assignments_validate_vault
        BEFORE INSERT ON speaker_contact_assignments
        BEGIN
            SELECT RAISE(ABORT, 'speaker assignment contact must belong to the meeting vault')
            WHERE NOT EXISTS (
                SELECT 1
                FROM meeting_speakers
                JOIN speaker_analyses ON speaker_analyses.id = meeting_speakers.analysisId
                JOIN recording_sessions ON recording_sessions.id = speaker_analyses.recordingSessionId
                JOIN meetings ON meetings.id = recording_sessions.meetingId
                JOIN contacts ON contacts.id = NEW.contactId AND contacts.vaultId = meetings.vaultId
                WHERE meeting_speakers.id = NEW.meetingSpeakerId
            );
        END;

        CREATE TRIGGER speaker_contact_assignments_validate_vault_update
        BEFORE UPDATE OF contactId ON speaker_contact_assignments
        BEGIN
            SELECT RAISE(ABORT, 'speaker assignment contact must belong to the meeting vault')
            WHERE NOT EXISTS (
                SELECT 1
                FROM meeting_speakers
                JOIN speaker_analyses ON speaker_analyses.id = meeting_speakers.analysisId
                JOIN recording_sessions ON recording_sessions.id = speaker_analyses.recordingSessionId
                JOIN meetings ON meetings.id = recording_sessions.meetingId
                JOIN contacts ON contacts.id = NEW.contactId AND contacts.vaultId = meetings.vaultId
                WHERE meeting_speakers.id = NEW.meetingSpeakerId
            );
        END;

        CREATE TRIGGER speaker_profiles_validate_vault
        BEFORE INSERT ON speaker_profiles
        BEGIN
            SELECT RAISE(ABORT, 'speaker profile contact must belong to its vault')
            WHERE NOT EXISTS (
                SELECT 1 FROM contacts WHERE id = NEW.contactId AND vaultId = NEW.vaultId
            );
        END;

        CREATE TRIGGER speaker_profiles_validate_vault_update
        BEFORE UPDATE OF vaultId, contactId ON speaker_profiles
        BEGIN
            SELECT RAISE(ABORT, 'speaker profile contact must belong to its vault')
            WHERE NOT EXISTS (
                SELECT 1 FROM contacts WHERE id = NEW.contactId AND vaultId = NEW.vaultId
            );
        END;

        CREATE TRIGGER speaker_match_observations_validate_scope
        BEFORE INSERT ON speaker_match_observations
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

        CREATE TRIGGER speaker_match_observations_validate_scope_update
        BEFORE UPDATE OF embeddingSpaceId, top1ContactId, top2ContactId ON speaker_match_observations
        BEGIN
            SELECT RAISE(ABORT, 'speaker match must use the analysis embedding space and meeting vault')
            WHERE (NEW.embeddingSpaceId IS NOT OLD.embeddingSpaceId AND NOT EXISTS (
                SELECT 1
                FROM meeting_speakers
                JOIN speaker_analyses ON speaker_analyses.id = meeting_speakers.analysisId
                WHERE meeting_speakers.id = NEW.meetingSpeakerId
                  AND speaker_analyses.embeddingSpaceId = NEW.embeddingSpaceId
            )) OR (NEW.top1ContactId IS NOT OLD.top1ContactId
                AND NEW.top1ContactId IS NOT NULL
                AND NOT EXISTS (
                    SELECT 1
                    FROM meeting_speakers
                    JOIN speaker_analyses ON speaker_analyses.id = meeting_speakers.analysisId
                    JOIN recording_sessions ON recording_sessions.id = speaker_analyses.recordingSessionId
                    JOIN meetings ON meetings.id = recording_sessions.meetingId
                    JOIN contacts ON contacts.id = NEW.top1ContactId AND contacts.vaultId = meetings.vaultId
                    WHERE meeting_speakers.id = NEW.meetingSpeakerId
                )
            ) OR (NEW.top2ContactId IS NOT OLD.top2ContactId
                AND NEW.top2ContactId IS NOT NULL
                AND NOT EXISTS (
                    SELECT 1
                    FROM meeting_speakers
                    JOIN speaker_analyses ON speaker_analyses.id = meeting_speakers.analysisId
                    JOIN recording_sessions ON recording_sessions.id = speaker_analyses.recordingSessionId
                    JOIN meetings ON meetings.id = recording_sessions.meetingId
                    JOIN contacts ON contacts.id = NEW.top2ContactId AND contacts.vaultId = meetings.vaultId
                    WHERE meeting_speakers.id = NEW.meetingSpeakerId
                )
            );
        END;

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
                END,
                state = CASE
                    WHEN state = 'suggested' AND top1ContactId = OLD.id THEN 'undeterminable'
                    ELSE state
                END,
                unknownReason = CASE
                    WHEN state = 'suggested' AND top1ContactId = OLD.id THEN 'insufficientEvidence'
                    ELSE unknownReason
                END
            WHERE top1ContactId = OLD.id OR top2ContactId = OLD.id;
        END;
        """)
    }

    private static func addTranscriptMeetingSpeakerColumn(in db: Database) throws {
        guard try db.tableExists("transcript_segments") else { return }
        let columns = try db.columns(in: "transcript_segments")
        if !columns.contains(where: { $0.name == "meetingSpeakerId" }) {
            try db.execute(sql: """
            ALTER TABLE transcript_segments
            ADD COLUMN meetingSpeakerId BLOB REFERENCES meeting_speakers(id) ON DELETE SET NULL
            """)
        }
        try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS transcript_segments_on_meetingSpeakerId_startTime_id
        ON transcript_segments(meetingSpeakerId, startTime, id)
        """)
        try db.execute(sql: """
        DROP TRIGGER IF EXISTS transcript_segments_validate_meetingSpeaker_insert;
        DROP TRIGGER IF EXISTS transcript_segments_validate_meetingSpeaker_update;

        CREATE TRIGGER transcript_segments_validate_meetingSpeaker_insert
        BEFORE INSERT ON transcript_segments
        WHEN NEW.meetingSpeakerId IS NOT NULL
        BEGIN
            SELECT RAISE(ABORT, 'transcript speaker must belong to the same meeting')
            WHERE NOT EXISTS (
                SELECT 1
                FROM meeting_speakers
                JOIN speaker_analyses ON speaker_analyses.id = meeting_speakers.analysisId
                JOIN recording_sessions ON recording_sessions.id = speaker_analyses.recordingSessionId
                WHERE meeting_speakers.id = NEW.meetingSpeakerId
                  AND recording_sessions.meetingId = NEW.meetingId
            );
        END;

        CREATE TRIGGER transcript_segments_validate_meetingSpeaker_update
        BEFORE UPDATE OF meetingId, meetingSpeakerId ON transcript_segments
        WHEN NEW.meetingSpeakerId IS NOT NULL
        BEGIN
            SELECT RAISE(ABORT, 'transcript speaker must belong to the same meeting')
            WHERE NOT EXISTS (
                SELECT 1
                FROM meeting_speakers
                JOIN speaker_analyses ON speaker_analyses.id = meeting_speakers.analysisId
                JOIN recording_sessions ON recording_sessions.id = speaker_analyses.recordingSessionId
                WHERE meeting_speakers.id = NEW.meetingSpeakerId
                  AND recording_sessions.meetingId = NEW.meetingId
            );
        END;
        """)
    }
}
