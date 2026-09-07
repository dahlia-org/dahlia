#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct AccountSyncStateTests {
        @Test
        func accountSyncStateAggregatesVaultsAndRecoversWithoutCrossingAccounts() async throws {
            let (database, vault) = try await syncedDatabase()
            try await database.dbQueue.write { db in
                let connectionID = try #require(vault.accountConnectionId)
                #expect(try MeetingRepository.fetchAccountSyncStates(in: db)[connectionID] == .pending)
                try db.execute(sql: "UPDATE vaults SET syncPullCursor = 'cursor' WHERE id = ?", arguments: [vault.id])
                #expect(try MeetingRepository.fetchAccountSyncStates(in: db)[connectionID] == .synced)

                let recordedTransactionID = try SyncTransactionRecorder.record(
                    vaultId: vault.id,
                    operations: [SyncOperationDraft(entity: .vault, action: .update, entityId: vault.id)],
                    in: db
                )
                let transactionID = try #require(recordedTransactionID)
                #expect(try MeetingRepository.fetchAccountSyncStates(in: db)[connectionID] == .pending)
                for reason in ["validation", "conflict", "authorization"] {
                    try db.execute(sql: "UPDATE sync_transactions SET blockedReason = ? WHERE id = ?", arguments: [reason, transactionID])
                    #expect(try MeetingRepository
                        .fetchAccountSyncStates(in: db)[connectionID] == .blocked(#require(SyncBlockedReason(rawValue: reason))))
                }
                try db.execute(sql: "DELETE FROM sync_transactions WHERE id = ?", arguments: [transactionID])
                #expect(try MeetingRepository.fetchAccountSyncStates(in: db)[connectionID] == .synced)

                var sibling = vault
                sibling.id = .v7()
                sibling.path = nil
                sibling.syncRecoveryState = "recovering"
                try sibling.insert(db)
                #expect(try MeetingRepository.fetchAccountSyncStates(in: db)[connectionID] == .recovering)
                try db.execute(sql: "UPDATE vaults SET syncRecoveryState = 'updateRequired' WHERE id = ?", arguments: [sibling.id])
                #expect(try MeetingRepository.fetchAccountSyncStates(in: db)[connectionID] == .updateRequired)

                let other = DahliaAccountConnectionRecord(
                    id: .v7(), origin: "https://other.example.com", clientID: "desktop-client", createdAt: .now
                )
                try other.insert(db)
                sibling.accountConnectionId = other.id
                sibling.syncConfirmedConnectionId = other.id
                sibling.syncPullCursor = "cursor"
                try sibling.update(db)
                try db.execute(sql: "UPDATE vaults SET syncRecoveryState = 'recovering' WHERE id = ?", arguments: [sibling.id])
                let states = try MeetingRepository.fetchAccountSyncStates(in: db)
                #expect(states[connectionID] == .synced)
                #expect(states[other.id] == .recovering)
                try sibling.delete(db)
                #expect(try MeetingRepository.fetchAccountSyncStates(in: db)[other.id] == nil)
            }
        }

        private func syncedDatabase() async throws -> (AppDatabaseManager, VaultRecord) {
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
            }
            return (database, savedVault)
        }
    }
#endif
