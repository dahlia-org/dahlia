#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct SyncTransactionQueueTests {
        @Test
        func ignoresReceiptThatReturnsAfterVaultMovesToLocalAccount() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://server.example.com", clientID: "desktop-client", createdAt: .now
            )
            var vault = VaultRecord(id: .v7(), path: "/tmp/sync", name: "Sync", createdAt: .now, lastOpenedAt: .now)
            vault.accountConnectionId = connection.id
            vault.syncConfirmedConnectionId = connection.id
            let savedVault = vault
            try await database.dbQueue.write { db in
                try connection.insert(db)
                try savedVault.insert(db)
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision) VALUES (?, 'vault', ?, 3)",
                    arguments: [savedVault.id, savedVault.id]
                )
            }
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            _ = try await repository.updateVaultName(id: savedVault.id, name: "Sent name")
            let claimed = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))

            try await repository.resolveVaultsForSignOut(connectionID: connection.id, disposition: .moveToLocalAccount)
            _ = try await repository.updateVaultName(id: savedVault.id, name: "Local after sign out")
            try await SyncTransactionQueue.complete(
                claimed,
                response: SyncTransactionResponse(
                    id: claimed.id,
                    status: "committed",
                    cursor: "late-cursor",
                    records: [.init(
                        entity: .vault,
                        id: savedVault.id,
                        revision: 4,
                        record: .object(["name": .string("Late canonical name")])
                    )]
                ),
                dbQueue: database.dbQueue
            )

            let state = try await database.dbQueue.read { db in
                try (
                    VaultRecord.fetchOne(db, key: savedVault.id),
                    Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions WHERE vaultId = ?", arguments: [savedVault.id]),
                    Int.fetchOne(db, sql: "SELECT count(*) FROM sync_entity_state WHERE vaultId = ?", arguments: [savedVault.id])
                )
            }
            #expect(state.0?.name == "Local after sign out")
            #expect(state.0?.accountConnectionId == nil)
            #expect(state.0?.syncLastCommittedCursor == nil)
            #expect(state.1 == 0)
            #expect(state.2 == 0)
        }
    }
#endif
