#if canImport(Testing)
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    struct DocumentPersistenceTests {
        private func seed(server: Bool = false) throws -> (DatabaseQueue, UUID, UUID) {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let workspaceID = UUID.v7(), meetingID = UUID.v7()
            try queue.write { db throws in
                var workspace = WorkspaceRecord(id: workspaceID, name: "Notes", createdAt: .now, lastOpenedAt: .now)
                if server {
                    let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://example.invalid", clientID: "test", createdAt: .now)
                    try connection.insert(db)
                    workspace.accountConnectionId = connection.id
                    workspace.organizationId = .v7()
                    workspace.syncRole = "admin"
                    workspace.syncConfirmedConnectionId = connection.id
                }
                try workspace.insert(db)
                try MeetingRecord(id: meetingID, workspaceId: workspaceID, name: "Meeting", createdAt: .now, updatedAt: .now).insert(db)
            }
            return (queue, workspaceID, meetingID)
        }

        private func remoteDocument(_ queue: DatabaseQueue, meetingID: UUID) async throws -> DocumentRecord {
            try await queue.read { db in
                if let existing = try DocumentRecord.notes(in: db, meetingID: meetingID) { return existing }
                let meeting = try #require(try MeetingRecord.fetchOne(db, key: meetingID))
                return DocumentRecord(
                    id: .v7(),
                    workspaceId: meeting.workspaceId,
                    meetingId: meetingID,
                    checkpoint: "AAA=",
                    createdAt: .now,
                    updatedAt: .now
                )
            }
        }

        @Test(arguments: [
            "v41_vaultAISettingsBackfill", "v45_workspaceLiveTranscriptDraft", "v46_workspacePersonalUser", "v47_orphanedRecordingRecoveryState",
        ])
        func releasedSchemaUpgradePreservesLiteralNotes(migration: String) async throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: migration)
            let workspaceID = UUID.v7(), meetingID = UUID.v7(), date = Date(timeIntervalSince1970: 1_700_000_000)
            let legacy = "# literal\r\n\n日本語\n"
            try await queue.write { db throws in
                let table = migration.hasPrefix("v41_") ? "vaults" : "workspaces"
                let column = migration.hasPrefix("v41_") ? "vaultId" : "workspace_id"
                let pathColumn = migration.hasPrefix("v41_") ? ", path" : ""
                let pathValue = migration.hasPrefix("v41_") ? ", '/tmp/documents-fixture'" : ""
                try db.execute(
                    sql: "INSERT INTO \(table) (id, name, createdAt, lastOpenedAt\(pathColumn)) VALUES (?, 'Preserved', ?, ?\(pathValue))",
                    arguments: [workspaceID, date, date]
                )
                try db.execute(
                    sql: "INSERT INTO meetings (id, \(column), name, createdAt, updatedAt) VALUES (?, ?, 'Meeting', ?, ?)",
                    arguments: [meetingID, workspaceID, date, date]
                )
                try MeetingNoteRecord(meetingId: meetingID, text: legacy, createdAt: date, updatedAt: date).insert(db)
            }
            try AppDatabaseManager.migrator.migrate(queue)
            let persistence = DocumentPersistence(dbQueue: queue)
            #expect(try await persistence.prepare(meetingID: meetingID).projection.text == legacy)
            #expect(try await persistence.prepare(meetingID: meetingID).projection.text == legacy)
            try await queue.read { db throws in
                #expect(try MeetingNoteRecord.fetchOne(db, key: meetingID)?.text == legacy)
                #expect(try DocumentRecord.notes(in: db, meetingID: meetingID)?.createdAt == date)
                #expect(try DocumentRecord.notes(in: db, meetingID: meetingID)?.updatedAt == date)
                #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
            }
        }

        @Test func serverLegacyRemainsPrivateUntilPublication() async throws {
            let (queue, _, id) = try seed(server: true)
            try await queue.write { try MeetingNoteRecord(meetingId: id, text: "private", createdAt: .now, updatedAt: .now).insert($0) }
            #expect(try await DocumentPersistence(dbQueue: queue).prepare(meetingID: id).projection.text.isEmpty)
            #expect(try await queue.read { try DocumentRecord.fetchCount($0) } == 0)
            #expect(try await queue.read { try DocumentUpdateRecord.fetchCount($0) } == 0)
        }

        @Test func cancellationStopsDocumentTransportAndAllowsRetry() async throws {
            let (queue, _, id) = try seed(server: true)
            let persistence = DocumentPersistence(dbQueue: queue)
            try await persistence.append(meetingID: id, update: persistence.legacyImport(text: "pending input"), local: true)
            let gate = DocumentTokenGate()
            let service = DocumentSyncService(dbQueue: queue, api: SyncAPIClient(session: .shared, tokenProvider: { _, _ in
                try await gate.token()
            }))
            for expected in 1 ... 2 {
                let operation = Task { try await service.synchronize(meetingID: id) }
                let started = await pollUntil { await gate.started == expected }
                operation.cancel()
                let cancelled = await pollUntil(timeout: .seconds(2)) { await gate.cancelled == expected }
                await gate.release()
                _ = try? await operation.value
                #expect(started)
                #expect(cancelled)
                #expect(try await queue.read { try DocumentUpdateRecord.filter(Column("pending") == true).fetchCount($0) } == 1)
            }
        }

        @Test func durableIngressAcceptsAWholeLegalStateAndRejectsOversizedBytes() async throws {
            let (queue, _, id) = try seed()
            let persistence = DocumentPersistence(dbQueue: queue)
            let text = String(repeating: "語", count: 1_600_000)
            let update = try await persistence.legacyImport(text: text)
            #expect(update.utf8.count > 6 * 1024 * 1024)
            try await persistence.append(meetingID: id, update: update, local: true)
            #expect(try await persistence.materialize(meetingID: id).projection.text == text)
            let tooLarge = Data(count: DocumentLimits.stateBytes + 1).base64EncodedString()
            await #expect(throws: (any Error).self) { try await persistence.append(meetingID: id, update: tooLarge, local: true) }
        }

        @Test func restartCompactionAndPrivateTransferPreservePendingBytes() async throws {
            let (queue, workspaceID, id) = try seed()
            let worker = DocumentCoreWorker()
            defer { worker.stop() }
            let persistence = DocumentPersistence(dbQueue: queue)
            let first = try await worker.process(DocumentCoreCommand(text: "one"))
            try await persistence.append(meetingID: id, update: first.update, local: true)
            let second = try await worker.process(DocumentCoreCommand(checkpoint: first.checkpoint, text: "two", vector: first.vector))
            for _ in 0 ..< 35 {
                try await persistence.append(meetingID: id, update: second.update, local: true)
            }
            let reopened = DocumentPersistence(dbQueue: queue)
            #expect(try await reopened.materialize(meetingID: id).projection.text == "one\ntwo")
            try await reopened.prepareAccountTransfer(workspaceID: workspaceID)
            try await queue.write { try DocumentPersistence.preservePrivateCopies(workspaceID: workspaceID, in: $0) }
            let copy = try #require(try await queue.read { try DocumentPrivateCopyRecord.fetchOne($0) })
            #expect(try await worker.process(DocumentCoreCommand(checkpoint: copy.checkpoint)).projection.text == "one\ntwo")
            #expect(try await queue.read { try DocumentRecord.fetchCount($0) } == 0)
        }

        @Test func remoteDeletionAndLRUNeverDiscardPendingEdits() async throws {
            let (queue, workspaceID, id) = try seed(server: true)
            let persistence = DocumentPersistence(dbQueue: queue)
            let update = try await persistence.legacyImport(text: "not yet uploaded")
            try await persistence.append(meetingID: id, update: update, local: true)
            _ = try await persistence.materialize(meetingID: id)
            try await queue.write { db throws in
                #expect(try DocumentRetention.evict(
                    documentID: #require(try DocumentRecord.notes(in: db, meetingID: id)).id,
                    protectedWorkspaces: [],
                    in: db
                ) == 0)
                try DocumentRetention.archiveBeforeRemoteDeletion(meetingID: id, in: db)
                try MeetingRecord.deleteOne(db, key: id)
            }
            let archive = try await persistence.archives(workspaceID: workspaceID)
            #expect(archive.count == 1)
            #expect(archive[0].2.contains("not yet uploaded"))
            #expect(try await queue.read { try DocumentRetention.hasPrivateData(workspaceID: workspaceID, in: $0) })
        }

        @Test func backupRemapsMeetingAndDocumentTogetherWithoutDroppingUpdateLog() async throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: "documents-backup-\(UUID.v7())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let sourceURL = directory.appending(path: "source.sqlite")
            let source = try AppDatabaseManager(path: sourceURL.path)
            let (seedQueue, workspaceID, meetingID) = try seed()
            try seedQueue.backup(to: source.dbQueue)
            let persistence = DocumentPersistence(dbQueue: source.dbQueue)
            let update = try await persistence.legacyImport(text: "portable edits")
            try await persistence.append(meetingID: meetingID, update: update, local: true)
            let generalID = UUID.v7()
            try await source.dbQueue.write { db in
                try DocumentRecord(
                    id: generalID,
                    workspaceId: workspaceID,
                    meetingId: nil,
                    kind: "general",
                    title: "Independent",
                    checkpoint: "AAA=",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                var entry = DocumentUpdateRecord(documentId: generalID, payload: update, pending: true, createdAt: .now)
                try entry.insert(db)
            }
            try source.close()
            let destination = try AppDatabaseManager(path: ":memory:").dbQueue
            let workspace = WorkspaceRecord(id: .v7(), name: "Restored", createdAt: .now, lastOpenedAt: .now)
            try await destination.write { db in
                try db.execute(sql: "ATTACH DATABASE ? AS backup_source", arguments: [sourceURL.path])
                try WorkspaceBackupTransfer.copy(workspaceId: workspaceID, in: db, destinationWorkspace: workspace, remapIDs: true)
            }
            let restored = try await destination.read { db in
                try UUID.fetchOne(db, sql: "SELECT id FROM meetings WHERE workspace_id = ?", arguments: [workspace.id])
            }
            let restoredID = try #require(restored)
            #expect(restoredID != meetingID)
            #expect(try await destination.read { try DocumentRecord.notes(in: $0, meetingID: restoredID)?.meetingId } == restoredID)
            #expect(try await DocumentPersistence(dbQueue: destination).materialize(meetingID: restoredID).projection.text == "portable edits")
            let general = try #require(try await destination.read { try DocumentRecord.filter(Column("kind") == "general").fetchOne($0) })
            #expect(general.id != generalID && general.meetingId == nil && general.workspaceId == workspace.id && general.title == "Independent")
            #expect(try await DocumentPersistence(dbQueue: destination).materialize(documentID: general.id).projection.text == "portable edits")
            #expect(try await destination.read { try DocumentRecord.notes(in: $0, meetingID: restoredID)?.id } != restoredID)
        }

        @Test func revokedPermissionPreservesBridgedEditsWithoutPublishing() async throws {
            let (queue, workspaceID, meetingID) = try seed(server: true)
            let persistence = DocumentPersistence(dbQueue: queue)
            let update = try await persistence.legacyImport(text: "typed before revocation")
            try await queue.write { try $0.execute(sql: "UPDATE workspaces SET syncRole = 'viewer' WHERE id = ?", arguments: [workspaceID]) }
            await #expect(throws: DocumentCoreError.editPreservedPrivately) {
                try await persistence.append(meetingID: meetingID, update: update, local: true)
            }
            #expect(try await queue.read { try DocumentUpdateRecord.fetchCount($0) } == 0)
            #expect(try await persistence.archives(workspaceID: workspaceID).first?.2.contains("typed before revocation") == true)
        }

        @Test func viewerSyncReceivesWithoutPublishingPendingEditsAndFlushFails() async throws {
            let (queue, workspaceID, meetingID) = try seed(server: true)
            let persistence = DocumentPersistence(dbQueue: queue), generation = UUID.v7()
            let document = try await remoteDocument(queue, meetingID: meetingID)
            let shared = try await persistence.legacyImport(text: "shared"), pending = try await persistence.legacyImport(text: "private edit")
            try await persistence.receive(document: document, update: shared, generation: generation, revision: 1, validate: { _ in })
            try await persistence.append(meetingID: meetingID, update: pending, local: true)
            let origin = "https://viewer-\(UUID.v7().uuidString.lowercased()).invalid"
            try await queue.write { db in
                try db.execute(sql: "UPDATE dahlia_account_connections SET origin = ?", arguments: [origin])
                try db.execute(sql: "UPDATE workspaces SET syncRole = 'viewer' WHERE id = ?", arguments: [workspaceID])
                try DocumentRecoveryRecord(id: .v7(), documentId: document.id, blocksJSON: "[]", reason: "deleted", pending: true, createdAt: .now)
                    .insert(db)
            }
            let remoteEdit = try await persistence.legacyImport(text: "remote edit")
            let response = try JSONSerialization.data(withJSONObject: ["generation": generation.uuidString, "revision": 2, "update": remoteEdit])
            let writes = Mutex(0)
            ImageURLProtocol.register(origin: origin) { request in
                let path = request.url!.path
                if path.hasSuffix("/capabilities") { return (200, [:], Data(#"{"documents":{"version":1}}"#.utf8)) }
                if path.hasSuffix("/sync") {
                    let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                    if body?["update"] is String { writes.withLock { $0 += 1 } }
                    return (200, [:], response)
                }
                if path.hasSuffix("/recoveries") {
                    if request.httpMethod == "POST" { writes.withLock { $0 += 1 } }
                    return (200, [:], Data(#"{"items":[],"nextCursor":null}"#.utf8))
                }
                return (500, [:], Data())
            }
            defer { ImageURLProtocol.remove(origin: origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let api = SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" })
            let sync = DocumentSyncService(dbQueue: queue, api: api)
            try await sync.synchronize(meetingID: meetingID)
            await #expect(throws: SyncHTTPError.self) { try await sync.flush(meetingID: meetingID) }
            #expect(writes.withLock { $0 } == 0)
            let text = try await persistence.materialize(meetingID: meetingID).projection.text
            #expect(text.contains("private edit") && text.contains("remote edit"))
            try await queue.read { db throws in
                #expect(try DocumentUpdateRecord.filter(Column("pending") == true).fetchCount(db) == 1)
                #expect(try DocumentRecoveryRecord.filter(Column("pending") == true).fetchCount(db) == 1)
            }
        }

        @Test func acknowledgedSharedCacheCanBeEvictedAndRefetched() async throws {
            let (queue, _, meetingID) = try seed(server: true)
            let persistence = DocumentPersistence(dbQueue: queue)
            let update = try await persistence.legacyImport(text: "reconstructable")
            let generation = UUID.v7()
            try await persistence.receive(
                document: remoteDocument(queue, meetingID: meetingID),
                update: update,
                generation: generation,
                revision: 1,
                validate: { _ in }
            )
            _ = try await persistence.materialize(meetingID: meetingID, compact: true)
            #expect(try await queue.write { db in
                try DocumentRetention.evict(
                    documentID: #require(try DocumentRecord.notes(in: db, meetingID: meetingID)).id,
                    protectedWorkspaces: [],
                    in: db
                )
            } > 0)
            #expect(try await queue.read { try DocumentRecord.notes(in: $0, meetingID: meetingID)?.resident } == false)
            try await persistence.receive(
                document: remoteDocument(queue, meetingID: meetingID),
                update: update,
                generation: generation,
                revision: 1,
                validate: { _ in }
            )
            #expect(try await persistence.materialize(meetingID: meetingID).projection.text == "reconstructable")
        }

        @Test(arguments: [false, true])
        func restoredGenerationKeepsOpenEditorCausalityAndPendingEdits(pending: Bool) async throws {
            let (queue, _, meetingID) = try seed(server: true)
            let persistence = DocumentPersistence(dbQueue: queue), worker = DocumentCoreWorker()
            defer { worker.stop() }
            let initial = try await worker.process(DocumentCoreCommand(text: "seed"))
            let originalGeneration = UUID.v7(), restoredGeneration = UUID.v7()
            try await persistence.receive(
                document: remoteDocument(queue, meetingID: meetingID),
                update: initial.checkpoint,
                generation: originalGeneration,
                revision: 9,
                validate: { _ in }
            )
            let edited: DocumentCoreResult
            if pending {
                edited = try await worker.process(DocumentCoreCommand(checkpoint: initial.checkpoint, text: "old", vector: initial.vector))
                try await persistence.append(meetingID: meetingID, update: edited.update, local: true)
            } else {
                edited = initial
            }
            try await persistence.receive(
                document: remoteDocument(queue, meetingID: meetingID),
                update: initial.checkpoint,
                generation: restoredGeneration,
                revision: 1,
                validate: { _ in }
            )
            // A still-open editor's next delta depends on the earlier local insertion.
            let next = try await worker.process(DocumentCoreCommand(checkpoint: edited.checkpoint, text: "new", vector: edited.vector))
            try await persistence.append(meetingID: meetingID, update: next.update, local: true)
            let expected = pending ? "seed\nold\nnew" : "seed\nnew"
            #expect(try await persistence.materialize(meetingID: meetingID).projection.text == expected)
            try await queue.read { db in
                let record = try #require(try DocumentRecord.notes(in: db, meetingID: meetingID))
                #expect(record.generation == restoredGeneration)
                #expect(record.revision == 1)
                #expect(try DocumentUpdateRecord.filter(Column("pending") == true).fetchCount(db) == (pending ? 2 : 1))
            }
        }

        @Test func acknowledgedRecoveryStillProtectsItsLocalCopy() async throws {
            let (queue, workspaceID, meetingID) = try seed(server: true)
            let document = try await remoteDocument(queue, meetingID: meetingID)
            try await queue.write { db in
                try document.insert(db)
                try DocumentRecoveryRecord(
                    id: .v7(),
                    documentId: document.id,
                    blocksJSON: "[]",
                    reason: "concurrent_delete",
                    pending: false,
                    createdAt: .now
                ).insert(db)
                #expect(try DocumentRetention.hasPrivateData(workspaceID: workspaceID, in: db))
                try DocumentRetention.archiveBeforeRemoteDeletion(meetingID: meetingID, in: db)
                try MeetingRecord.deleteOne(db, key: meetingID)
                #expect(try DocumentRetention.hasPrivateData(workspaceID: workspaceID, in: db))
            }
        }

        @Test func remoteOnlyDeletionDoesNotCreateAnUnsendableViewerRecovery() async throws {
            struct Fixture: Decodable { let checkpoint: String
                let deletionUpdate: String
            }
            let url = try #require(Bundle.module.url(forResource: "documents", withExtension: "json", subdirectory: "Fixtures"))
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
            let (queue, workspaceID, meetingID) = try seed(server: true)
            try await queue.write { try $0.execute(sql: "UPDATE workspaces SET syncRole = 'viewer' WHERE id = ?", arguments: [workspaceID]) }
            let persistence = DocumentPersistence(dbQueue: queue), generation = UUID.v7()
            try await persistence.receive(
                document: remoteDocument(queue, meetingID: meetingID),
                update: fixture.checkpoint,
                generation: generation,
                revision: 1,
                validate: { _ in }
            )
            try await persistence.receive(
                document: remoteDocument(queue, meetingID: meetingID),
                update: fixture.deletionUpdate,
                generation: generation,
                revision: 2,
                validate: { _ in }
            )
            #expect(try await queue.read { try DocumentRecoveryRecord.fetchCount($0) } == 0)
            #expect(try await persistence.materialize(meetingID: meetingID).projection.text == "# literal\r\n")
        }

        @Test func editorFromBeforeAccountMoveArchivesLateDeltaAgainstItsPrivateCheckpoint() async throws {
            let (queue, workspaceID, meetingID) = try seed()
            let persistence = DocumentPersistence(dbQueue: queue), worker = DocumentCoreWorker()
            defer { worker.stop() }
            let initial = try await worker.process(DocumentCoreCommand(text: "private before move"))
            try await persistence.append(meetingID: meetingID, update: initial.update, local: true)
            _ = try await persistence.materialize(meetingID: meetingID, compact: true)
            let late = try await worker.process(DocumentCoreCommand(checkpoint: initial.checkpoint, text: "late input", vector: initial.vector))
            try await queue.write { db in
                try DocumentPersistence.preservePrivateCopies(workspaceID: workspaceID, in: db)
                let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://example.invalid", clientID: "test", createdAt: .now)
                try connection.insert(db)
                try db.execute(
                    sql: "UPDATE workspaces SET accountConnectionId = ?, organizationId = ?, syncRole = 'admin', syncConfirmedConnectionId = ? WHERE id = ?",
                    arguments: [connection.id, UUID.v7(), connection.id, workspaceID]
                )
            }
            await #expect(throws: DocumentCoreError.editPreservedPrivately) {
                try await persistence.append(
                    meetingID: meetingID,
                    update: late.update,
                    local: true,
                    orphan: .init(workspaceID: workspaceID, meetingID: meetingID, name: "Original")
                )
            }
            #expect(try await queue.read { try DocumentRecord.fetchCount($0) } == 0)
            #expect(try await persistence.archives(workspaceID: workspaceID).first?.2.contains("private before move\nlate input") == true)
        }

        @Test(arguments: [false, true])
        func v47UpgradePreservesDocumentRelationshipsAndBytes(predatesRecordingRecovery: Bool) throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v47_documents")
            if predatesRecordingRecovery {
                // Disposable fixture for a Documents build made before the independent main migration.
                try queue.write { db in
                    try db.execute(sql: "DROP TABLE orphaned_recording_recoveries")
                    try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v47_orphanedRecordingRecoveryState'")
                }
            }
            let workspaceID = UUID.v7(), meetingID = UUID.v7(), recoveryID = UUID.v7(), copyID = UUID.v7(), date = Date()
            try queue.write { db in
                try WorkspaceRecord(id: workspaceID, name: "Old", createdAt: date, lastOpenedAt: date).insert(db)
                try MeetingRecord(id: meetingID, workspaceId: workspaceID, name: "Old", createdAt: date, updatedAt: date).insert(db)
                try db.execute(
                    sql: "INSERT INTO documents(id, meetingId, checkpoint, text, createdAt, updatedAt) VALUES (?, ?, 'AAA=', 'old projection', ?, ?)",
                    arguments: [meetingID, meetingID, date, date]
                )
                try db.execute(
                    sql: "INSERT INTO document_updates(meetingId, payload, pending, createdAt) VALUES (?, 'AAA=', 1, ?)",
                    arguments: [meetingID, date]
                )
                try db.execute(
                    sql: "INSERT INTO document_recoveries(id, meetingId, blocksJSON, reason, pending, createdAt) VALUES (?, ?, '[]', 'deleted', 1, ?)",
                    arguments: [recoveryID, meetingID, date]
                )
                try db.execute(
                    sql: "INSERT INTO document_private_copies(id, meetingId, checkpoint, text, createdAt, updatedAt) VALUES (?, ?, 'AAA=', 'private', ?, ?)",
                    arguments: [copyID, meetingID, date, date]
                )
            }
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.read { db in
                let document = try #require(try DocumentRecord.notes(in: db, meetingID: meetingID))
                #expect(document.id == meetingID) // Existing identity is preserved, but no longer required.
                #expect(document.workspaceId == workspaceID && document.text == "old projection")
                #expect(try DocumentUpdateRecord.fetchOne(db)?.documentId == document.id)
                #expect(try DocumentRecoveryRecord.fetchOne(db, key: recoveryID)?.documentId == document.id)
                #expect(try DocumentPrivateCopyRecord.fetchOne(db, key: copyID)?.workspaceId == workspaceID)
                #expect(try db.tableExists("orphaned_recording_recoveries"))
                #expect(try AppDatabaseManager.migrator.hasCompletedMigrations(db))
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }

        @Test func canonicalNotesIDRebindPreservesPendingUpdatesAndRecoveries() async throws {
            let (queue, workspaceID, meetingID) = try seed(server: true)
            let persistence = DocumentPersistence(dbQueue: queue)
            let update = try await persistence.legacyImport(text: "offline")
            try await persistence.append(meetingID: meetingID, update: update, local: true)
            let old = try #require(try await queue.read { try DocumentRecord.notes(in: $0, meetingID: meetingID) })
            let recoveryID = UUID.v7(), canonicalID = UUID.v7()
            try await queue.write { db in
                try DocumentRecoveryRecord(id: recoveryID, documentId: old.id, blocksJSON: "[]", reason: "deleted", pending: true, createdAt: .now)
                    .insert(db)
            }
            let remote = DocumentRecord(
                id: canonicalID,
                workspaceId: workspaceID,
                meetingId: meetingID,
                checkpoint: "AAA=",
                createdAt: .now,
                updatedAt: .now
            )
            try await persistence.receive(document: remote, update: "AAA=", generation: .v7(), revision: 0, validate: { _ in })
            #expect(try await persistence.materialize(meetingID: meetingID).projection.text == "offline")
            try await queue.read { db throws in
                #expect(try DocumentRecord.fetchOne(db, key: old.id) == nil)
                #expect(try DocumentRecord.notes(in: db, meetingID: meetingID)?.id == canonicalID)
                #expect(try DocumentUpdateRecord.filter(Column("pending") == true).fetchOne(db)?.documentId == canonicalID)
                #expect(try DocumentRecoveryRecord.fetchOne(db, key: recoveryID)?.documentId == canonicalID)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }

        @Test func independentDocumentOwnershipAndMeetingNotesUniqueness() async throws {
            let (queue, workspaceID, meetingID) = try seed()
            let other = UUID.v7(), generalID = UUID.v7()
            let persistence = DocumentPersistence(dbQueue: queue)
            let state = try await persistence.legacyImport(text: "general")
            try await queue.write { db in
                try WorkspaceRecord(id: other, name: "Other", createdAt: .now, lastOpenedAt: .now).insert(db)
                try DocumentRecord(
                    id: generalID,
                    workspaceId: workspaceID,
                    meetingId: nil,
                    kind: "general",
                    title: "Own title",
                    checkpoint: state,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                for _ in 0 ..< 2 {
                    try DocumentRecord(
                        id: .v7(),
                        workspaceId: workspaceID,
                        meetingId: meetingID,
                        kind: "summary",
                        checkpoint: "AAA=",
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                }
                try DocumentRecord(id: .v7(), workspaceId: workspaceID, meetingId: meetingID, checkpoint: "AAA=", createdAt: .now, updatedAt: .now)
                    .insert(db)
                #expect(throws: (any Error).self) {
                    try DocumentRecord(
                        id: .v7(),
                        workspaceId: workspaceID,
                        meetingId: meetingID,
                        checkpoint: "AAA=",
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                }
                #expect(throws: (any Error).self) {
                    try DocumentRecord(
                        id: .v7(),
                        workspaceId: other,
                        meetingId: meetingID,
                        kind: "general",
                        checkpoint: "AAA=",
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                }
                try WorkspaceRelocation.move([(.init(entity: .meeting, id: meetingID, workspaceId: other), workspaceID)], in: db)
                #expect(try DocumentRecord.notes(in: db, meetingID: meetingID)?.workspaceId == other)
                try MeetingRecord.deleteOne(db, key: meetingID)
                #expect(try DocumentRecord.fetchCount(db) == 1)
            }
            #expect(try await persistence.materialize(documentID: generalID).projection.text == "general")
            try await persistence.prepareAccountTransfer(workspaceID: workspaceID)
            try await queue.write { try DocumentPersistence.preservePrivateCopies(workspaceID: workspaceID, in: $0) }
            let copy = try #require(try await queue.read { try DocumentPrivateCopyRecord.fetchOne($0) })
            #expect(copy.meetingId == nil && copy.workspaceId == workspaceID && copy.kind == "general" && copy.title == "Own title")
            #expect(copy.text == "general")
        }

        @Test func synchronizationResolvesNotesThenUsesCanonicalDocumentID() async throws {
            let (queue, workspaceID, meetingID) = try seed(server: true)
            let persistence = DocumentPersistence(dbQueue: queue), canonicalID = UUID.v7(), generation = UUID.v7()
            let origin = "https://documents-\(UUID.v7().uuidString.lowercased()).invalid"
            try await queue.write { try $0.execute(sql: "UPDATE dahlia_account_connections SET origin = ?", arguments: [origin]) }
            try await persistence.append(meetingID: meetingID, update: persistence.legacyImport(text: "offline input"), local: true)
            let proposed = try #require(try await queue.read { try DocumentRecord.notes(in: $0, meetingID: meetingID)?.id })
            let response = try JSONSerialization.data(withJSONObject: ["document": [
                "id": canonicalID.uuidString, "workspaceId": workspaceID.uuidString, "meetingId": meetingID.uuidString,
                "kind": "notes", "title": "", "schemaVersion": 1, "generation": generation.uuidString, "revision": 0,
                "checkpoint": "AAA=", "text": "", "createdAt": "2026-09-29T00:00:00.000Z", "updatedAt": "2026-09-29T00:00:00.000Z",
            ]])
            let exchange = try JSONSerialization.data(withJSONObject: ["generation": generation.uuidString, "revision": 1, "update": "AAA="])
            ImageURLProtocol.register(origin: origin) { request in
                let path = request.url!.path.lowercased()
                if path.hasSuffix("/capabilities") { return (200, [:], Data(#"{"documents":{"version":1}}"#.utf8)) }
                if path.hasSuffix("/meetings/\(meetingID.uuidString.lowercased())/notes") {
                    if request.httpMethod == "GET" { return (200, [:], Data(#"{"document":null}"#.utf8)) }
                    #expect((ImageURLProtocol.requestJSON(request)?["id"] as? String)?.lowercased() == proposed.uuidString.lowercased())
                    return (200, [:], response)
                }
                #expect(path.contains("/documents/\(canonicalID.uuidString.lowercased())/"))
                if path.hasSuffix("/sync") { return (200, [:], exchange) }
                if path.hasSuffix("/recoveries") { return (200, [:], Data(#"{"items":[],"nextCursor":null}"#.utf8)) }
                return (404, [:], Data())
            }
            defer { ImageURLProtocol.remove(origin: origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let client = SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" })
            try await DocumentSyncService(dbQueue: queue, api: client).synchronize(meetingID: meetingID)
            #expect(try await persistence.materialize(meetingID: meetingID).projection.text == "offline input")
            try await queue.read { db throws in
                #expect(try DocumentRecord.notes(in: db, meetingID: meetingID)?.id == canonicalID)
                #expect(try DocumentUpdateRecord.filter(Column("pending") == true).fetchCount(db) == 0)
            }
        }

        @Test(arguments: [false, true])
        func workspaceDownloadIncludesUnattachedDocumentsAndRebindsMovedOwnership(alreadyCached: Bool) async throws {
            let (queue, workspaceID, _) = try seed(server: true)
            let persistence = DocumentPersistence(dbQueue: queue)
            let id = UUID.v7(), generation = UUID.v7(), oldWorkspaceID = UUID.v7()
            let checkpoint = try await persistence.legacyImport(text: "Independent body")
            let origin = "https://general-\(UUID.v7().uuidString.lowercased()).invalid"
            try await queue.write { db in
                try db.execute(sql: "UPDATE dahlia_account_connections SET origin = ?", arguments: [origin])
                if alreadyCached {
                    var oldWorkspace = try #require(try WorkspaceRecord.fetchOne(db, key: workspaceID))
                    oldWorkspace.id = oldWorkspaceID
                    try oldWorkspace.insert(db)
                    try DocumentRecord(
                        id: id, workspaceId: oldWorkspaceID, meetingId: nil, kind: "general", title: "Independent title",
                        revision: 1, generation: generation, checkpoint: checkpoint, text: "Independent body",
                        createdAt: .now, updatedAt: .now
                    ).insert(db)
                    var update = DocumentUpdateRecord(documentId: id, payload: "AAA=", pending: true, createdAt: .now)
                    try update.insert(db)
                }
            }
            let item: [String: Any] = [
                "id": id.uuidString, "meetingId": NSNull(), "kind": "general", "generation": generation.uuidString, "revision": 1,
            ]
            let listing = try JSONSerialization.data(withJSONObject: ["items": [item], "nextCursor": NSNull()])
            let response = try JSONSerialization.data(withJSONObject: ["document": [
                "id": id.uuidString, "workspaceId": workspaceID.uuidString, "meetingId": NSNull(),
                "kind": "general", "title": "Independent title", "schemaVersion": 1,
                "generation": generation.uuidString, "revision": 1, "checkpoint": checkpoint, "text": "Independent body",
                "createdAt": "2026-09-29T00:00:00.000Z", "updatedAt": "2026-09-29T00:00:00.000Z",
            ]])
            let exchange = try JSONSerialization.data(withJSONObject: ["generation": generation.uuidString, "revision": 1, "update": "AAA="])
            ImageURLProtocol.register(origin: origin) { request in
                let path = request.url!.path.lowercased()
                if path.hasSuffix("/capabilities") { return (200, [:], Data(#"{"documents":{"version":1}}"#.utf8)) }
                #expect(path.contains("/workspaces/\(workspaceID.uuidString.lowercased())/documents"))
                if path.hasSuffix("/documents") { return (200, [:], listing) }
                if path.hasSuffix("/documents/\(id.uuidString.lowercased())") { return (200, [:], response) }
                if path.hasSuffix("/sync") { return (200, [:], exchange) }
                if path.hasSuffix("/recoveries") { return (200, [:], Data(#"{"items":[],"nextCursor":null}"#.utf8)) }
                return (404, [:], Data())
            }
            defer { ImageURLProtocol.remove(origin: origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let client = SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" })
            try await DocumentSyncService(dbQueue: queue, api: client).synchronizeWorkspace(workspaceID: workspaceID)
            #expect(try await persistence.materialize(documentID: id).projection.text == "Independent body")
            try await queue.read { db in
                let row = try #require(try DocumentRecord.fetchOne(db, key: id))
                #expect(row.workspaceId == workspaceID && row.meetingId == nil && row.title == "Independent title")
                #expect(try DocumentUpdateRecord.filter(Column("pending") == true).fetchCount(db) == 0)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }

        @Test(arguments: ["moved", "movedViewer", "restoringDestination", "denied", "unavailable"])
        func standaloneTransferBeforeCatalogDiscoveryPreservesPendingEdits(scenario: String) async throws {
            let moved = scenario.hasPrefix("moved"), viewer = scenario == "movedViewer"
            let (queue, sourceID, _) = try seed(server: true)
            let destinationID = UUID.v7(), id = UUID.v7(), generation = UUID.v7()
            let persistence = DocumentPersistence(dbQueue: queue)
            let checkpoint = try await persistence.legacyImport(text: "shared")
            let pending = try await persistence.legacyImport(text: "pending edit")
            let origin = "https://relocated-\(UUID.v7().uuidString.lowercased()).invalid"
            let organizationID = try await queue.write { db in
                try db.execute(sql: "UPDATE dahlia_account_connections SET origin = ?", arguments: [origin])
                try DocumentRecord(
                    id: id, workspaceId: sourceID, meetingId: nil, kind: "general", title: "Independent",
                    revision: 1, generation: generation, checkpoint: checkpoint, text: "shared", createdAt: .now, updatedAt: .now
                ).insert(db)
                var update = DocumentUpdateRecord(documentId: id, payload: pending, pending: true, createdAt: .now)
                try update.insert(db)
                let source = try #require(try WorkspaceRecord.fetchOne(db, key: sourceID))
                if scenario == "restoringDestination" {
                    try WorkspaceRecord(
                        id: destinationID, name: "Restoring", createdAt: .now, lastOpenedAt: .now,
                        accountConnectionId: source.accountConnectionId, organizationId: source.organizationId,
                        syncRole: "admin", syncConfirmedConnectionId: nil
                    ).insert(db)
                }
                return try #require(source.organizationId)
            }
            let relocation = try JSONSerialization.data(withJSONObject: [
                "workspaces": [[
                    "workspaceId": destinationID.uuidString,
                    "organizationId": organizationID.uuidString,
                    "organizationName": "Organization",
                    "meetingDeletionGraceDays": 7,
                    "generationSettings": JSONSerialization.jsonObject(with: JSONEncoder().encode(WorkspaceGenerationSettings())),
                    "name": "Destination",
                    "createdAt": "2026-09-29T00:00:00.000Z",
                    "updatedAt": "2026-09-29T00:00:00.000Z",
                    "revision": 1,
                    "role": viewer ? "viewer" : "admin",
                ]],
                "items": [], "documents": [["id": id.uuidString, "workspaceId": destinationID.uuidString]],
            ])
            let item: [String: Any] = [
                "id": id.uuidString, "meetingId": NSNull(), "kind": "general", "generation": generation.uuidString, "revision": 1,
            ]
            let listing = try JSONSerialization.data(withJSONObject: ["items": [item], "nextCursor": NSNull()])
            let exchange = try JSONSerialization.data(withJSONObject: ["generation": generation.uuidString, "revision": 2, "update": "AAA="])
            let sent = Mutex<String?>(nil)
            ImageURLProtocol.register(origin: origin) { request in
                let path = request.url!.path.lowercased()
                if path.hasSuffix("/capabilities") { return (200, [:], Data(#"{"documents":{"version":1}}"#.utf8)) }
                if path.contains(destinationID.uuidString.lowercased()) {
                    if path.hasSuffix("/documents") { return (200, [:], listing) }
                    if path.hasSuffix("/sync") {
                        if let data = request.httpBody,
                           let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            sent.withLock { $0 = body["update"] as? String }
                        }
                        return (200, [:], exchange)
                    }
                    if path.hasSuffix("/recoveries") { return (200, [:], Data(#"{"items":[],"nextCursor":null}"#.utf8)) }
                }
                if path.hasSuffix("/documents") { return (200, [:], Data(#"{"items":[],"nextCursor":null}"#.utf8)) }
                if path.hasSuffix("/relocations") {
                    return (moved || scenario == "restoringDestination" ? 200 : scenario == "denied" ? 403 : 503, [:], relocation)
                }
                return (404, [:], Data())
            }
            defer { ImageURLProtocol.remove(origin: origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let api = SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" })
            let sync = DocumentSyncService(dbQueue: queue, api: api)
            if moved {
                try await sync.synchronizeWorkspace(workspaceID: sourceID)
            } else {
                await #expect(throws: (any Error).self) { try await sync.synchronizeWorkspace(workspaceID: sourceID) }
            }
            try await queue.read { db throws in
                #expect(try DocumentRecord.fetchOne(db, key: id)?.workspaceId == (moved ? destinationID : sourceID))
                #expect(try DocumentUpdateRecord.filter(Column("pending") == true).fetchCount(db) == 1)
                #expect(try DocumentLocalArchiveRecord.fetchCount(db) == 0)
                if scenario == "restoringDestination" {
                    #expect(try WorkspaceRecord.fetchOne(db, key: destinationID)?.syncConfirmedConnectionId == nil)
                }
            }
            if moved {
                try await sync.synchronizeWorkspace(workspaceID: destinationID)
                if viewer {
                    #expect(sent.withLock { $0 } == nil)
                    #expect(try await queue.read { try DocumentUpdateRecord.filter(Column("pending") == true).fetchCount($0) } == 1)
                    #expect(try await persistence.materialize(documentID: id).projection.text.contains("pending edit"))
                    try await queue
                        .write { try $0.execute(sql: "UPDATE workspaces SET syncRole = 'editor' WHERE id = ?", arguments: [destinationID]) }
                    try await sync.synchronizeWorkspace(workspaceID: destinationID)
                }
                #expect(try await queue.read { try DocumentUpdateRecord.filter(Column("pending") == true).fetchCount($0) } == 0)
                let worker = DocumentCoreWorker()
                defer { worker.stop() }
                let update = try #require(sent.withLock { $0 })
                #expect(try await worker.process(DocumentCoreCommand(checkpoint: checkpoint, updates: [update])).projection.text
                    .contains("pending edit"))
            }
        }

        @Test(arguments: ["missing", "inventoryFailure", "readFailure", "changedGeneration"], [false, true])
        func missingStandaloneCacheRequiresCanonicalAbsenceAndPreservesPrivateBytes(scenario: String, pending: Bool) async throws {
            let (queue, workspaceID, _) = try seed(server: true)
            let persistence = DocumentPersistence(dbQueue: queue), id = UUID.v7(), generation = UUID.v7()
            let checkpoint = try await persistence.legacyImport(text: "Retained body")
            let origin = "https://missing-\(UUID.v7().uuidString.lowercased()).invalid"
            try await queue.write { db in
                try db.execute(sql: "UPDATE dahlia_account_connections SET origin = ?", arguments: [origin])
                try DocumentRecord(
                    id: id, workspaceId: workspaceID, meetingId: nil, kind: "general", title: "Document",
                    revision: 1, generation: generation, checkpoint: checkpoint, text: "Retained body", createdAt: .now, updatedAt: .now
                ).insert(db)
                if pending {
                    var update = DocumentUpdateRecord(documentId: id, payload: "AAA=", pending: true, createdAt: .now)
                    try update.insert(db)
                }
                try DocumentPrivateCopyRecord(
                    id: .v7(), workspaceId: workspaceID, meetingId: nil, kind: "general", title: "Private",
                    checkpoint: checkpoint, text: "Private body", createdAt: .now, updatedAt: .now
                ).insert(db)
            }
            ImageURLProtocol.register(origin: origin) { request in
                let path = request.url!.path.lowercased()
                if path.hasSuffix("/capabilities") { return (200, [:], Data(#"{"documents":{"version":1}}"#.utf8)) }
                if path.hasSuffix("/documents") {
                    return scenario == "inventoryFailure" ? (503, [:], Data()) : (200, [:], Data(#"{"items":[],"nextCursor":null}"#.utf8))
                }
                if path.hasSuffix("/sync") { return (404, [:], Data()) }
                if path.hasSuffix("/relocations") { return (200, [:], Data(#"{"workspaces":[],"items":[],"documents":[]}"#.utf8)) }
                if path.hasSuffix("/documents/\(id.uuidString.lowercased())") {
                    if scenario == "changedGeneration" {
                        do {
                            try queue.write { try $0.execute(sql: "UPDATE documents SET generation = ? WHERE id = ?", arguments: [UUID.v7(), id]) }
                        } catch {
                            Issue.record(error)
                        }
                    }
                    return (scenario == "readFailure" ? 503 : 404, [:], Data())
                }
                Issue.record("Unexpected route: \(path)")
                return (500, [:], Data())
            }
            defer { ImageURLProtocol.remove(origin: origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let client = SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" })
            let sync = DocumentSyncService(dbQueue: queue, api: client)
            if scenario == "missing" {
                try await sync.synchronizeWorkspace(workspaceID: workspaceID)
            } else {
                await #expect(throws: (any Error).self) { try await sync.synchronizeWorkspace(workspaceID: workspaceID) }
            }
            try await queue.read { db throws in
                #expect(try DocumentRecord.fetchCount(db) == (scenario == "missing" ? 0 : 1))
                #expect(try DocumentPrivateCopyRecord.fetchOne(db)?.text == "Private body")
                #expect(try DocumentUpdateRecord.filter(Column("pending") == true).fetchCount(db) == (pending && scenario != "missing" ? 1 : 0))
            }
            let archives = try await persistence.archives(workspaceID: workspaceID)
            #expect(archives.count == (pending && scenario == "missing" ? 1 : 0))
            if pending, scenario == "missing" { #expect(archives.first?.2.contains("Retained body") == true) }
        }

        @Test(arguments: [false, true])
        func directSummaryRetryFlushesNotesBeforeSnapshotAndStopsOnFailure(fails: Bool) async throws {
            let (queue, workspaceID, meetingID) = try seed(server: true)
            let persistence = DocumentPersistence(dbQueue: queue), generation = UUID.v7()
            let origin = "https://retry-\(UUID.v7().uuidString.lowercased()).invalid"
            try await queue.write { db in
                try db.execute(sql: "UPDATE dahlia_account_connections SET origin = ?", arguments: [origin])
                try db.execute(sql: "UPDATE workspaces SET syncPullCursor = 'ready' WHERE id = ?", arguments: [workspaceID])
                try DocumentRecord(
                    id: .v7(), workspaceId: workspaceID, meetingId: meetingID, generation: generation,
                    checkpoint: "AAA=", createdAt: .now, updatedAt: .now
                ).insert(db)
            }
            try await persistence.append(meetingID: meetingID, update: persistence.legacyImport(text: "Pending snapshot input"), local: true)
            let calls = Mutex<[String]>([])
            let retryResponse = try JSONSerialization.data(withJSONObject: ["job": [
                "id": generation.uuidString, "method": "transcript", "status": "pending", "attempts": 0,
                "settings": ["model": "gpt-5.4", "detail": "high", "reasoningEffort": "medium"], "outputLanguage": "ja", "error": NSNull(),
                "createdAt": "2026-09-29T00:00:00.000Z",
            ]])
            let exchange = try JSONSerialization.data(withJSONObject: ["generation": generation.uuidString, "revision": 1, "update": "AAA="])
            ImageURLProtocol.register(origin: origin) { request in
                let path = request.url!.path
                if path.hasSuffix("/capabilities") { return (200, [:], Data(#"{"documents":{"version":1}}"#.utf8)) }
                if path.hasSuffix("/sync") {
                    calls.withLock { $0.append("sync") }
                    #expect(ImageURLProtocol.requestJSON(request)?["update"] is String)
                    return fails ? (503, [:], Data()) : (200, [:], exchange)
                }
                if path.hasSuffix("/recoveries") { return (200, [:], Data(#"{"items":[],"nextCursor":null}"#.utf8)) }
                if path.hasSuffix("/retry") {
                    calls.withLock { $0.append("retry") }
                    do {
                        #expect(try queue.read { try DocumentUpdateRecord.filter(Column("pending") == true).fetchCount($0) } == 0)
                    } catch {
                        Issue.record(error)
                    }
                    return (202, [:], retryResponse)
                }
                Issue.record("Unexpected route: \(path)")
                return (500, [:], Data())
            }
            defer { ImageURLProtocol.remove(origin: origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let client = SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" })
            let service = ServerSummaryService(client: client, synchronize: { _, _ in })
            let target = try #require(try await service.target(meetingID: meetingID, dbQueue: queue))
            if fails {
                await #expect(throws: (any Error).self) {
                    try await service.retry(target, previousID: UUID.v7().uuidString, id: .v7(), dbQueue: queue)
                }
            } else {
                _ = try await service.retry(target, previousID: UUID.v7().uuidString, id: .v7(), dbQueue: queue)
            }
            #expect(calls.withLock { $0 } == (fails ? ["sync"] : ["sync", "retry"]))
        }

        @Test func failedMigrationRollsBackWithoutChangingLegacyRows() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v46_workspacePersonalUser")
            try queue.write { try $0.execute(sql: "CREATE TABLE document_updates (sentinel TEXT)") }
            #expect(throws: (any Error).self) { try AppDatabaseManager.migrator.migrate(queue) }
            try queue.read { db throws in
                #expect(try !db.tableExists("documents"))
                #expect(try db.columns(in: "document_updates").map(\.name) == ["sentinel"])
                #expect(try !String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations").contains("v47_documents"))
            }
        }
    }

    @MainActor
    struct DocumentEditorLifecycleTests {
        @Test func obsoleteLoadFailureCannotOverwriteReopenedEditor() async throws {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let model = DocumentEditorModel(dbQueue: queue, meetingID: nil, resolveMeeting: { nil })
            let gate = DocumentLoadGate()
            var firstFlush = true
            model.flushEditor = {
                guard firstFlush else { return }
                firstFlush = false
                await gate.wait()
                throw DocumentCoreError.failed
            }
            let obsolete = Task { await model.load() }
            #expect(await pollUntil { await gate.started })
            model.stop()
            await model.load()
            #expect(model.ready)
            await gate.release()
            await obsolete.value
            #expect(model.error.isEmpty)
            #expect(model.ready)
            model.stop()
            try await model.finishLocalSaves()
        }

        @Test(arguments: [false, true])
        func detachedLoadDoesNotRestartEditorSynchronization(cancelLoad: Bool) async throws {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let model = DocumentEditorModel(dbQueue: queue, meetingID: nil, resolveMeeting: { nil })
            let gate = DocumentLoadGate()
            model.flushEditor = { await gate.wait() }
            let loading = Task { await model.load() }
            #expect(await pollUntil { await gate.started })
            model.stop()
            if cancelLoad { loading.cancel() }
            await gate.release()
            await loading.value
            #expect(!model.ready)
            try await model.finishLocalSaves()
            #expect(DocumentEditorModel.activeMeetingIDs(dbQueue: queue).isEmpty)
            await model.load()
            #expect(model.ready)
            model.stop()
            try await model.finishLocalSaves()
        }

        @Test(arguments: [false, true])
        func failedLegacyConversionRemainsReadable(oversized: Bool) async throws {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let workspace = WorkspaceRecord(id: .v7(), name: "Legacy", createdAt: .now, lastOpenedAt: .now)
            let meetingID = UUID.v7()
            let text = oversized ? String(repeating: "x", count: 2_000_001) : "# literal\r\n\n旧 Notes\n"
            try await queue.write { db in
                try workspace.insert(db)
                try MeetingRecord(id: meetingID, workspaceId: workspace.id, name: "Legacy", createdAt: .now, updatedAt: .now).insert(db)
                try MeetingNoteRecord(meetingId: meetingID, text: text, createdAt: .now, updatedAt: .now).insert(db)
                if !oversized {
                    try db
                        .execute(
                            sql: "CREATE TRIGGER fail_conversion BEFORE INSERT ON documents BEGIN SELECT RAISE(ABORT, 'fixture disk error'); END"
                        )
                }
            }
            let model = DocumentEditorModel(dbQueue: queue, meetingID: meetingID, resolveMeeting: { nil })
            await model.load()
            #expect(!model.ready)
            #expect(model.legacyText == text)
            #expect(try await queue.read { try MeetingNoteRecord.fetchOne($0, key: meetingID)?.text } == text)
            model.stop()
            try await model.finishLocalSaves()
            if !oversized {
                try await queue.write { try $0.execute(sql: "DROP TRIGGER fail_conversion") }
                let reopened = DocumentEditorModel(dbQueue: queue, meetingID: meetingID, resolveMeeting: { nil })
                await reopened.load()
                #expect(reopened.ready)
                #expect(reopened.legacyText.isEmpty)
                #expect(try await DocumentPersistence(dbQueue: queue).materialize(meetingID: meetingID).projection.text == text)
                reopened.stop()
                try await reopened.finishLocalSaves()
            }
        }

        @Test func transientDraftResolutionRestoresCausalHistoryAndLaterEditing() async throws {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let workspace = WorkspaceRecord(id: .v7(), name: "Local", createdAt: .now, lastOpenedAt: .now), draftID = UUID.v7()
            try await queue.write { try workspace.insert($0) }
            let resolved = Mutex(false)
            let model = DocumentEditorModel(
                dbQueue: queue, meetingID: nil, orphan: .init(workspaceID: workspace.id, meetingID: draftID, name: "Draft"),
                resolveMeeting: { resolved.withLock { $0 } ? draftID : nil }
            )
            await model.load()
            let core = DocumentCoreWorker()
            defer { core.stop() }
            let first = try await core.process(DocumentCoreCommand(text: "Before resolution", repair: true))
            model.accept(first.update)
            try await model.finishLocalSaves()
            #expect(try await queue.read { try DocumentRecord.fetchCount($0) } == 0)
            try await queue
                .write { try MeetingRecord(id: draftID, workspaceId: workspace.id, name: "Resolved", createdAt: .now, updatedAt: .now).insert($0) }
            resolved.withLock { $0 = true }
            // A summary/save flush also resolves the draft if no further keystroke arrives.
            try await model.finishLocalSaves()
            #expect(try await DocumentPersistence(dbQueue: queue).materialize(meetingID: draftID).projection.text == "Before resolution")
            let second = try await core.process(DocumentCoreCommand(checkpoint: first.checkpoint, text: "After resolution", vector: first.vector))
            model.accept(second.update)
            try await model.finishLocalSaves()
            let third = try await core.process(DocumentCoreCommand(checkpoint: second.checkpoint, text: "Continued", vector: second.vector))
            model.accept(third.update)
            try await model.finishLocalSaves()
            let text = try await DocumentPersistence(dbQueue: queue).materialize(meetingID: draftID).projection.text
            #expect(text == "Before resolution\nAfter resolution\nContinued")
            try await model.synchronizeVisibleDocument()
            #expect(model.status == L10n.documentSavedLocally)
            #expect(model.error.isEmpty)
            #expect(try await queue.read { try DocumentLocalArchiveRecord.fetchCount($0) } == 1)
            model.stop()
            try await model.finishLocalSaves()
        }

        @Test func unresolvedDraftRetainsOriginalWorkspaceAndNeverPublishesItsPrivateFallback() async throws {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let workspace = WorkspaceRecord(id: .v7(), name: "Original", createdAt: .now, lastOpenedAt: .now)
            let draftID = UUID.v7()
            try await queue.write { db in
                try workspace.insert(db)
                try db
                    .execute(
                        sql: "CREATE TRIGGER fail_archive BEFORE INSERT ON document_local_archives BEGIN SELECT RAISE(ABORT, 'fixture disk error'); END"
                    )
            }
            let model = DocumentEditorModel(
                dbQueue: queue,
                meetingID: nil,
                orphan: .init(workspaceID: workspace.id, meetingID: draftID, name: "Draft"),
                resolveMeeting: { nil }
            )
            await model.load()
            try await model.accept(DocumentPersistence(dbQueue: queue).legacyImport(text: "unmaterialized draft input"))
            await #expect(throws: (any Error).self) { try await model.finishLocalSaves() }
            model.stop()
            #expect(DocumentEditorModel.reserveRemoval(meetingIDs: [], dbQueue: queue, workspaceID: workspace.id) == nil)
            try await queue.write { db in
                try db.execute(sql: "DROP TRIGGER fail_archive")
                try MeetingRecord(id: draftID, workspaceId: workspace.id, name: "Created meanwhile", createdAt: .now, updatedAt: .now).insert(db)
            }
            try await DocumentEditorModel.finishLocalSaves(dbQueue: queue)
            #expect(try await queue.read { try DocumentRecord.fetchCount($0) } == 0)
            #expect(try await DocumentPersistence(dbQueue: queue).archives(workspaceID: workspace.id).first?.2
                .contains("unmaterialized draft input") == true)
            #expect(try await queue.read { try DocumentRetention.hasPrivateData(workspaceID: workspace.id, in: $0) })
        }

        @Test func failedEditorDrainRetriesAfterStorageRecoveryAndFencesParentRemoval() async throws {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let workspace = WorkspaceRecord(id: .v7(), name: "Test", createdAt: .now, lastOpenedAt: .now)
            let meetingID = UUID.v7()
            try await queue.write { db in
                try workspace.insert(db)
                try MeetingRecord(id: meetingID, workspaceId: workspace.id, name: "Test", createdAt: .now, updatedAt: .now).insert(db)
                try db
                    .execute(
                        sql: "CREATE TRIGGER fail_document_save BEFORE INSERT ON document_updates BEGIN SELECT RAISE(ABORT, 'fixture disk error'); END"
                    )
            }
            let model = DocumentEditorModel(dbQueue: queue, meetingID: meetingID, resolveMeeting: { nil })
            await model.load()
            try await model.accept(DocumentPersistence(dbQueue: queue).legacyImport(text: "retained after failure"))
            await #expect(throws: (any Error).self) { try await model.finishLocalSaves() }
            model.stop()
            #expect(DocumentEditorModel.reserveRemoval(meetingIDs: [meetingID], dbQueue: queue) == nil)
            try await queue.write { try $0.execute(sql: "DROP TRIGGER fail_document_save") }
            try await DocumentEditorModel.finishLocalSaves(dbQueue: queue)
            #expect(try await DocumentPersistence(dbQueue: queue).materialize(meetingID: meetingID).projection.text == "retained after failure")
            let lease = try #require(DocumentEditorModel.reserveRemoval(meetingIDs: [meetingID], dbQueue: queue))
            let blocked = DocumentEditorModel(dbQueue: queue, meetingID: meetingID, resolveMeeting: { nil })
            await blocked.load()
            #expect(!blocked.ready)
            DocumentEditorModel.releaseRemoval(lease)
            await blocked.load()
            #expect(blocked.ready)
            #expect(DocumentEditorModel.reserveRemoval(meetingIDs: [meetingID], dbQueue: queue) == nil)
            let other = try #require(DocumentEditorModel.reserveRemoval(meetingIDs: [.v7()], dbQueue: queue))
            DocumentEditorModel.releaseRemoval(other)
            blocked.stop()
            try await blocked.finishLocalSaves()
        }
    }

    private actor DocumentLoadGate {
        private(set) var started = false
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            started = true
            guard !released else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            released = true
            for waiter in waiters {
                waiter.resume()
            }
            waiters.removeAll()
        }
    }

    private actor DocumentTokenGate {
        private(set) var started = 0
        private(set) var cancelled = 0
        private var pending: CheckedContinuation<String, any Error>?

        func token() async throws -> String {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    pending = $0
                    started += 1
                }
            } onCancel: {
                Task { await self.cancel() }
            }
        }

        private func cancel() {
            cancelled += 1
            release()
        }

        func release() {
            pending?.resume(throwing: CancellationError())
            pending = nil
        }
    }
#endif
