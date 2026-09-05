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

        @Test(arguments: [false, true])
        func acceptingServerVersionForcesCanonicalReconciliation(hasConfirmedVault: Bool) async throws {
            let (database, vault) = try await syncedDatabase()
            try await database.dbQueue.write { db in
                if hasConfirmedVault {
                    try db.execute(
                        sql: "INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision) VALUES (?, 'vault', ?, 3)",
                        arguments: [vault.id, vault.id]
                    )
                }
                var edited = vault
                edited.name = "Rejected local name"
                try edited.update(db)
                try SyncTransactionRecorder.record(
                    vaultId: vault.id,
                    operations: [SyncInitialSnapshotBuilder.vaultOperation(edited, action: hasConfirmedVault ? .update : .create)],
                    in: db
                )
            }
            let claimed = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            try await SyncTransactionQueue.block(
                claimed,
                reason: .conflict,
                response: Data("""
                {"conflicts":[{"entity":"vault","id":"\(vault.id.uuidString)","serverRevision":4}]}
                """.utf8),
                dbQueue: database.dbQueue
            )

            try await SyncTransactionQueue.acceptServerVersion(vaultId: vault.id, dbQueue: database.dbQueue)

            let state = try await database.dbQueue.read { db in
                try (
                    Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions WHERE vaultId = ?", arguments: [vault.id]),
                    Int.fetchOne(db, sql: "SELECT count(*) FROM sync_entity_state WHERE vaultId = ?", arguments: [vault.id]),
                    VaultRecord.fetchOne(db, key: vault.id)?.syncPullCursor
                )
            }
            #expect(state.0 == 0)
            #expect(state.1 == 1)
            #expect(state.2 == nil)
            try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: database.dbQueue)
            #expect(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue) == nil)
            #expect(try await database.dbQueue.read { db in
                try VaultRecord.fetchOne(db, key: vault.id)?.syncConfirmedConnectionId
            } == vault.syncConfirmedConnectionId)

            let canonical = try SyncJSON.decoder.decode(
                SyncCanonicalPayload.self,
                from: Data("{\"name\":\"Server name\"}".utf8)
            )
            let changes: [SyncChangePage.Change] = [
                .init(sequence: 4, entity: .vault, entityId: vault.id, action: "upsert", revision: 4, record: canonical),
            ]
            #expect(try await RemoteChangeApplier.apply(
                changes, screenshots: [:], transcripts: [:], cursor: nil,
                vaultId: vault.id, expectedConnectionId: #require(vault.syncConfirmedConnectionId),
                dbQueue: database.dbQueue
            ))
            #expect(try await RemoteChangeApplier.finishReset(
                SyncResetSnapshot(canonicalChanges: changes), cursor: "server-cursor",
                vaultId: vault.id, expectedConnectionId: #require(vault.syncConfirmedConnectionId),
                dbQueue: database.dbQueue
            ))
            try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: database.dbQueue)
            #expect(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue) == nil)
            #expect(try await database.dbQueue.read { db in
                try VaultRecord.fetchOne(db, key: vault.id)?.name
            } == "Server name")
        }

        @Test
        func reconciliationRebasesDurableEditsBeforeTheyCanBeClaimed() async throws {
            let (database, vault) = try await syncedDatabase()
            let connectionId = try #require(vault.syncConfirmedConnectionId)
            try await database.dbQueue.write { db in
                try SyncTransactionRecorder.record(
                    vaultId: vault.id,
                    operations: [SyncInitialSnapshotBuilder.vaultOperation(vault, action: .update)], in: db
                )
            }
            let rejected = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            try await SyncTransactionQueue.block(rejected, reason: .conflict, response: Data("{}".utf8), dbQueue: database.dbQueue)
            try await SyncTransactionQueue.acceptServerVersion(vaultId: vault.id, dbQueue: database.dbQueue)

            let meetingId = UUID.v7()
            let patch = SyncOperationDraft(entity: .transcript, action: .patch, entityId: meetingId)
            let segment = SyncTranscriptPatchSegment(TranscriptSegmentRecord(
                id: .v7(), meetingId: meetingId, sessionId: nil, startTime: .now, endTime: nil,
                text: "Finalized during reconciliation", translatedText: nil, isConfirmed: true,
                audioSource: "mic", speakerLabel: nil, audioFeatureVersion: nil,
                audioActiveRmsDecibels: nil, audioMedianPitchHertz: nil,
                audioVoicedFrameRatio: nil, audioPitchSpreadHertz: nil
            ))
            try await database.dbQueue.write { db in
                for name in ["First edit", "Second edit"] {
                    var edited = vault
                    edited.name = name
                    try edited.update(db)
                    try SyncTransactionRecorder.record(
                        vaultId: vault.id,
                        operations: [SyncInitialSnapshotBuilder.vaultOperation(edited, action: .update)], in: db
                    )
                }
                try SyncTransactionRecorder.record(
                    vaultId: vault.id, operations: [patch], transcriptSegments: [patch.id: [segment]], in: db
                )
            }
            #expect(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue) == nil)
            await #expect(throws: SyncTransactionQueueError.self) {
                try await SyncTransactionQueue.reconcileRevisions(
                    [], vaultId: vault.id, connectionId: connectionId, dbQueue: database.dbQueue
                )
            }
            #expect(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue) == nil)

            let canonical = try SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: Data("{\"name\":\"Server\"}".utf8))
            let changes: [SyncChangePage.Change] = [
                .init(sequence: 1, entity: .vault, entityId: vault.id, action: "upsert", revision: 8, record: canonical),
                .init(sequence: 2, entity: .transcript, entityId: meetingId, action: "upsert", revision: 4, record: nil),
            ]
            try await SyncTransactionQueue.reconcileRevisions(
                changes, vaultId: vault.id, connectionId: connectionId, dbQueue: database.dbQueue
            )
            let revisions = try await database.dbQueue.read { db in
                try Int.fetchAll(db, sql: """
                SELECT o.baseRevision FROM sync_operations o JOIN sync_transactions t ON t.id = o.transactionId
                WHERE t.vaultId = ? ORDER BY t.sequence, o.position
                """, arguments: [vault.id])
            }
            #expect(revisions == [8, 9, 4])
            #expect(try await SyncTransactionQueue.transcriptPatch(operationId: patch.id, dbQueue: database.dbQueue).segments.first?.text == segment.text)
            #expect(try await database.dbQueue.read { db in
                try VaultRecord.fetchOne(db, key: vault.id)?.name
            } == "Second edit")
            let first = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            #expect(first.operations.first?.baseRevision == 8)
            // A pre-upgrade retry must retain its wire body even if a revision marker remains.
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE sync_entity_state SET confirmedRevision = NULL WHERE vaultId = ? AND entity = 'vault'",
                    arguments: [vault.id]
                )
            }
            try await SyncTransactionQueue.reconcileRevisions(
                [.init(sequence: 3, entity: .vault, entityId: vault.id, action: "upsert", revision: 20, record: canonical)],
                vaultId: vault.id, connectionId: connectionId, dbQueue: database.dbQueue
            )
            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT baseRevision FROM sync_operations WHERE transactionId = ?", arguments: [first.id])
            } == 8)
        }

        @Test
        func transcriptChunkEncodesRequiredNullableFields() throws {
            for hasValues in [false, true] {
                let segment = TranscriptChunkBody.Segment(
                    segmentId: .v7(), startTime: Date(timeIntervalSince1970: 0),
                    endTime: hasValues ? Date(timeIntervalSince1970: 1) : nil,
                    text: "Confirmed", isConfirmed: true,
                    audioSource: hasValues ? "mic" : nil,
                    speakerLabel: hasValues ? "Speaker" : nil
                )
                let data = try SyncJSON.encoder.encode(TranscriptChunkBody(segments: [segment], deletions: []))
                let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let segments = try #require(object["segments"] as? [[String: Any]])
                let encoded = try #require(segments.first)
                for key in ["endTime", "audioSource", "speakerLabel"] {
                    let value = try #require(encoded[key])
                    #expect((value is NSNull) == !hasValues)
                }
                let decoded = try SyncJSON.decoder.decode(TranscriptChunkBody.self, from: data)
                #expect(decoded.segments.first?.speakerLabel == segment.speakerLabel)
                #expect(decoded.segments.first?.audioSource == segment.audioSource)
                #expect(decoded.segments.first?.endTime == segment.endTime)
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
