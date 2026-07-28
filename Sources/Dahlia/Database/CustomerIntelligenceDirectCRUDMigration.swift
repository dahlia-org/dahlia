import GRDB

/// Reconciles databases that applied the pre-release v25/v27 customer-intelligence schema.
///
/// Those builds stored Insight review state as a string and included the experimental
/// Glossary and proposal queues. The direct CRUD design uses a Boolean acceptance flag
/// and no staging tables, so this forward migration makes previously opened QA databases
/// match a fresh installation.
enum CustomerIntelligenceDirectCRUDMigration {
    static func migrate(in db: Database) throws {
        try rebuildInsightsIfNeeded(in: db)
        try removeRetiredSchema(in: db)
        try recreateReferenceTriggers(in: db)
    }

    private static func rebuildInsightsIfNeeded(in db: Database) throws {
        let columns = try Set(db.columns(in: "insights").map(\.name))
        guard !columns.contains("isAccepted") || !columns.contains("revision") || columns.contains("reviewState") else {
            return
        }
        let referenceCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM insight_references") ?? 0
        let acceptedValue = columns.contains("isAccepted")
            ? "isAccepted"
            : "CASE WHEN reviewState = 'accepted' THEN 1 ELSE 0 END"
        let revisionValue = columns.contains("revision") ? "revision" : "1"

        try db.execute(sql: """
        DROP TRIGGER IF EXISTS insights_prevent_vault_change;
        DROP TABLE IF EXISTS insight_references_v29_backup;
        CREATE TABLE insight_references_v29_backup AS
        SELECT insightId, resourceType, resourceId, referenceRole, createdAt
        FROM insight_references;
        CREATE TABLE insights_v29 (
            id BLOB PRIMARY KEY NOT NULL,
            vaultId BLOB NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            content TEXT NOT NULL,
            isAccepted BOOLEAN NOT NULL DEFAULT 0 CHECK (isAccepted IN (0, 1)),
            metadataJSON TEXT NOT NULL DEFAULT '{}',
            revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0),
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL,
            CHECK (LENGTH(TRIM(content)) > 0),
            CHECK (LENGTH(TRIM(metadataJSON)) > 0)
        );
        INSERT INTO insights_v29
            (id, vaultId, content, isAccepted, metadataJSON, revision, createdAt, updatedAt)
        SELECT id, vaultId, content, \(acceptedValue), metadataJSON, \(revisionValue), createdAt, updatedAt
        FROM insights;
        DROP TABLE insights;
        ALTER TABLE insights_v29 RENAME TO insights;
        CREATE INDEX insights_on_vaultId_createdAt_id
            ON insights(vaultId, createdAt DESC, id DESC);
        CREATE INDEX insights_on_vaultId_isAccepted_createdAt_id
            ON insights(vaultId, isAccepted, createdAt DESC, id DESC);
        CREATE TRIGGER insights_prevent_vault_change
        BEFORE UPDATE OF vaultId ON insights
        WHEN NEW.vaultId <> OLD.vaultId
        BEGIN
            SELECT RAISE(ABORT, 'insight vault is immutable');
        END;
        """)
        if referenceCount > 0 {
            try db.execute(sql: """
            INSERT OR IGNORE INTO insight_references
                (insightId, resourceType, resourceId, referenceRole, createdAt)
            SELECT insightId, resourceType, resourceId, referenceRole, createdAt
            FROM insight_references_v29_backup
            """)
        }
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM insight_references") == referenceCount else {
            throw DatabaseError(message: "insight rebuild did not preserve references")
        }
        try db.execute(sql: "DROP TABLE insight_references_v29_backup")
    }

    private static func removeRetiredSchema(in db: Database) throws {
        let triggerNames = [
            "conversation_topics_cleanup_proposal_evidence",
            "customer_intelligence_proposals_prevent_vault_change",
            "customer_intelligence_proposal_evidence_validate_insert",
            "customer_intelligence_proposal_evidence_validate_update",
            "customer_intelligence_proposal_dependencies_validate_insert",
            "organizations_cleanup_workspace_references",
            "contacts_cleanup_workspace_references",
            "projects_cleanup_workspace_references",
            "meetings_cleanup_workspace_references",
            "organizations_cleanup_resource_references",
            "contacts_cleanup_resource_references",
            "projects_cleanup_resource_references",
            "meetings_cleanup_resource_references",
        ]
        for name in triggerNames {
            try db.execute(sql: "DROP TRIGGER IF EXISTS \(name)")
        }
        try db.execute(sql: """
        DROP TABLE IF EXISTS customer_intelligence_mutation_import_chunks;
        DROP TABLE IF EXISTS customer_intelligence_mutation_imports;
        DROP TABLE IF EXISTS customer_intelligence_direct_mutations;
        DROP TABLE IF EXISTS customer_intelligence_proposal_dependencies;
        DROP TABLE IF EXISTS customer_intelligence_proposal_evidence;
        DROP TABLE IF EXISTS customer_intelligence_proposals;
        DROP TABLE IF EXISTS glossary_term_references;
        DROP TABLE IF EXISTS glossary_terms;
        """)
    }

    private static func recreateReferenceTriggers(in db: Database) throws {
        try db.execute(sql: """
        DROP TRIGGER IF EXISTS project_resource_references_validate_insert;
        DROP TRIGGER IF EXISTS project_resource_references_validate_update;
        DROP TRIGGER IF EXISTS insight_references_validate_insert;
        DROP TRIGGER IF EXISTS insight_references_validate_update;
        """)
        try createReferenceValidationTriggers(in: db)
        try createReferenceCleanupTriggers(in: db)
        try CustomerIntelligenceWorkspaceMigration.createWorkspaceCleanupTriggers(in: db)
    }

    // swiftlint:disable:next function_body_length
    private static func createReferenceValidationTriggers(in db: Database) throws {
        try db.execute(sql: """
        CREATE TRIGGER project_resource_references_validate_insert
        BEFORE INSERT ON project_resource_references
        BEGIN
            SELECT RAISE(ABORT, 'project resource does not exist in the project vault')
            WHERE (
                NEW.resourceType = 'organization'
                AND NOT EXISTS (
                    SELECT 1
                    FROM projects
                    JOIN organizations ON organizations.id = NEW.resourceId
                    WHERE projects.id = NEW.projectId
                      AND projects.vaultId = organizations.vaultId
                )
            ) OR (
                NEW.resourceType = 'contact'
                AND NOT EXISTS (
                    SELECT 1
                    FROM projects
                    JOIN contacts ON contacts.id = NEW.resourceId
                    WHERE projects.id = NEW.projectId
                      AND projects.vaultId = contacts.vaultId
                )
            );
        END;

        CREATE TRIGGER project_resource_references_validate_update
        BEFORE UPDATE OF projectId, resourceType, resourceId ON project_resource_references
        BEGIN
            SELECT RAISE(ABORT, 'project resource does not exist in the project vault')
            WHERE (
                NEW.resourceType = 'organization'
                AND NOT EXISTS (
                    SELECT 1
                    FROM projects
                    JOIN organizations ON organizations.id = NEW.resourceId
                    WHERE projects.id = NEW.projectId
                      AND projects.vaultId = organizations.vaultId
                )
            ) OR (
                NEW.resourceType = 'contact'
                AND NOT EXISTS (
                    SELECT 1
                    FROM projects
                    JOIN contacts ON contacts.id = NEW.resourceId
                    WHERE projects.id = NEW.projectId
                      AND projects.vaultId = contacts.vaultId
                )
            );
        END;

        CREATE TRIGGER insight_references_validate_insert
        BEFORE INSERT ON insight_references
        BEGIN
            SELECT RAISE(ABORT, 'insight resource does not exist in the insight vault')
            WHERE (
                NEW.resourceType = 'organization'
                AND NOT EXISTS (
                    SELECT 1 FROM insights
                    JOIN organizations ON organizations.id = NEW.resourceId
                    WHERE insights.id = NEW.insightId AND insights.vaultId = organizations.vaultId
                )
            ) OR (
                NEW.resourceType = 'contact'
                AND NOT EXISTS (
                    SELECT 1 FROM insights
                    JOIN contacts ON contacts.id = NEW.resourceId
                    WHERE insights.id = NEW.insightId AND insights.vaultId = contacts.vaultId
                )
            ) OR (
                NEW.resourceType = 'project'
                AND NOT EXISTS (
                    SELECT 1 FROM insights
                    JOIN projects ON projects.id = NEW.resourceId
                    WHERE insights.id = NEW.insightId AND insights.vaultId = projects.vaultId
                )
            ) OR (
                NEW.resourceType = 'meeting'
                AND NOT EXISTS (
                    SELECT 1 FROM insights
                    JOIN meetings ON meetings.id = NEW.resourceId
                    WHERE insights.id = NEW.insightId AND insights.vaultId = meetings.vaultId
                )
            );
        END;

        CREATE TRIGGER insight_references_validate_update
        BEFORE UPDATE OF insightId, resourceType, resourceId ON insight_references
        BEGIN
            SELECT RAISE(ABORT, 'insight resource does not exist in the insight vault')
            WHERE (
                NEW.resourceType = 'organization'
                AND NOT EXISTS (
                    SELECT 1 FROM insights
                    JOIN organizations ON organizations.id = NEW.resourceId
                    WHERE insights.id = NEW.insightId AND insights.vaultId = organizations.vaultId
                )
            ) OR (
                NEW.resourceType = 'contact'
                AND NOT EXISTS (
                    SELECT 1 FROM insights
                    JOIN contacts ON contacts.id = NEW.resourceId
                    WHERE insights.id = NEW.insightId AND insights.vaultId = contacts.vaultId
                )
            ) OR (
                NEW.resourceType = 'project'
                AND NOT EXISTS (
                    SELECT 1 FROM insights
                    JOIN projects ON projects.id = NEW.resourceId
                    WHERE insights.id = NEW.insightId AND insights.vaultId = projects.vaultId
                )
            ) OR (
                NEW.resourceType = 'meeting'
                AND NOT EXISTS (
                    SELECT 1 FROM insights
                    JOIN meetings ON meetings.id = NEW.resourceId
                    WHERE insights.id = NEW.insightId AND insights.vaultId = meetings.vaultId
                )
            );
        END;
        """)
    }

    private static func createReferenceCleanupTriggers(in db: Database) throws {
        try db.execute(sql: """
        CREATE TRIGGER organizations_cleanup_resource_references
        AFTER DELETE ON organizations
        BEGIN
            DELETE FROM project_resource_references
            WHERE resourceType = 'organization' AND resourceId = OLD.id;
            DELETE FROM insight_references
            WHERE resourceType = 'organization' AND resourceId = OLD.id;
        END;

        CREATE TRIGGER contacts_cleanup_resource_references
        AFTER DELETE ON contacts
        BEGIN
            DELETE FROM project_resource_references
            WHERE resourceType = 'contact' AND resourceId = OLD.id;
            DELETE FROM insight_references
            WHERE resourceType = 'contact' AND resourceId = OLD.id;
        END;
        """)

        if try db.tableExists("projects") {
            try db.execute(sql: """
            CREATE TRIGGER projects_cleanup_resource_references
            AFTER DELETE ON projects
            BEGIN
                DELETE FROM insight_references
                WHERE resourceType = 'project' AND resourceId = OLD.id;
            END;
            """)
        }

        if try db.tableExists("meetings") {
            try db.execute(sql: """
            CREATE TRIGGER meetings_cleanup_resource_references
            AFTER DELETE ON meetings
            BEGIN
                DELETE FROM insight_references
                WHERE resourceType = 'meeting' AND resourceId = OLD.id;
            END;
            """)
        }
    }
}
