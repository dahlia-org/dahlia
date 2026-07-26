import GRDB

// The customer-intelligence tables and their polymorphic-reference safeguards form one atomic schema migration.
// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
enum CustomerIntelligenceMigration {
    static let maximumOrganizationDepth = 32

    static func migrate(in db: Database) throws {
        try createCanonicalTables(in: db)
        try createReferenceTables(in: db)
        try createIndexes(in: db)
        try createOrganizationTriggers(in: db)
        try createVaultImmutabilityTriggers(in: db)
        try createRelationshipValidationTriggers(in: db)
        try createReferenceValidationTriggers(in: db)
        try createReferenceCleanupTriggers(in: db)
    }

    // swiftlint:disable:next function_body_length
    private static func createCanonicalTables(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE contacts (
            id BLOB PRIMARY KEY NOT NULL,
            vaultId BLOB NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            email TEXT NOT NULL,
            displayName TEXT,
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL,
            UNIQUE(vaultId, email),
            CHECK (LENGTH(email) > 0),
            CHECK (displayName IS NULL OR LENGTH(TRIM(displayName)) > 0)
        );

        CREATE TABLE organizations (
            id BLOB PRIMARY KEY NOT NULL,
            vaultId BLOB NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            parentOrganizationId BLOB REFERENCES organizations(id),
            nodeKind TEXT NOT NULL CHECK (nodeKind IN ('organization', 'unit')),
            name TEXT NOT NULL,
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL,
            CHECK (LENGTH(TRIM(name)) > 0),
            CHECK (parentOrganizationId IS NULL OR parentOrganizationId <> id)
        );

        CREATE TABLE organization_domains (
            vaultId BLOB NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            domainName TEXT NOT NULL,
            organizationId BLOB NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
            isPrimary BOOLEAN NOT NULL DEFAULT 0 CHECK (isPrimary IN (0, 1)),
            firstObservedAt DATETIME NOT NULL,
            lastObservedAt DATETIME NOT NULL,
            PRIMARY KEY (vaultId, domainName),
            CHECK (LENGTH(domainName) > 0),
            CHECK (lastObservedAt >= firstObservedAt)
        );

        CREATE TABLE organization_memberships (
            organizationId BLOB NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
            contactId BLOB NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
            roleLabel TEXT,
            createdAt DATETIME NOT NULL,
            PRIMARY KEY (organizationId, contactId),
            CHECK (roleLabel IS NULL OR LENGTH(TRIM(roleLabel)) > 0)
        );

        CREATE TABLE meeting_participants (
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

        CREATE TABLE insights (
            id BLOB PRIMARY KEY NOT NULL,
            vaultId BLOB NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            content TEXT NOT NULL,
            reviewState TEXT NOT NULL CHECK (reviewState IN ('proposed', 'accepted', 'rejected')),
            metadataJSON TEXT NOT NULL DEFAULT '{}',
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL,
            CHECK (LENGTH(TRIM(content)) > 0),
            CHECK (LENGTH(TRIM(metadataJSON)) > 0)
        );

        CREATE TABLE glossary_terms (
            id BLOB PRIMARY KEY NOT NULL,
            vaultId BLOB NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            term TEXT NOT NULL,
            definition TEXT NOT NULL,
            aliasesJSON TEXT NOT NULL DEFAULT '[]',
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL,
            CHECK (LENGTH(TRIM(term)) > 0),
            CHECK (LENGTH(TRIM(definition)) > 0),
            CHECK (LENGTH(TRIM(aliasesJSON)) > 0)
        );
        """)
    }

    private static func createReferenceTables(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE project_resource_references (
            id BLOB PRIMARY KEY NOT NULL,
            projectId BLOB NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            resourceType TEXT NOT NULL CHECK (resourceType IN ('organization', 'contact')),
            resourceId BLOB NOT NULL,
            relationLabel TEXT NOT NULL DEFAULT '',
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL,
            UNIQUE(projectId, resourceType, resourceId, relationLabel)
        );

        CREATE TABLE insight_references (
            insightId BLOB NOT NULL REFERENCES insights(id) ON DELETE CASCADE,
            resourceType TEXT NOT NULL
                CHECK (resourceType IN ('organization', 'contact', 'project', 'meeting')),
            resourceId BLOB NOT NULL,
            referenceRole TEXT NOT NULL CHECK (referenceRole IN ('context', 'evidence', 'mentioned')),
            createdAt DATETIME NOT NULL,
            PRIMARY KEY (insightId, resourceType, resourceId, referenceRole)
        );

        CREATE TABLE glossary_term_references (
            glossaryTermId BLOB NOT NULL REFERENCES glossary_terms(id) ON DELETE CASCADE,
            resourceType TEXT NOT NULL
                CHECK (resourceType IN ('organization', 'contact', 'project', 'meeting')),
            resourceId BLOB NOT NULL,
            createdAt DATETIME NOT NULL,
            PRIMARY KEY (glossaryTermId, resourceType, resourceId)
        );
        """)
    }

    static func createIndexes(in db: Database) throws {
        try db.execute(sql: """
        CREATE INDEX contacts_on_vaultId_sortKey_id
            ON contacts(vaultId, COALESCE(displayName, email) COLLATE NOCASE, id);
        CREATE INDEX organizations_on_vaultId_parentOrganizationId_nodeKind
            ON organizations(vaultId, parentOrganizationId, nodeKind);
        CREATE INDEX organizations_on_vaultId_name_id
            ON organizations(vaultId, name COLLATE NOCASE, id);
        CREATE INDEX organization_domains_on_organizationId_domainName
            ON organization_domains(organizationId, domainName);
        CREATE UNIQUE INDEX organization_domains_one_primary
            ON organization_domains(organizationId)
            WHERE isPrimary = 1;
        CREATE INDEX organization_memberships_on_contactId_organizationId
            ON organization_memberships(contactId, organizationId);
        CREATE INDEX meeting_participants_on_contactId_meetingId
            ON meeting_participants(contactId, meetingId);
        CREATE INDEX project_resource_references_on_resourceType_resourceId_projectId
            ON project_resource_references(resourceType, resourceId, projectId);
        CREATE INDEX project_resource_references_on_projectId_createdAt_id
            ON project_resource_references(projectId, createdAt DESC, id DESC);
        CREATE INDEX project_resource_references_on_projectId_resourceType_createdAt_id
            ON project_resource_references(projectId, resourceType, createdAt DESC, id DESC);
        CREATE INDEX insights_on_vaultId_createdAt_id
            ON insights(vaultId, createdAt DESC, id DESC);
        CREATE INDEX insights_on_vaultId_reviewState_createdAt_id
            ON insights(vaultId, reviewState, createdAt DESC, id DESC);
        CREATE INDEX insight_references_on_resourceType_resourceId_insightId
            ON insight_references(resourceType, resourceId, insightId);
        CREATE INDEX glossary_terms_on_vaultId_term
            ON glossary_terms(vaultId, term COLLATE NOCASE, id);
        CREATE INDEX glossary_term_references_on_resourceType_resourceId_glossaryTermId
            ON glossary_term_references(resourceType, resourceId, glossaryTermId);
        """)
    }

    static func createVaultImmutabilityTriggers(in db: Database) throws {
        try db.execute(sql: """
        CREATE TRIGGER contacts_prevent_vault_change
        BEFORE UPDATE OF vaultId ON contacts
        WHEN NEW.vaultId <> OLD.vaultId
        BEGIN
            SELECT RAISE(ABORT, 'contact vault is immutable');
        END;

        CREATE TRIGGER insights_prevent_vault_change
        BEFORE UPDATE OF vaultId ON insights
        WHEN NEW.vaultId <> OLD.vaultId
        BEGIN
            SELECT RAISE(ABORT, 'insight vault is immutable');
        END;

        CREATE TRIGGER glossary_terms_prevent_vault_change
        BEFORE UPDATE OF vaultId ON glossary_terms
        WHEN NEW.vaultId <> OLD.vaultId
        BEGIN
            SELECT RAISE(ABORT, 'glossary term vault is immutable');
        END;
        """)

        if try db.tableExists("meetings") {
            try db.execute(sql: """
            CREATE TRIGGER meetings_prevent_vault_change
            BEFORE UPDATE OF vaultId ON meetings
            WHEN NEW.vaultId <> OLD.vaultId
            BEGIN
                SELECT RAISE(ABORT, 'meeting vault is immutable');
            END;
            """)
        }
    }

    // swiftlint:disable:next function_body_length
    static func createOrganizationTriggers(in db: Database) throws {
        try db.execute(sql: """
        CREATE TRIGGER organizations_validate_insert
        BEFORE INSERT ON organizations
        BEGIN
            SELECT RAISE(ABORT, 'organization root must have organization kind')
            WHERE NEW.parentOrganizationId IS NULL AND NEW.nodeKind <> 'organization';

            SELECT RAISE(ABORT, 'organization parent must exist in the same vault')
            WHERE NEW.parentOrganizationId IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1
                  FROM organizations AS parent
                  WHERE parent.id = NEW.parentOrganizationId
                    AND parent.vaultId = NEW.vaultId
              );

            SELECT RAISE(ABORT, 'an organization cannot be placed under a unit')
            WHERE NEW.nodeKind = 'organization'
              AND NEW.parentOrganizationId IS NOT NULL
              AND EXISTS (
                  SELECT 1
                  FROM organizations AS parent
                  WHERE parent.id = NEW.parentOrganizationId
                    AND parent.nodeKind <> 'organization'
              );

            WITH RECURSIVE ancestors(id, parentOrganizationId, depth) AS (
                SELECT id, parentOrganizationId, 1
                FROM organizations
                WHERE id = NEW.parentOrganizationId
                UNION ALL
                SELECT parent.id, parent.parentOrganizationId, ancestors.depth + 1
                FROM organizations AS parent
                JOIN ancestors ON parent.id = ancestors.parentOrganizationId
                WHERE ancestors.depth < 33
            )
            SELECT RAISE(ABORT, 'organization hierarchy exceeds maximum depth')
            WHERE COALESCE((SELECT MAX(depth) FROM ancestors), 0) > 32
               OR EXISTS (
                   SELECT 1
                   FROM ancestors
                   WHERE depth = 33 AND parentOrganizationId IS NOT NULL
               );
        END;

        CREATE TRIGGER organizations_validate_update
        BEFORE UPDATE OF vaultId, parentOrganizationId, nodeKind ON organizations
        BEGIN
            SELECT RAISE(ABORT, 'organization vault is immutable')
            WHERE NEW.vaultId <> OLD.vaultId;

            SELECT RAISE(ABORT, 'organization node kind is immutable')
            WHERE NEW.nodeKind <> OLD.nodeKind;

            SELECT RAISE(ABORT, 'organization root must have organization kind')
            WHERE NEW.parentOrganizationId IS NULL AND NEW.nodeKind <> 'organization';

            SELECT RAISE(ABORT, 'organization parent must exist in the same vault')
            WHERE NEW.parentOrganizationId IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1
                  FROM organizations AS parent
                  WHERE parent.id = NEW.parentOrganizationId
                    AND parent.vaultId = NEW.vaultId
              );

            SELECT RAISE(ABORT, 'an organization cannot be placed under a unit')
            WHERE NEW.nodeKind = 'organization'
              AND NEW.parentOrganizationId IS NOT NULL
              AND EXISTS (
                  SELECT 1
                  FROM organizations AS parent
                  WHERE parent.id = NEW.parentOrganizationId
                    AND parent.nodeKind <> 'organization'
              );

            WITH RECURSIVE descendants(id, depth) AS (
                SELECT OLD.id, 0
                UNION ALL
                SELECT child.id, descendants.depth + 1
                FROM organizations AS child
                JOIN descendants ON child.parentOrganizationId = descendants.id
                WHERE descendants.depth < 33
            )
            SELECT RAISE(ABORT, 'organization hierarchy cannot contain a cycle')
            WHERE NEW.parentOrganizationId IN (SELECT id FROM descendants);

            WITH RECURSIVE
            ancestors(id, parentOrganizationId, depth) AS (
                SELECT id, parentOrganizationId, 1
                FROM organizations
                WHERE id = NEW.parentOrganizationId
                UNION ALL
                SELECT parent.id, parent.parentOrganizationId, ancestors.depth + 1
                FROM organizations AS parent
                JOIN ancestors ON parent.id = ancestors.parentOrganizationId
                WHERE ancestors.depth < 33
            ),
            descendants(id, depth) AS (
                SELECT OLD.id, 0
                UNION ALL
                SELECT child.id, descendants.depth + 1
                FROM organizations AS child
                JOIN descendants ON child.parentOrganizationId = descendants.id
                WHERE descendants.depth < 33
            )
            SELECT RAISE(ABORT, 'organization hierarchy exceeds maximum depth')
            WHERE COALESCE((SELECT MAX(depth) FROM ancestors), 0)
                    + COALESCE((SELECT MAX(depth) FROM descendants), 0) > 32
               OR EXISTS (
                   SELECT 1
                   FROM ancestors
                   WHERE depth = 33 AND parentOrganizationId IS NOT NULL
               )
               OR EXISTS (
                   SELECT 1
                   FROM descendants AS boundary
                   WHERE boundary.depth = 33
                     AND EXISTS (
                         SELECT 1
                         FROM organizations AS child
                         WHERE child.parentOrganizationId = boundary.id
                     )
               );
        END;

        CREATE TRIGGER organization_domains_validate_insert
        BEFORE INSERT ON organization_domains
        BEGIN
            SELECT RAISE(ABORT, 'organization domain owner must be an organization in the same vault')
            WHERE NOT EXISTS (
                SELECT 1
                FROM organizations
                WHERE id = NEW.organizationId
                  AND vaultId = NEW.vaultId
                  AND nodeKind = 'organization'
            );
        END;

        CREATE TRIGGER organization_domains_validate_update
        BEFORE UPDATE OF vaultId, domainName, organizationId ON organization_domains
        BEGIN
            SELECT RAISE(ABORT, 'organization domain identity is immutable')
            WHERE NEW.vaultId <> OLD.vaultId
               OR NEW.domainName <> OLD.domainName
               OR NEW.organizationId <> OLD.organizationId;
        END;

        CREATE TRIGGER organization_domains_assign_first_primary
        AFTER INSERT ON organization_domains
        WHEN NOT EXISTS (
            SELECT 1
            FROM organization_domains
            WHERE organizationId = NEW.organizationId AND isPrimary = 1
        )
        BEGIN
            UPDATE organization_domains
            SET isPrimary = 1
            WHERE vaultId = NEW.vaultId AND domainName = NEW.domainName;
        END;

        CREATE TRIGGER organization_domains_promote_after_primary_delete
        AFTER DELETE ON organization_domains
        WHEN OLD.isPrimary = 1
        BEGIN
            UPDATE organization_domains
            SET isPrimary = 1
            WHERE rowid = (
                SELECT rowid
                FROM organization_domains
                WHERE organizationId = OLD.organizationId
                ORDER BY firstObservedAt ASC, domainName ASC
                LIMIT 1
            );
        END;
        """)
    }

    static func createRelationshipValidationTriggers(in db: Database) throws {
        try db.execute(sql: """
        CREATE TRIGGER organization_memberships_validate_insert
        BEFORE INSERT ON organization_memberships
        BEGIN
            SELECT RAISE(ABORT, 'organization membership must stay within one vault')
            WHERE NOT EXISTS (
                SELECT 1
                FROM organizations
                JOIN contacts ON contacts.id = NEW.contactId
                WHERE organizations.id = NEW.organizationId
                  AND organizations.vaultId = contacts.vaultId
            );
        END;

        CREATE TRIGGER organization_memberships_validate_update
        BEFORE UPDATE OF organizationId, contactId ON organization_memberships
        BEGIN
            SELECT RAISE(ABORT, 'organization membership must stay within one vault')
            WHERE NOT EXISTS (
                SELECT 1
                FROM organizations
                JOIN contacts ON contacts.id = NEW.contactId
                WHERE organizations.id = NEW.organizationId
                  AND organizations.vaultId = contacts.vaultId
            );
        END;

        CREATE TRIGGER meeting_participants_validate_insert
        BEFORE INSERT ON meeting_participants
        BEGIN
            SELECT RAISE(ABORT, 'meeting participant must stay within one vault')
            WHERE NOT EXISTS (
                SELECT 1
                FROM meetings
                JOIN contacts ON contacts.id = NEW.contactId
                WHERE meetings.id = NEW.meetingId
                  AND meetings.vaultId = contacts.vaultId
            );
        END;

        CREATE TRIGGER meeting_participants_validate_update
        BEFORE UPDATE OF meetingId, contactId ON meeting_participants
        BEGIN
            SELECT RAISE(ABORT, 'meeting participant must stay within one vault')
            WHERE NOT EXISTS (
                SELECT 1
                FROM meetings
                JOIN contacts ON contacts.id = NEW.contactId
                WHERE meetings.id = NEW.meetingId
                  AND meetings.vaultId = contacts.vaultId
            );
        END;
        """)
    }

    // swiftlint:disable:next function_body_length
    static func createReferenceValidationTriggers(in db: Database) throws {
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

        CREATE TRIGGER glossary_term_references_validate_insert
        BEFORE INSERT ON glossary_term_references
        BEGIN
            SELECT RAISE(ABORT, 'glossary resource does not exist in the glossary term vault')
            WHERE (
                NEW.resourceType = 'organization'
                AND NOT EXISTS (
                    SELECT 1 FROM glossary_terms
                    JOIN organizations ON organizations.id = NEW.resourceId
                    WHERE glossary_terms.id = NEW.glossaryTermId
                      AND glossary_terms.vaultId = organizations.vaultId
                )
            ) OR (
                NEW.resourceType = 'contact'
                AND NOT EXISTS (
                    SELECT 1 FROM glossary_terms
                    JOIN contacts ON contacts.id = NEW.resourceId
                    WHERE glossary_terms.id = NEW.glossaryTermId
                      AND glossary_terms.vaultId = contacts.vaultId
                )
            ) OR (
                NEW.resourceType = 'project'
                AND NOT EXISTS (
                    SELECT 1 FROM glossary_terms
                    JOIN projects ON projects.id = NEW.resourceId
                    WHERE glossary_terms.id = NEW.glossaryTermId
                      AND glossary_terms.vaultId = projects.vaultId
                )
            ) OR (
                NEW.resourceType = 'meeting'
                AND NOT EXISTS (
                    SELECT 1 FROM glossary_terms
                    JOIN meetings ON meetings.id = NEW.resourceId
                    WHERE glossary_terms.id = NEW.glossaryTermId
                      AND glossary_terms.vaultId = meetings.vaultId
                )
            );
        END;

        CREATE TRIGGER glossary_term_references_validate_update
        BEFORE UPDATE OF glossaryTermId, resourceType, resourceId ON glossary_term_references
        BEGIN
            SELECT RAISE(ABORT, 'glossary resource does not exist in the glossary term vault')
            WHERE (
                NEW.resourceType = 'organization'
                AND NOT EXISTS (
                    SELECT 1 FROM glossary_terms
                    JOIN organizations ON organizations.id = NEW.resourceId
                    WHERE glossary_terms.id = NEW.glossaryTermId
                      AND glossary_terms.vaultId = organizations.vaultId
                )
            ) OR (
                NEW.resourceType = 'contact'
                AND NOT EXISTS (
                    SELECT 1 FROM glossary_terms
                    JOIN contacts ON contacts.id = NEW.resourceId
                    WHERE glossary_terms.id = NEW.glossaryTermId
                      AND glossary_terms.vaultId = contacts.vaultId
                )
            ) OR (
                NEW.resourceType = 'project'
                AND NOT EXISTS (
                    SELECT 1 FROM glossary_terms
                    JOIN projects ON projects.id = NEW.resourceId
                    WHERE glossary_terms.id = NEW.glossaryTermId
                      AND glossary_terms.vaultId = projects.vaultId
                )
            ) OR (
                NEW.resourceType = 'meeting'
                AND NOT EXISTS (
                    SELECT 1 FROM glossary_terms
                    JOIN meetings ON meetings.id = NEW.resourceId
                    WHERE glossary_terms.id = NEW.glossaryTermId
                      AND glossary_terms.vaultId = meetings.vaultId
                )
            );
        END;
        """)
    }

    static func createReferenceCleanupTriggers(in db: Database) throws {
        try db.execute(sql: """
        CREATE TRIGGER organizations_cleanup_resource_references
        AFTER DELETE ON organizations
        BEGIN
            DELETE FROM project_resource_references
            WHERE resourceType = 'organization' AND resourceId = OLD.id;
            DELETE FROM insight_references
            WHERE resourceType = 'organization' AND resourceId = OLD.id;
            DELETE FROM glossary_term_references
            WHERE resourceType = 'organization' AND resourceId = OLD.id;
        END;

        CREATE TRIGGER contacts_cleanup_resource_references
        AFTER DELETE ON contacts
        BEGIN
            DELETE FROM project_resource_references
            WHERE resourceType = 'contact' AND resourceId = OLD.id;
            DELETE FROM insight_references
            WHERE resourceType = 'contact' AND resourceId = OLD.id;
            DELETE FROM glossary_term_references
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
                DELETE FROM glossary_term_references
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
                DELETE FROM glossary_term_references
                WHERE resourceType = 'meeting' AND resourceId = OLD.id;
            END;
            """)
        }
    }
}
