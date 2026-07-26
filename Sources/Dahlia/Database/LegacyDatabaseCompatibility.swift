import GRDB

/// Reconciles schemas produced by pre-release migration lines that shipped in older app builds.
///
/// The retired tables are archived in place so their rows remain recoverable, while the active
/// migration history is collapsed onto the current customer-intelligence migration.
enum LegacyDatabaseCompatibility {
    static let retiredMigrationIdentifiers = Set([
        "v8_projectSummaryInstruction",
        "v18_lakebaseSync",
        "v19_lakebaseMigrationConnection",
        "v19_meetingDescription",
        "v24_customerIntelligence",
        "v25_customerProjectContext",
        "v26_projectContextKind",
    ])

    private static let customerIntelligenceMigrationIdentifiers = Set([
        "v24_customerIntelligence",
        "v25_customerProjectContext",
        "v26_projectContextKind",
    ])

    private static let lakebaseMigrationIdentifiers = Set([
        "v18_lakebaseSync",
        "v19_lakebaseMigrationConnection",
    ])

    private static let migrationBeforeCustomerIntelligence = "v24_projectWorkspaceHierarchy"
    private static let currentCustomerIntelligenceMigration = "v25_customerIntelligence"
    private static let archivedTablePrefix = "legacy_retired_"

    private static let customerIntelligenceTableNames = Set([
        "external_entity_references",
        "glossary_term_aliases",
        "glossary_terms",
        "meeting_participants",
        "ontology_snippets",
        "organization_domains",
        "organization_unit_relationships",
        "organization_units",
        "organizations",
        "people",
        "person_emails",
        "person_organization_memberships",
        "person_relationships",
        "project_context_profiles",
        "project_customer_insights",
        "project_organization_links",
        "project_qualifications",
        "project_stakeholders",
        "snippet_entity_links",
        "snippet_evidence_links",
    ])

    static func reconcileIfNeeded(
        _ dbQueue: DatabaseQueue,
        canonicalMigrator: DatabaseMigrator
    ) throws {
        let appliedIdentifiers = try dbQueue.read {
            try canonicalMigrator.appliedIdentifiers($0)
        }
        let appliedRetiredIdentifiers = retiredMigrationIdentifiers.intersection(appliedIdentifiers)
        guard !appliedRetiredIdentifiers.isEmpty else {
            try detachArchivedTablesIfNeeded(in: dbQueue)
            return
        }

        if !appliedIdentifiers.contains(currentCustomerIntelligenceMigration) {
            try canonicalMigrator.migrate(dbQueue, upTo: migrationBeforeCustomerIntelligence)
        }

        try archiveRetiredTables(
            in: dbQueue,
            appliedRetiredIdentifiers: appliedRetiredIdentifiers
        )

        var compatibilityMigrator = DatabaseMigrator()
        compatibilityMigrator.eraseDatabaseOnSchemaChange = false
        compatibilityMigrator.registerMigration(
            currentCustomerIntelligenceMigration,
            merging: retiredMigrationIdentifiers
        ) { db, _ in
            try CustomerIntelligenceMigration.migrate(in: db)
        }
        try compatibilityMigrator.migrate(dbQueue)
    }

    static func isArchivedTable(_ tableName: String) -> Bool {
        tableName.hasPrefix(archivedTablePrefix)
    }

    private static func archiveCustomerIntelligenceTables(in db: Database) throws {
        for tableName in customerIntelligenceTableNames.sorted() where try db.tableExists(tableName) {
            try archiveTable(tableName, in: db)
        }
    }

    private static func archiveLakebaseTables(in db: Database) throws {
        let tableNames = try String.fetchAll(
            db,
            sql: """
            SELECT name
            FROM sqlite_master
            WHERE type = 'table' AND name LIKE 'lakebase\\_%' ESCAPE '\\'
            ORDER BY name
            """
        )
        for tableName in tableNames {
            try archiveTable(tableName, in: db)
        }
    }

    private static func archiveTable(_ tableName: String, in db: Database) throws {
        try db.rename(table: tableName, to: archivedTablePrefix + tableName)
    }

    private static func archiveRetiredTables(
        in dbQueue: DatabaseQueue,
        appliedRetiredIdentifiers: Set<String>
    ) throws {
        try writeWithForeignKeysDisabled(to: dbQueue) { db in
            try db.inTransaction {
                if !appliedRetiredIdentifiers.isDisjoint(with: customerIntelligenceMigrationIdentifiers) {
                    try archiveCustomerIntelligenceTables(in: db)
                }
                if !appliedRetiredIdentifiers.isDisjoint(with: lakebaseMigrationIdentifiers) {
                    try archiveLakebaseTables(in: db)
                }
                try detachArchivedTables(in: db)
                return .commit
            }
        }
    }

    /// Archived tables are inert snapshots. Removing their foreign keys prevents retired
    /// relationships from participating in cascades against the active schema.
    private static func detachArchivedTablesIfNeeded(in dbQueue: DatabaseQueue) throws {
        let hasForeignKeys = try dbQueue.read { db in
            let tableNames = try archivedTableNames(in: db)
            return try tableNames.contains { try !db.foreignKeys(on: $0).isEmpty }
        }
        guard hasForeignKeys else { return }

        try writeWithForeignKeysDisabled(to: dbQueue) { db in
            try db.inTransaction {
                try detachArchivedTables(in: db)
                return .commit
            }
        }
    }

    private static func detachArchivedTables(in db: Database) throws {
        for tableName in try archivedTableNames(in: db) {
            let detachedName = "detached_\(tableName)"
            try db.execute(
                sql: """
                CREATE TABLE \(detachedName.quotedDatabaseIdentifier)
                AS SELECT * FROM \(tableName.quotedDatabaseIdentifier)
                """
            )
            try db.drop(table: tableName)
            try db.rename(table: detachedName, to: tableName)
        }
    }

    private static func archivedTableNames(in db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
            SELECT name
            FROM sqlite_master
            WHERE type = 'table' AND name GLOB ?
            ORDER BY name
            """,
            arguments: [archivedTablePrefix + "*"]
        )
    }

    private static func writeWithForeignKeysDisabled(
        to dbQueue: DatabaseQueue,
        _ updates: (Database) throws -> Void
    ) throws {
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            do {
                try updates(db)
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            } catch {
                try db.execute(sql: "PRAGMA foreign_keys = ON")
                throw error
            }
        }
    }
}
