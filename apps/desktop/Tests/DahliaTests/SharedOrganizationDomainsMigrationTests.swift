import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct SharedOrganizationDomainsMigrationTests {
        @Test
        // swiftlint:disable:next function_body_length
        func preservesExistingRowsAndAllowsSharedDomains() throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v32_transcriptAudioFeatures")
            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/shared-organization-domains-vault",
                name: "Vault",
                createdAt: .now,
                lastOpenedAt: .now
            )
            let firstOrganizationID = UUID.v7()
            let secondOrganizationID = UUID.v7()
            let firstObservedAt = Date(timeIntervalSince1970: 1_700_000_000)
            let lastObservedAt = firstObservedAt.addingTimeInterval(600)
            try queue.write { db in
                try insertLegacyVault(vault, in: db)
                try insertRootOrganization(firstOrganizationID, vaultID: vault.id, in: db)
                try insertRootOrganization(secondOrganizationID, vaultID: vault.id, in: db)
                try db.execute(
                    sql: """
                    INSERT INTO organization_domains (
                        vaultId, domainName, organizationId, isPrimary, firstObservedAt, lastObservedAt
                    )
                    VALUES (?, 'alpha.example', ?, 1, ?, ?),
                           (?, 'shared.example', ?, 0, ?, ?)
                    """,
                    arguments: [
                        vault.id, firstOrganizationID, firstObservedAt, lastObservedAt,
                        vault.id, firstOrganizationID, firstObservedAt, lastObservedAt,
                    ]
                )
            }

            try AppDatabaseManager.migrator.migrate(queue)

            try queue.write { db in
                let preservedRecord = try OrganizationDomainRecord
                    .filter(
                        Column("vaultId") == vault.id
                            && Column("domainName") == "shared.example"
                            && Column("organizationId") == firstOrganizationID
                    )
                    .fetchOne(db)
                let preserved = try #require(preservedRecord)
                #expect(preserved.isPrimary == false)
                #expect(preserved.firstObservedAt == firstObservedAt)
                #expect(preserved.lastObservedAt == lastObservedAt)

                try db.execute(
                    sql: """
                    INSERT INTO organization_domains (
                        vaultId, domainName, organizationId, isPrimary, firstObservedAt, lastObservedAt
                    )
                    VALUES (?, 'shared.example', ?, 0, ?, ?)
                    """,
                    arguments: [vault.id, secondOrganizationID, firstObservedAt, lastObservedAt]
                )

                let shared = try OrganizationDomainRecord
                    .filter(Column("vaultId") == vault.id && Column("domainName") == "shared.example")
                    .fetchAll(db)
                #expect(shared.count == 2)
                #expect(shared.first { $0.organizationId == firstOrganizationID }?.isPrimary == false)
                #expect(shared.first { $0.organizationId == secondOrganizationID }?.isPrimary == true)

                #expect(throws: DatabaseError.self) {
                    try db.execute(
                        sql: """
                        INSERT INTO organization_domains (
                            vaultId, domainName, organizationId, isPrimary, firstObservedAt, lastObservedAt
                        )
                        VALUES (?, 'shared.example', ?, 0, ?, ?)
                        """,
                        arguments: [vault.id, secondOrganizationID, firstObservedAt, lastObservedAt]
                    )
                }
                #expect(throws: DatabaseError.self) {
                    try db.execute(
                        sql: """
                        INSERT INTO organization_domains (
                            vaultId, domainName, organizationId, isPrimary, firstObservedAt, lastObservedAt
                        )
                        VALUES (?, 'second.example', ?, 1, ?, ?)
                        """,
                        arguments: [vault.id, secondOrganizationID, firstObservedAt, lastObservedAt]
                    )
                }
            }
        }

        @Test
        func appliesAllMigrationsToEmptyDatabase() throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue)
            let applied = try queue.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"
                )
            }
            #expect(applied == "v45_screenshotContent")
        }

        private func insertRootOrganization(
            _ id: UUID,
            vaultID: UUID,
            in db: Database
        ) throws {
            try db.execute(
                sql: """
                INSERT INTO organizations (
                    id, vaultId, parentOrganizationId, nodeKind, name, description, revision, createdAt, updatedAt
                )
                VALUES (?, ?, NULL, 'organization', ?, '', 1, ?, ?)
                """,
                arguments: [id, vaultID, id.uuidString, Date.now, Date.now]
            )
        }
    }
#endif
