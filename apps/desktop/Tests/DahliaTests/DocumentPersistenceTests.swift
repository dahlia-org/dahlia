#if canImport(Testing)
    import Foundation
    import GRDB
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

        @Test(arguments: ["v41_vaultAISettingsBackfill", "v45_workspaceLiveTranscriptDraft", "v46_workspacePersonalUser"])
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
                #expect(try DocumentRecord.fetchOne(db, key: meetingID)?.createdAt == date)
                #expect(try DocumentRecord.fetchOne(db, key: meetingID)?.updatedAt == date)
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
                #expect(try DocumentRetention.evict(meetingID: id, protectedWorkspaces: [], in: db) == 0)
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
            #expect(try await destination.read { try DocumentRecord.fetchOne($0, key: restoredID)?.meetingId } == restoredID)
            #expect(try await DocumentPersistence(dbQueue: destination).materialize(meetingID: restoredID).projection.text == "portable edits")
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

        @Test func acknowledgedSharedCacheCanBeEvictedAndRefetched() async throws {
            let (queue, _, meetingID) = try seed(server: true)
            let persistence = DocumentPersistence(dbQueue: queue)
            let update = try await persistence.legacyImport(text: "reconstructable")
            let generation = UUID.v7()
            try await persistence.receive(meetingID: meetingID, update: update, generation: generation, revision: 1, validate: { _ in })
            _ = try await persistence.materialize(meetingID: meetingID, compact: true)
            #expect(try await queue.write { try DocumentRetention.evict(meetingID: meetingID, protectedWorkspaces: [], in: $0) } > 0)
            #expect(try await queue.read { try DocumentRecord.fetchOne($0, key: meetingID)?.resident } == false)
            try await persistence.receive(meetingID: meetingID, update: update, generation: generation, revision: 1, validate: { _ in })
            #expect(try await persistence.materialize(meetingID: meetingID).projection.text == "reconstructable")
        }

        @Test(arguments: [false, true])
        func restoredGenerationKeepsOpenEditorCausalityAndPendingEdits(pending: Bool) async throws {
            let (queue, _, meetingID) = try seed(server: true)
            let persistence = DocumentPersistence(dbQueue: queue), worker = DocumentCoreWorker()
            defer { worker.stop() }
            let initial = try await worker.process(DocumentCoreCommand(text: "seed"))
            let originalGeneration = UUID.v7(), restoredGeneration = UUID.v7()
            try await persistence.receive(meetingID: meetingID, update: initial.checkpoint, generation: originalGeneration, revision: 9, validate: { _ in })
            let edited: DocumentCoreResult
            if pending {
                edited = try await worker.process(DocumentCoreCommand(checkpoint: initial.checkpoint, text: "old", vector: initial.vector))
                try await persistence.append(meetingID: meetingID, update: edited.update, local: true)
            } else {
                edited = initial
            }
            try await persistence.receive(meetingID: meetingID, update: initial.checkpoint, generation: restoredGeneration, revision: 1, validate: { _ in })
            // A still-open editor's next delta depends on the earlier local insertion.
            let next = try await worker.process(DocumentCoreCommand(checkpoint: edited.checkpoint, text: "new", vector: edited.vector))
            try await persistence.append(meetingID: meetingID, update: next.update, local: true)
            let expected = pending ? "seed\nold\nnew" : "seed\nnew"
            #expect(try await persistence.materialize(meetingID: meetingID).projection.text == expected)
            try await queue.read { db in
                let record = try #require(try DocumentRecord.fetchOne(db, key: meetingID))
                #expect(record.generation == restoredGeneration)
                #expect(record.revision == 1)
                #expect(try DocumentUpdateRecord.filter(Column("pending") == true).fetchCount(db) == (pending ? 2 : 1))
            }
        }

        @Test func acknowledgedRecoveryStillProtectsItsLocalCopy() async throws {
            let (queue, workspaceID, meetingID) = try seed(server: true)
            try await queue.write { db in
                try DocumentRecoveryRecord(
                    id: .v7(),
                    meetingId: meetingID,
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
            try await persistence.receive(meetingID: meetingID, update: fixture.checkpoint, generation: generation, revision: 1, validate: { _ in })
            try await persistence.receive(
                meetingID: meetingID,
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
            for waiter in waiters { waiter.resume() }
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
