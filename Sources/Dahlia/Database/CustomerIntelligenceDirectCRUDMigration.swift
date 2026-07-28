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
        let acceptedValue = columns.contains("isAccepted")
            ? "isAccepted"
            : "CASE WHEN reviewState = 'accepted' THEN 1 ELSE 0 END"
        let revisionValue = columns.contains("revision") ? "revision" : "1"

        try db.execute(sql: """
        DROP TRIGGER IF EXISTS insights_prevent_vault_change;
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
        try CustomerIntelligenceMigration.createReferenceValidationTriggers(in: db)
        try CustomerIntelligenceMigration.createReferenceCleanupTriggers(in: db)
        try CustomerIntelligenceWorkspaceMigration.createWorkspaceCleanupTriggers(in: db)
    }
}
