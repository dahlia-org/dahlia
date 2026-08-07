import Foundation
import GRDB

enum MeetingSpeakerClusterMigration {
    // The schema, indexes, validation triggers, and v34 backfill form one atomic migration.
    // swiftlint:disable:next function_body_length
    static func migrate(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS meeting_speaker_clusters (
            id BLOB PRIMARY KEY NOT NULL,
            meetingId BLOB NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            audioSource TEXT NOT NULL CHECK (audioSource IN ('microphone', 'system')),
            embeddingSpaceId BLOB NOT NULL REFERENCES speaker_embedding_spaces(id),
            representative BLOB NOT NULL,
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL
        );

        CREATE TABLE IF NOT EXISTS meeting_speaker_cluster_members (
            meetingSpeakerId BLOB PRIMARY KEY NOT NULL REFERENCES meeting_speakers(id) ON DELETE CASCADE,
            clusterId BLOB NOT NULL REFERENCES meeting_speaker_clusters(id) ON DELETE CASCADE,
            createdAt DATETIME NOT NULL
        );

        CREATE TABLE IF NOT EXISTS speaker_cluster_contact_assignments (
            clusterId BLOB PRIMARY KEY NOT NULL REFERENCES meeting_speaker_clusters(id) ON DELETE CASCADE,
            contactId BLOB NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
            origin TEXT NOT NULL CHECK (origin IN ('manual', 'suggestionApproved', 'ownerChannelConfirmation')),
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL
        );

        CREATE INDEX IF NOT EXISTS meeting_speaker_clusters_on_meeting_source_space
            ON meeting_speaker_clusters(meetingId, audioSource, embeddingSpaceId, id);
        CREATE INDEX IF NOT EXISTS meeting_speaker_cluster_members_on_clusterId_meetingSpeakerId
            ON meeting_speaker_cluster_members(clusterId, meetingSpeakerId);
        CREATE INDEX IF NOT EXISTS speaker_cluster_contact_assignments_on_contactId_clusterId
            ON speaker_cluster_contact_assignments(contactId, clusterId);

        CREATE TRIGGER IF NOT EXISTS speaker_cluster_contact_assignments_validate_vault
        BEFORE INSERT ON speaker_cluster_contact_assignments
        BEGIN
            SELECT RAISE(ABORT, 'speaker cluster assignment contact must belong to the meeting vault')
            WHERE NOT EXISTS (
                SELECT 1
                FROM meeting_speaker_clusters
                JOIN meetings ON meetings.id = meeting_speaker_clusters.meetingId
                JOIN contacts ON contacts.id = NEW.contactId AND contacts.vaultId = meetings.vaultId
                WHERE meeting_speaker_clusters.id = NEW.clusterId
            );
        END;

        CREATE TRIGGER IF NOT EXISTS speaker_cluster_contact_assignments_validate_vault_update
        BEFORE UPDATE OF contactId ON speaker_cluster_contact_assignments
        BEGIN
            SELECT RAISE(ABORT, 'speaker cluster assignment contact must belong to the meeting vault')
            WHERE NOT EXISTS (
                SELECT 1
                FROM meeting_speaker_clusters
                JOIN meetings ON meetings.id = meeting_speaker_clusters.meetingId
                JOIN contacts ON contacts.id = NEW.contactId AND contacts.vaultId = meetings.vaultId
                WHERE meeting_speaker_clusters.id = NEW.clusterId
            );
        END;
        """)

        let requiredTables = [
            "meetings", "recording_sessions", "speaker_embedding_spaces", "speaker_analyses",
            "meeting_speakers", "speaker_contact_assignments",
        ]
        guard try requiredTables.allSatisfy({ try db.tableExists($0) }),
              try db.columns(in: "recording_sessions").contains(where: { $0.name == "meetingId" })
        else {
            return
        }
        try MeetingSpeakerClusterer.assignUnclusteredSpeakers(meetingId: nil, now: .now, in: db)
    }
}
