import GRDB

enum SharedOrganizationDomainsMigration {
    // swiftlint:disable:next function_body_length
    static func migrate(in db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE organization_domains RENAME TO organization_domains_v31;

        CREATE TABLE organization_domains (
            vaultId BLOB NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            domainName TEXT NOT NULL,
            organizationId BLOB NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
            isPrimary BOOLEAN NOT NULL DEFAULT 0 CHECK (isPrimary IN (0, 1)),
            firstObservedAt DATETIME NOT NULL,
            lastObservedAt DATETIME NOT NULL,
            PRIMARY KEY (vaultId, domainName, organizationId),
            CHECK (LENGTH(domainName) > 0),
            CHECK (lastObservedAt >= firstObservedAt)
        );

        INSERT INTO organization_domains (
            vaultId,
            domainName,
            organizationId,
            isPrimary,
            firstObservedAt,
            lastObservedAt
        )
        SELECT
            vaultId,
            domainName,
            organizationId,
            isPrimary,
            firstObservedAt,
            lastObservedAt
        FROM organization_domains_v31;

        DROP TABLE organization_domains_v31;

        CREATE INDEX organization_domains_on_organizationId_domainName
            ON organization_domains(organizationId, domainName);
        CREATE UNIQUE INDEX organization_domains_one_primary
            ON organization_domains(organizationId)
            WHERE isPrimary = 1;

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
            WHERE vaultId = NEW.vaultId
              AND domainName = NEW.domainName
              AND organizationId = NEW.organizationId;
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
        """)
    }
}
