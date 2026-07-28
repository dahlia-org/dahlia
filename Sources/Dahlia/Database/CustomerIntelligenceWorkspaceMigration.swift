import Foundation
import GRDB

/// Adds the bounded organization workspace and conversation topics.
///
/// The contact-related tables are rebuilt together because `contacts.email` changes
/// from required to nullable. This migration is registered with deferred foreign-key
/// checks so released databases keep every existing identifier and relationship.
enum CustomerIntelligenceWorkspaceMigration { // swiftlint:disable:this type_body_length
    static func migrate(in db: Database) throws {
        let snapshot = try ReferenceSnapshot.capture(in: db)
        try dropCustomerIntelligenceTriggers(in: db)
        try rebuildContactTables(in: db)
        try snapshot.validate(in: db)

        try db.alter(table: "organizations") {
            $0.add(column: "revision", .integer).notNull().defaults(to: 1)
        }
        try db.alter(table: "insights") {
            $0.add(column: "revision", .integer).notNull().defaults(to: 1)
        }
        try createWorkspaceTables(in: db)
        try createIndexes(in: db)
        try CustomerIntelligenceMigration.createOrganizationTriggers(in: db)
        try CustomerIntelligenceMigration.createVaultImmutabilityTriggers(in: db)
        try CustomerIntelligenceMigration.createRelationshipValidationTriggers(in: db)
        try CustomerIntelligenceMigration.createReferenceValidationTriggers(in: db)
        try CustomerIntelligenceMigration.createReferenceCleanupTriggers(in: db)
        try createRevisionTriggers(in: db)
        try createWorkspaceValidationTriggers(in: db)
        try createWorkspaceCleanupTriggers(in: db)
        try validateForeignKeys(in: db)
    }

    private struct ReferenceSnapshot {
        let contactIDs: [UUID]
        let memberships: Int
        let membershipKeys: [String]
        let participants: Int
        let participantKeys: [String]
        let projectReferences: Int
        let insightReferences: Int

        static func capture(in db: Database) throws -> Self {
            try Self(
                contactIDs: UUID.fetchAll(db, sql: "SELECT id FROM contacts ORDER BY id"),
                memberships: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM organization_memberships") ?? 0,
                membershipKeys: String.fetchAll(
                    db,
                    sql: """
                    SELECT LOWER(HEX(organizationId)) || ':' || LOWER(HEX(contactId))
                    FROM organization_memberships
                    ORDER BY organizationId, contactId
                    """
                ),
                participants: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_participants") ?? 0,
                participantKeys: String.fetchAll(
                    db,
                    sql: """
                    SELECT LOWER(HEX(meetingId)) || ':' || LOWER(HEX(contactId))
                    FROM meeting_participants
                    ORDER BY meetingId, contactId
                    """
                ),
                projectReferences: Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM project_resource_references WHERE resourceType = 'contact'"
                ) ?? 0,
                insightReferences: Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM insight_references WHERE resourceType = 'contact'"
                ) ?? 0
            )
        }

        func validate(in db: Database) throws {
            let migratedIDs = try UUID.fetchAll(db, sql: "SELECT id FROM contacts ORDER BY id")
            guard migratedIDs == contactIDs,
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM organization_memberships") == memberships,
                  try String.fetchAll(
                      db,
                      sql: """
                      SELECT LOWER(HEX(organizationId)) || ':' || LOWER(HEX(contactId))
                      FROM organization_memberships
                      ORDER BY organizationId, contactId
                      """
                  ) == membershipKeys,
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_participants") == participants,
                  try String.fetchAll(
                      db,
                      sql: """
                      SELECT LOWER(HEX(meetingId)) || ':' || LOWER(HEX(contactId))
                      FROM meeting_participants
                      ORDER BY meetingId, contactId
                      """
                  ) == participantKeys,
                  try Int.fetchOne(
                      db,
                      sql: "SELECT COUNT(*) FROM project_resource_references WHERE resourceType = 'contact'"
                  ) == projectReferences,
                  try Int.fetchOne(
                      db,
                      sql: "SELECT COUNT(*) FROM insight_references WHERE resourceType = 'contact'"
                  ) == insightReferences
            else {
                throw DatabaseError(message: "customer intelligence rebuild did not preserve references")
            }
        }
    }

    private static func dropCustomerIntelligenceTriggers(in db: Database) throws {
        let triggerNames = [
            "contacts_prevent_vault_change",
            "insights_prevent_vault_change",
            "meetings_prevent_vault_change",
            "organizations_validate_insert",
            "organizations_validate_update",
            "organization_domains_validate_insert",
            "organization_domains_validate_update",
            "organization_domains_assign_first_primary",
            "organization_domains_promote_after_primary_delete",
            "organization_memberships_validate_insert",
            "organization_memberships_validate_update",
            "meeting_participants_validate_insert",
            "meeting_participants_validate_update",
            "project_resource_references_validate_insert",
            "project_resource_references_validate_update",
            "insight_references_validate_insert",
            "insight_references_validate_update",
            "organizations_cleanup_resource_references",
            "contacts_cleanup_resource_references",
            "projects_cleanup_resource_references",
            "meetings_cleanup_resource_references",
        ]
        for name in triggerNames {
            try db.execute(sql: "DROP TRIGGER IF EXISTS \(name)")
        }
    }

    private static func rebuildContactTables(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE contacts_v26 (
            id BLOB PRIMARY KEY NOT NULL,
            vaultId BLOB NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            email TEXT,
            displayName TEXT,
            revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0),
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL,
            UNIQUE(vaultId, email),
            CHECK (email IS NULL OR LENGTH(email) > 0),
            CHECK (displayName IS NULL OR LENGTH(TRIM(displayName)) > 0),
            CHECK (email IS NOT NULL OR displayName IS NOT NULL)
        );

        CREATE TABLE organization_memberships_v26 (
            organizationId BLOB NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
            contactId BLOB NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
            roleLabel TEXT,
            createdAt DATETIME NOT NULL,
            PRIMARY KEY (organizationId, contactId),
            CHECK (roleLabel IS NULL OR LENGTH(TRIM(roleLabel)) > 0)
        );

        CREATE TABLE meeting_participants_v26 (
            meetingId BLOB NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            contactId BLOB NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
            role TEXT NOT NULL CHECK (role IN ('organizer', 'required', 'optional', 'attendee', 'unknown')),
            responseStatus TEXT NOT NULL
                CHECK (responseStatus IN ('accepted', 'declined', 'tentative', 'needs_action', 'unknown')),
            source TEXT NOT NULL,
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL,
            PRIMARY KEY (meetingId, contactId),
            CHECK (LENGTH(TRIM(source)) > 0)
        );

        INSERT INTO contacts_v26 (id, vaultId, email, displayName, revision, createdAt, updatedAt)
        SELECT id, vaultId, email, displayName, 1, createdAt, updatedAt FROM contacts;

        INSERT INTO organization_memberships_v26 (organizationId, contactId, roleLabel, createdAt)
        SELECT organizationId, contactId, roleLabel, createdAt FROM organization_memberships;

        INSERT INTO meeting_participants_v26
            (meetingId, contactId, role, responseStatus, source, createdAt, updatedAt)
        SELECT meetingId, contactId, role, responseStatus, source, createdAt, updatedAt
        FROM meeting_participants;

        DROP TABLE organization_memberships;
        DROP TABLE meeting_participants;
        DROP TABLE contacts;

        ALTER TABLE contacts_v26 RENAME TO contacts;
        ALTER TABLE organization_memberships_v26 RENAME TO organization_memberships;
        ALTER TABLE meeting_participants_v26 RENAME TO meeting_participants;
        """)
    }

    private static func createWorkspaceTables(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE conversation_topics (
            id BLOB PRIMARY KEY NOT NULL,
            vaultId BLOB NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            title TEXT NOT NULL,
            currentState TEXT NOT NULL,
            revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0),
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL,
            CHECK (LENGTH(TRIM(title)) > 0),
            CHECK (LENGTH(TRIM(currentState)) > 0)
        );

        CREATE TABLE conversation_topic_references (
            topicId BLOB NOT NULL REFERENCES conversation_topics(id) ON DELETE CASCADE,
            resourceType TEXT NOT NULL
                CHECK (resourceType IN ('organization', 'contact', 'project', 'meeting')),
            resourceId BLOB NOT NULL,
            note TEXT,
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL,
            PRIMARY KEY (topicId, resourceType, resourceId),
            CHECK (
                (resourceType = 'meeting' AND note IS NOT NULL AND LENGTH(TRIM(note)) > 0)
                OR (resourceType <> 'meeting' AND note IS NULL)
            )
        );

        """)
    }

    private static func createIndexes(in db: Database) throws {
        try db.execute(sql: """
        CREATE INDEX contacts_on_vaultId_sortKey_id
            ON contacts(vaultId, COALESCE(displayName, email) COLLATE NOCASE, id);
        CREATE INDEX organization_memberships_on_contactId_organizationId
            ON organization_memberships(contactId, organizationId);
        CREATE INDEX meeting_participants_on_contactId_meetingId
            ON meeting_participants(contactId, meetingId);
        CREATE INDEX conversation_topics_on_vaultId_updatedAt_id
            ON conversation_topics(vaultId, updatedAt DESC, id DESC);
        CREATE INDEX conversation_topic_references_on_resource
            ON conversation_topic_references(resourceType, resourceId, topicId);
        """)
    }

    // swiftlint:disable:next function_body_length
    private static func createRevisionTriggers(in db: Database) throws {
        try db.execute(sql: """
        CREATE TRIGGER organization_domains_revision_insert
        AFTER INSERT ON organization_domains
        BEGIN
            UPDATE organizations SET revision = revision + 1 WHERE id = NEW.organizationId;
        END;
        CREATE TRIGGER organization_domains_revision_update
        AFTER UPDATE ON organization_domains
        BEGIN
            UPDATE organizations SET revision = revision + 1 WHERE id = NEW.organizationId;
        END;
        CREATE TRIGGER organization_domains_revision_delete
        AFTER DELETE ON organization_domains
        BEGIN
            UPDATE organizations SET revision = revision + 1 WHERE id = OLD.organizationId;
        END;

        CREATE TRIGGER organization_memberships_revision_insert
        AFTER INSERT ON organization_memberships
        BEGIN
            UPDATE organizations SET revision = revision + 1 WHERE id = NEW.organizationId;
        END;
        CREATE TRIGGER organization_memberships_revision_update
        AFTER UPDATE ON organization_memberships
        BEGIN
            UPDATE organizations SET revision = revision + 1 WHERE id = OLD.organizationId;
            UPDATE organizations SET revision = revision + 1
            WHERE id = NEW.organizationId AND NEW.organizationId <> OLD.organizationId;
        END;
        CREATE TRIGGER organization_memberships_revision_delete
        AFTER DELETE ON organization_memberships
        BEGIN
            UPDATE organizations SET revision = revision + 1 WHERE id = OLD.organizationId;
        END;

        CREATE TRIGGER meeting_participants_revision_insert
        AFTER INSERT ON meeting_participants
        BEGIN
            UPDATE contacts SET revision = revision + 1 WHERE id = NEW.contactId;
        END;
        CREATE TRIGGER meeting_participants_revision_update
        AFTER UPDATE ON meeting_participants
        BEGIN
            UPDATE contacts SET revision = revision + 1 WHERE id = OLD.contactId;
            UPDATE contacts SET revision = revision + 1
            WHERE id = NEW.contactId AND NEW.contactId <> OLD.contactId;
        END;
        CREATE TRIGGER meeting_participants_revision_delete
        AFTER DELETE ON meeting_participants
        BEGIN
            UPDATE contacts SET revision = revision + 1 WHERE id = OLD.contactId;
        END;
        CREATE TRIGGER conversation_topic_references_revision_insert
        AFTER INSERT ON conversation_topic_references
        BEGIN
            UPDATE conversation_topics SET revision = revision + 1, updatedAt = NEW.updatedAt
            WHERE id = NEW.topicId;
        END;
        CREATE TRIGGER conversation_topic_references_revision_update
        AFTER UPDATE ON conversation_topic_references
        BEGIN
            UPDATE conversation_topics SET revision = revision + 1, updatedAt = NEW.updatedAt
            WHERE id = NEW.topicId;
        END;
        CREATE TRIGGER conversation_topic_references_revision_delete
        AFTER DELETE ON conversation_topic_references
        BEGIN
            UPDATE conversation_topics SET revision = revision + 1
            WHERE id = OLD.topicId;
        END;
        """)
    }

    private static func createWorkspaceValidationTriggers(in db: Database) throws {
        try db.execute(sql: """
        CREATE TRIGGER conversation_topics_prevent_vault_change
        BEFORE UPDATE OF vaultId ON conversation_topics
        WHEN NEW.vaultId <> OLD.vaultId
        BEGIN
            SELECT RAISE(ABORT, 'conversation topic vault is immutable');
        END;

        CREATE TRIGGER conversation_topic_references_validate_insert
        BEFORE INSERT ON conversation_topic_references
        BEGIN
            SELECT RAISE(ABORT, 'topic resource does not exist in the topic vault')
            WHERE NOT (
                (NEW.resourceType = 'organization' AND EXISTS (
                    SELECT 1 FROM conversation_topics
                    JOIN organizations ON organizations.id = NEW.resourceId
                    WHERE conversation_topics.id = NEW.topicId
                      AND conversation_topics.vaultId = organizations.vaultId
                ))
                OR (NEW.resourceType = 'contact' AND EXISTS (
                    SELECT 1 FROM conversation_topics
                    JOIN contacts ON contacts.id = NEW.resourceId
                    WHERE conversation_topics.id = NEW.topicId
                      AND conversation_topics.vaultId = contacts.vaultId
                ))
                OR (NEW.resourceType = 'project' AND EXISTS (
                    SELECT 1 FROM conversation_topics
                    JOIN projects ON projects.id = NEW.resourceId
                    WHERE conversation_topics.id = NEW.topicId
                      AND conversation_topics.vaultId = projects.vaultId
                ))
                OR (NEW.resourceType = 'meeting' AND EXISTS (
                    SELECT 1 FROM conversation_topics
                    JOIN meetings ON meetings.id = NEW.resourceId
                    WHERE conversation_topics.id = NEW.topicId
                      AND conversation_topics.vaultId = meetings.vaultId
                ))
            );
        END;

        CREATE TRIGGER conversation_topic_references_validate_update
        BEFORE UPDATE OF topicId, resourceType, resourceId ON conversation_topic_references
        BEGIN
            SELECT RAISE(ABORT, 'topic reference identity is immutable')
            WHERE NEW.topicId <> OLD.topicId
               OR NEW.resourceType <> OLD.resourceType
               OR NEW.resourceId <> OLD.resourceId;
        END;

        """)
    }

    static func createWorkspaceCleanupTriggers(in db: Database) throws {
        let resources = [
            ("organizations", "organization"),
            ("contacts", "contact"),
            ("projects", "project"),
            ("meetings", "meeting"),
        ]
        for (table, resourceType) in resources {
            guard try db.tableExists(table) else { continue }
            try db.execute(sql: """
            CREATE TRIGGER \(table)_cleanup_workspace_references
            AFTER DELETE ON \(table)
            BEGIN
                DELETE FROM conversation_topic_references
                WHERE resourceType = '\(resourceType)' AND resourceId = OLD.id;
            END;
            """)
        }
    }

    private static func validateForeignKeys(in db: Database) throws {
        let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
        guard violations.isEmpty else {
            throw DatabaseError(message: "foreign key violations remain after customer intelligence rebuild")
        }
    }
}
