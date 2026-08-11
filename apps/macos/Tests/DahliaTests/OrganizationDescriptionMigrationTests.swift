import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct OrganizationDescriptionMigrationTests {
        @Test
        func preservesExistingOrganizations() throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v29_customerIntelligenceDirectCRUD")
            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/organization-description-vault",
                name: "Vault",
                createdAt: .now,
                lastOpenedAt: .now
            )
            let organizationID = UUID.v7()
            try queue.write { db in
                try vault.insert(db)
                try db.execute(
                    sql: """
                    INSERT INTO organizations (
                        id, vaultId, parentOrganizationId, nodeKind, name, revision, createdAt, updatedAt
                    )
                    VALUES (?, ?, NULL, 'organization', 'Acme', 3, ?, ?)
                    """,
                    arguments: [organizationID, vault.id, Date.now, Date.now]
                )
            }

            try AppDatabaseManager.migrator.migrate(queue)

            let migrated = try queue.read { db in
                try OrganizationRecord.fetchOne(db, key: organizationID)
            }
            #expect(migrated?.name == "Acme")
            #expect(migrated?.description.isEmpty == true)
            #expect(migrated?.revision == 3)
        }
    }
#endif
