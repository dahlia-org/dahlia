#if canImport(Testing)
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    struct DocumentPersistenceTests {
        private struct SchemaFixture: Decodable {
            struct LegacySchema: Decodable { let checkpoint: String
                let append: String
            }

            let checkpoint: String
            let deletionUpdate: String
            let retainedDeletionUpdate: String
            let lateUpdate: String
            let purgedCheckpoint: String
            let v1: LegacySchema
        }

        private func schemaFixture() throws -> SchemaFixture {
            let url = try #require(Bundle.module.url(forResource: "documents", withExtension: "json", subdirectory: "Fixtures"))
            return try JSONDecoder().decode(SchemaFixture.self, from: Data(contentsOf: url))
        }

        @Test func recoveryPagesBoundPreviewAndReadFullTextExplicitly() async throws {
            let (queue, workspaceID, meetingID) = try seed()
            let documentID = UUID.v7()
            let fullText = String(repeating: "文", count: 3000)
            let blocks = try String(
                decoding: JSONEncoder().encode([DocumentBlock(id: "paragraph", type: "paragraph", text: fullText)]),
                as: UTF8.self
            )
            try await queue.write { db in
                try DocumentRecord(
                    id: documentID,
                    workspaceId: workspaceID,
                    meetingId: meetingID,
                    checkpoint: "AAA=",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                for _ in 0 ..< 205 {
                    try DocumentRecoveryRecord(
                        id: .v7(),
                        documentId: documentID,
                        blocksJSON: blocks,
                        reason: "deleted",
                        pending: false,
                        createdAt: .now
                    ).insert(db)
                }
            }
            let persistence = DocumentPersistence(dbQueue: queue)
            let first = try await persistence.recoveryPage(meetingID: meetingID)
            #expect(first.records.count == 100 && first.previews.values.allSatisfy { $0.count == 2000 })
            let id = try #require(first.records.first?.id)
            #expect(try await persistence.recoveryText(id: id) == fullText)
            let second = try await persistence.recoveryPage(meetingID: meetingID, before: first.next)
            #expect(second.records.count == 100 && Set(first.records.map(\.id)).isDisjoint(with: second.records.map(\.id)))
            let last = try await persistence.recoveryPage(meetingID: meetingID, before: second.next)
            #expect(last.records.count == 5 && last.next == nil)
        }

        @Test func editorRecoveryCommitsWithItsUpdateAndSurvivesRestart() async throws {
            let (queue, workspaceID, meetingID) = try seed()
            let fixture = try schemaFixture()
            try await queue.write { db in
                try DocumentRecord(
                    id: .v7(),
                    workspaceId: workspaceID,
                    meetingId: meetingID,
                    checkpoint: fixture.purgedCheckpoint,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                try db
                    .execute(
                        sql: "CREATE TRIGGER fail_recovery BEFORE INSERT ON document_recoveries BEGIN SELECT RAISE(ABORT, 'fixture disk error'); END"
                    )
            }
            let persistence = DocumentPersistence(dbQueue: queue)
            let recovery = #"[{"id":"block-1","type":"paragraph","text":"日確定本語"}]"#
            await #expect(throws: (any Error).self) {
                try await persistence.append(meetingID: meetingID, update: fixture.lateUpdate, local: true, recovery: recovery)
            }
            #expect(try await queue.read { try DocumentUpdateRecord.fetchCount($0) } == 0)
            #expect(try await queue.read { try DocumentRecoveryRecord.fetchCount($0) } == 0)
            try await queue.write { try $0.execute(sql: "DROP TRIGGER fail_recovery") }
            try await persistence.append(meetingID: meetingID, update: fixture.lateUpdate, local: true, recovery: recovery)
            let restarted = DocumentPersistence(dbQueue: queue)
            let (records, text) = try await restarted.recoveries(meetingID: meetingID)
            let record = try #require(records.first)
            #expect(records.count == 1 && !record.pending && record.reason == "concurrent_delete")
            #expect(text[record.id] == "日確定本語")
            #expect(try await restarted.materialize(meetingID: meetingID).projection.text == "# literal\r\n")
            #expect(try await queue.read { try DocumentUpdateRecord.filter(Column("pending") == true).fetchCount($0) } == 0)
        }

        @Test(arguments: [false, true]) func localRecoveryDoesNotRepeatAfterUnrelatedEdits(recording: Bool) async throws {
            let (queue, workspaceID, meetingID) = try seed()
            let fixture = try schemaFixture(), documentID = UUID.v7()
            try await queue.write { db in
                try DocumentRecord(
                    id: documentID, workspaceId: workspaceID, meetingId: meetingID,
                    checkpoint: fixture.checkpoint, createdAt: .now, updatedAt: .now
                ).insert(db)
                if recording {
                    try RecordingSessionRecord(
                        id: .v7(), meetingId: meetingID, startedAt: .now,
                        offsetSeconds: 0, createdAt: .now, updatedAt: .now
                    ).insert(db)
                }
            }
            let persistence = DocumentPersistence(dbQueue: queue)
            try await persistence.append(meetingID: meetingID, update: fixture.retainedDeletionUpdate, local: true)
            #expect(try await persistence.materialize(meetingID: meetingID).purged == false)
            #expect(try await persistence.recoveries(meetingID: meetingID).0.count == 1)
            try await persistence.insertRecoveredText(meetingID: meetingID, text: "Unrelated edit")

            let restarted = DocumentPersistence(dbQueue: queue)
            #expect(try await restarted.materialize(documentID: documentID).projection.text.contains("Unrelated edit"))
            #expect(try await restarted.recoveries(meetingID: meetingID).0.count == 1)
            // A genuinely changed hidden body must still produce a new recovery after compaction.
            try await restarted.append(meetingID: meetingID, update: fixture.lateUpdate, local: true)
            _ = try await restarted.materialize(meetingID: meetingID)
            let (records, text) = try await restarted.recoveries(meetingID: meetingID)
            #expect(records.count == 2)
            #expect(text.values.contains { $0.contains("offline") })
            try await restarted.insertRecoveredText(meetingID: meetingID, text: "Another unrelated edit")
            _ = try await restarted.materialize(documentID: documentID)
            #expect(try await restarted.recoveries(meetingID: meetingID).0.count == 2)
        }

        @Test func onlyLocalOwnerPurgesExpiredBlocks() async throws {
            let (queue, workspaceID, meetingID) = try seed()
            let fixture = try schemaFixture()
            try await queue.write { db in
                try DocumentRecord(
                    id: .v7(),
                    workspaceId: workspaceID,
                    meetingId: meetingID,
                    checkpoint: fixture.deletionUpdate,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            let result = try await DocumentPersistence(dbQueue: queue).materialize(meetingID: meetingID, compact: true)
            #expect(result.purged == true)
            #expect(result.projection.text == "# literal\r\n")
            #expect(try await queue.read { try DocumentRecord.notes(in: $0, meetingID: meetingID)?.checkpoint } == result.checkpoint)
        }

        private func seed() throws -> (any DatabaseWriter, UUID, UUID) {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let workspaceID = UUID.v7(), meetingID = UUID.v7()
            try queue.write { db throws in
                let workspace = WorkspaceRecord(id: workspaceID, name: "Notes", createdAt: .now, lastOpenedAt: .now)
                try workspace.insertIntoLegacySchema(db)
                try MeetingRecord(id: meetingID, workspaceId: workspaceID, name: "Meeting", createdAt: .now, updatedAt: .now).insert(db)
            }
            return (queue, workspaceID, meetingID)
        }

        private func remoteDocument(_ queue: any DatabaseWriter, meetingID: UUID) async throws -> DocumentRecord {
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

        @Test(arguments: [false, true])
        func v47UpgradePreservesDocumentRelationshipsAndBytes(predatesRecordingRecovery: Bool) throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try DevelopmentSchemaHistory.migrator.migrate(queue, upTo: "v47_documents")
            if predatesRecordingRecovery {
                // Disposable fixture for a Documents build made before the independent main migration.
                try queue.write { db in
                    try db.execute(sql: "DROP TABLE orphaned_recording_recoveries")
                    try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v47_orphanedRecordingRecoveryState'")
                }
            }
            let workspaceID = UUID.v7(), meetingID = UUID.v7(), recoveryID = UUID.v7(), copyID = UUID.v7(), date = Date()
            try queue.write { db in
                try WorkspaceRecord(id: workspaceID, name: "Old", createdAt: date, lastOpenedAt: date).insertIntoLegacySchema(db)
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

        @Test func independentDocumentOwnershipAndMeetingNotesUniqueness() async throws {
            let (queue, workspaceID, meetingID) = try seed()
            let other = UUID.v7(), generalID = UUID.v7()
            let persistence = DocumentPersistence(dbQueue: queue)
            let state = try await persistence.legacyImport(text: "general")
            try await queue.write { db in
                try WorkspaceRecord(id: other, name: "Other", createdAt: .now, lastOpenedAt: .now).insertIntoLegacySchema(db)
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
                try db.execute(
                    sql: "INSERT INTO workspace_relocation_scope(source_workspace_id, destination_workspace_id) VALUES (?, ?)",
                    arguments: [workspaceID, other]
                )
                try db.execute(sql: "UPDATE meetings SET workspace_id = ? WHERE id = ?", arguments: [other, meetingID])
                #expect(try DocumentRecord.notes(in: db, meetingID: meetingID)?.workspaceId == other)
                try MeetingRecord.deleteOne(db, key: meetingID)
                #expect(try DocumentRecord.fetchCount(db) == 1)
            }
            #expect(try await persistence.materialize(documentID: generalID).projection.text == "general")
        }

        @Test func failedMigrationRollsBackWithoutChangingLegacyRows() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v46_workspacePersonalUser")
            try queue.write { try $0.execute(sql: "CREATE TABLE document_updates (sentinel TEXT)") }
            #expect(throws: (any Error).self) { try AppDatabaseManager.migrator.migrate(queue) }
            try queue.read { db throws in
                #expect(try !db.tableExists("documents"))
                #expect(try db.columns(in: "document_updates").map(\.name) == ["sentinel"])
                #expect(try !String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations").contains("v54_documentsSyncAndBackgroundJobs"))
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
                try workspace.insertIntoLegacySchema(db)
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
            try await queue.write { try workspace.insertIntoLegacySchema($0) }
            let resolved = Mutex(false)
            let model = DocumentEditorModel(
                dbQueue: queue, meetingID: nil, orphan: .init(workspaceID: workspace.id, meetingID: draftID, name: "Draft"),
                resolveMeeting: { resolved.withLock { $0 } ? draftID : nil }
            )
            await model.load()
            let core = DocumentCoreWorker()
            defer { core.stop() }
            let first = try await core.process(DocumentCoreCommand(text: "Before resolution"))
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
                try workspace.insertIntoLegacySchema(db)
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
            try await model.accept(
                DocumentPersistence(dbQueue: queue).legacyImport(text: "unmaterialized draft input"),
                recovery: #"[{"id":"purged","type":"paragraph","text":"日確定本語"}]"#
            )
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
            #expect(try await DocumentPersistence(dbQueue: queue).archives(workspaceID: workspace.id).first?.2.contains("日確定本語") == true)
        }

        @Test func editAfterItsMeetingAndWorkspaceAreDeletedIsDroppedWithoutBlockingDrain() async throws {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let workspace = WorkspaceRecord(id: .v7(), name: "Deleted", createdAt: .now, lastOpenedAt: .now)
            let meetingID = UUID.v7()
            try await queue.write { db in
                try workspace.insertIntoLegacySchema(db)
                try MeetingRecord(id: meetingID, workspaceId: workspace.id, name: "Deleted", createdAt: .now, updatedAt: .now).insert(db)
            }
            let model = DocumentEditorModel(dbQueue: queue, meetingID: meetingID, resolveMeeting: { nil })
            await model.load()
            #expect(model.ready)
            _ = try await queue.write { try WorkspaceRecord.deleteOne($0, key: workspace.id) }
            try await model.accept(DocumentPersistence(dbQueue: queue).legacyImport(text: "late edit"))
            try await model.finishLocalSaves()
            #expect(model.error.isEmpty)
            model.stop()
            try await DocumentEditorModel.finishLocalSaves(dbQueue: queue)
        }

        @Test func failedEditorDrainRetriesAfterStorageRecoveryAndFencesParentRemoval() async throws {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let workspace = WorkspaceRecord(id: .v7(), name: "Test", createdAt: .now, lastOpenedAt: .now)
            let meetingID = UUID.v7()
            try await queue.write { db in
                try workspace.insertIntoLegacySchema(db)
                try MeetingRecord(id: meetingID, workspaceId: workspace.id, name: "Test", createdAt: .now, updatedAt: .now).insert(db)
                try db
                    .execute(
                        sql: "CREATE TRIGGER fail_document_save BEFORE INSERT ON document_updates BEGIN SELECT RAISE(ABORT, 'fixture disk error'); END"
                    )
            }
            let model = DocumentEditorModel(dbQueue: queue, meetingID: meetingID, resolveMeeting: { nil })
            await model.load()
            try await model.accept(
                DocumentPersistence(dbQueue: queue).legacyImport(text: "retained after failure"),
                recovery: #"[{"id":"purged","type":"paragraph","text":"日確定本語"}]"#
            )
            await #expect(throws: (any Error).self) { try await model.finishLocalSaves() }
            model.stop()
            #expect(DocumentEditorModel.reserveRemoval(meetingIDs: [meetingID], dbQueue: queue) == nil)
            try await queue.write { try $0.execute(sql: "DROP TRIGGER fail_document_save") }
            try await DocumentEditorModel.finishLocalSaves(dbQueue: queue)
            #expect(try await DocumentPersistence(dbQueue: queue).materialize(meetingID: meetingID).projection.text == "retained after failure")
            #expect(try await DocumentPersistence(dbQueue: queue).recoveries(meetingID: meetingID).1.values.contains("日確定本語"))
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

    private actor DocumentSendWindow {
        let entered: AsyncStream<Bool>
        private let events: AsyncStream<Bool>.Continuation
        private var pending: CheckedContinuation<Void, Never>?
        private(set) var starts = 0
        init() { (entered, events) = AsyncStream.makeStream() }
        func wait() async {
            await withCheckedContinuation { continuation in
                pending = continuation
                starts += 1
                events.yield(true)
            }
        }

        func release() { pending?.resume()
            pending = nil
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
