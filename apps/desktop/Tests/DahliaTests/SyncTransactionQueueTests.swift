#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct SyncTransactionQueueTests {
        @Test
        func operationBodyEncodesAbsentValuesAsExplicitNull() throws {
            let body = SyncOperationBody(
                id: .v7(),
                entity: .vault,
                action: .create,
                entityId: .v7(),
                baseRevision: nil,
                data: nil
            )

            let encoded = try SyncJSON.encoder.encode(body)
            let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

            #expect(object.keys.contains("baseRevision"))
            #expect(object["baseRevision"] is NSNull)
            #expect(object.keys.contains("data"))
            #expect(object["data"] is NSNull)
        }

        @Test
        func canonicalProjectUpdateInvalidatesOpenEditsForItsHierarchy() async throws {
            let (database, vault) = try await syncedDatabase()
            let root = ProjectRecord(
                id: .v7(), vaultId: vault.id, parentProjectId: nil,
                name: "Root", createdAt: .now, projectType: .undefined
            )
            let child = ProjectRecord(
                id: .v7(), vaultId: vault.id, parentProjectId: root.id,
                name: "Child", createdAt: .now, projectType: nil
            )
            let canonical = try SyncJSON.decoder.decode(
                SyncCanonicalPayload.self,
                from: Data(
                    "{\"name\":\"Renamed\",\"description\":\"Remote\",\"projectType\":\"undefined\",\"createdAt\":\"2026-09-03T00:00:00.000Z\"}"
                        .utf8
                )
            )
            try await database.dbQueue.write { db in
                try root.insert(db)
                try child.insert(db)
                try SyncTransactionQueue.applyCanonical(
                    .project,
                    id: root.id,
                    vaultId: vault.id,
                    value: canonical,
                    in: db
                )
            }

            let revisions = try await database.dbQueue.read { db in
                try (
                    ProjectRecord.fetchOne(db, key: root.id)?.revision,
                    ProjectRecord.fetchOne(db, key: child.id)?.revision
                )
            }
            #expect(revisions.0 == 2)
            #expect(revisions.1 == 2)
        }

        @Test
        func retryingAValidationBlockPreservesTheImmutableTransaction() async throws {
            let (database, vault) = try await syncedDatabase()
            let payload = try SyncJSON.encoder.encode(JSONValue.object(["name": .string("Queued")]))
            let operationId = UUID.v7()
            _ = try await database.dbQueue.write { db in
                try SyncTransactionRecorder.record(
                    vaultId: vault.id,
                    operations: [SyncOperationDraft(
                        id: operationId,
                        entity: .vault,
                        action: .update,
                        entityId: vault.id,
                        payloadJSON: payload
                    )],
                    in: db
                )
            }
            let firstClaim = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            try await SyncTransactionQueue.block(
                firstClaim,
                reason: .validation,
                response: Data(#"{"error":"invalid_sync_transaction"}"#.utf8),
                dbQueue: database.dbQueue
            )

            try await SyncTransactionQueue.retryInvalidTransaction(vaultId: vault.id, dbQueue: database.dbQueue)

            let retried = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            #expect(retried.id == firstClaim.id)
            #expect(retried.operations.first?.id == operationId)
            #expect(retried.operations.first?.payloadJSON == payload)
        }

        @Test
        func interruptedInitialSnapshotRepairsOnlyAnUnconfirmedOwnerVault() async throws {
            let (database, vault) = try await syncedDatabase()

            try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: database.dbQueue)

            let ownerState: (UUID?, Row?) = try database.dbQueue.read { db in
                let savedVault = try VaultRecord.fetchOne(db, key: vault.id)
                let operation = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT o.entity, o.action FROM sync_operations o
                    JOIN sync_transactions t ON t.id = o.transactionId
                    WHERE t.vaultId = ? ORDER BY t.sequence, o.position LIMIT 1
                    """,
                    arguments: [vault.id]
                )
                return (savedVault?.syncConfirmedConnectionId, operation)
            }
            #expect(ownerState.0 == vault.accountConnectionId)
            #expect(ownerState.1?["entity"] as String? == "vault")
            #expect(ownerState.1?["action"] as String? == "create")

            let memberVaultId = UUID.v7()
            try await database.dbQueue.write { db in
                var member = VaultRecord(
                    id: memberVaultId,
                    path: "/tmp/member",
                    name: "Member",
                    createdAt: .now,
                    lastOpenedAt: .now
                )
                member.accountConnectionId = vault.accountConnectionId
                member.syncConfirmedConnectionId = vault.accountConnectionId
                member.syncRole = "member"
                try member.insert(db)
            }

            try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: database.dbQueue)

            let memberState: (UUID?, Int?) = try await database.dbQueue.read { db in
                let savedVault = try VaultRecord.fetchOne(db, key: memberVaultId)
                let transactionCount = try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM sync_transactions WHERE vaultId = ?",
                    arguments: [memberVaultId]
                )
                return (savedVault?.syncConfirmedConnectionId, transactionCount)
            }
            #expect(memberState.0 == vault.accountConnectionId)
            #expect(memberState.1 == 0)
        }

        @Test
        func initialSnapshotRepairLeavesAnExistingOwnerTransactionUntouched() async throws {
            let (database, vault) = try await syncedDatabase()
            _ = try await database.dbQueue.write { db in
                try SyncTransactionRecorder.record(
                    vaultId: vault.id,
                    operations: [SyncOperationDraft(entity: .vault, action: .update, entityId: vault.id)],
                    in: db
                )
            }

            try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: database.dbQueue)

            let operations = try await database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT o.action FROM sync_operations o
                    JOIN sync_transactions t ON t.id = o.transactionId
                    WHERE t.vaultId = ? ORDER BY t.sequence, o.position
                    """,
                    arguments: [vault.id]
                ).map { $0["action"] as String }
            }
            #expect(operations == ["update"])
        }

        @Test
        func nonConflictBlocksCannotDiscardDurableTransactions() async throws {
            let (database, vault) = try await syncedDatabase()
            _ = try await database.dbQueue.write { db in
                try SyncTransactionRecorder.record(
                    vaultId: vault.id,
                    operations: [SyncOperationDraft(entity: .vault, action: .update, entityId: vault.id)],
                    in: db
                )
            }
            let claimed = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            try await SyncTransactionQueue.block(
                claimed,
                reason: .validation,
                response: Data("{}".utf8),
                dbQueue: database.dbQueue
            )

            try await SyncTransactionQueue.acceptServerVersion(vaultId: vault.id, dbQueue: database.dbQueue)
            try await SyncTransactionQueue.reapplyLocalVersion(vaultId: vault.id, dbQueue: database.dbQueue)

            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions WHERE vaultId = ?", arguments: [vault.id])
            } == 1)

            try await SyncTransactionQueue.discardInvalidTransaction(vaultId: vault.id, dbQueue: database.dbQueue)
            let replacement = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            #expect(replacement.vaultId == vault.id)
            #expect(replacement.operations.count == 1)
            #expect(replacement.operations.first?.entity == .vault)
            #expect(replacement.operations.first?.action == .create)
        }

        @Test
        func authorizationBlocksCanRetryAfterReauthentication() async throws {
            let (database, vault) = try await syncedDatabase()
            _ = try await database.dbQueue.write { db in
                try SyncTransactionRecorder.record(
                    vaultId: vault.id,
                    operations: [SyncOperationDraft(entity: .vault, action: .update, entityId: vault.id)],
                    in: db
                )
            }
            let firstClaim = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            try await SyncTransactionQueue.block(
                firstClaim,
                reason: .authorization,
                response: Data("{}".utf8),
                dbQueue: database.dbQueue
            )

            try await SyncTransactionQueue.retryAuthorizationBlocks(
                connectionId: firstClaim.connectionId,
                dbQueue: database.dbQueue
            )

            let retried = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            #expect(retried.id == firstClaim.id)
        }

        @Test
        func restoreResetKeepsTheConfirmedVaultRevisionInItsImmutableOperation() async throws {
            let (database, vault) = try await syncedDatabase()
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision) VALUES (?, 'vault', ?, 4)",
                    arguments: [vault.id, vault.id]
                )
            }

            try await SyncInitialSnapshotBuilder.prepareRestore(dbQueue: database.dbQueue)
            try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: database.dbQueue)

            let state = try await database.dbQueue.read { db in
                try (
                    Int.fetchOne(
                        db,
                        sql: "SELECT baseRevision FROM sync_operations WHERE entity = 'vault' AND action = 'reset'"
                    ),
                    Int.fetchOne(db, sql: "SELECT count(*) FROM sync_entity_state WHERE vaultId = ?", arguments: [vault.id])
                )
            }
            #expect(state.0 == 4)
            #expect(state.1 == 0)
        }

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
