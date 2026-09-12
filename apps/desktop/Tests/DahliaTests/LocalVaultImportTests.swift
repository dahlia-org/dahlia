#if canImport(Testing)
    import DahliaMeetingAccess
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct LocalVaultImportTests {
        @Test(arguments: ["admin", "editor"])
        func importsIntoANonemptyVaultAndTracksOnlyInitialWork(role: String) async throws {
            let fixture = try LocalImportFixture(role: role)
            defer { fixture.close() }
            let queue = fixture.database.dbQueue
            try await queue.write { db in _ = try fixture.commit(in: db) }
            let operationIDs = try await queue.read { try Set(UUID.fetchAll($0, sql: "SELECT operationId FROM local_vault_import_operations")) }
            #expect(operationIDs.count >= 7)
            try await queue.write { db throws in
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meeting.id)?.vaultId == fixture.target.id)
                #expect(try ProjectRecord.fetchOne(db, key: fixture.child.id)?.parentProjectId == fixture.root.id)
                #expect(try FileRecord.fetchOne(db, key: fixture.file.id)?.vaultId == fixture.target.id)
                #expect(try MeetingAttachmentRecord.fetchOne(db, key: fixture.attachment.id)?.fileId == fixture.file.id)
                #expect(try SummaryContent.fetchOne(db, key: fixture.meeting.id)?.document == "original summary")
                #expect(try String.fetchOne(
                    db,
                    sql: "SELECT text FROM transcript_segment_bodies WHERE segmentId = ?",
                    arguments: [fixture.segmentId]
                ) == "原文")
                #expect(try TranscriptSegmentRecord.fetchOne(db, key: fixture.segmentId)?.translatedText == "translation")
                #expect(try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)?.meetingId == fixture.meeting.id)
                #expect(try String.fetchOne(db, sql: "SELECT originalVaultPath FROM recording_audio_files") == fixture.source.path)
                #expect(try RecordingArchiveRecord.fetchOne(db, key: fixture.session.id)?.connectionId == fixture.connection.id)
                #expect(try VaultRecord.fetchOne(db, key: fixture.source.id)?.name == "Local settings")
                #expect(try VaultRecord.fetchOne(db, key: fixture.target.id)?.name == "Existing settings")
                #expect(try MeetingRecord.fetchOne(db, key: fixture.existing.id) != nil)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations WHERE entity = 'vault'") == 0)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
                var edited = fixture.meeting
                edited.vaultId = fixture.target.id
                edited.name = "Edited while importing"
                try edited.update(db)
                try SyncTransactionRecorder.record(vaultId: fixture.target.id, operations: [
                    SyncInitialSnapshotBuilder.meetingOperation(edited, action: .update, in: db),
                ], in: db)
                let recording = RecordingSessionRecord(
                    id: .v7(),
                    meetingId: fixture.existing.id,
                    startedAt: .now,
                    offsetSeconds: 0,
                    createdAt: .now,
                    updatedAt: .now
                )
                try recording.insert(db)
            }
            // Reopening keeps operation IDs and the fixed import completion set.
            try queue.close()
            let reopened = try AppDatabaseManager(path: fixture.path).dbQueue
            defer { try? reopened.close() }
            #expect(try await reopened
                .read { try Set(UUID.fetchAll($0, sql: "SELECT operationId FROM local_vault_import_operations")) } == operationIDs)
            while let transaction = try await SyncTransactionQueue.claim(dbQueue: reopened),
                  transaction.operations.contains(where: { operationIDs.contains($0.id) }) {
                let records = try transaction.operations.map { operation in
                    let value: JSONValue? = operation.entity == .meeting
                        ? try SyncJSON.decoder.decode(
                            JSONValue.self,
                            from: Data("{\"name\":\"Original\",\"createdAt\":\"2026-09-01T00:00:00Z\",\"updatedAt\":\"2026-09-01T00:00:00Z\"}".utf8)
                        ) : nil
                    return SyncTransactionResponse.Record(entity: operation.entity, id: operation.entityId, revision: 1, record: value)
                }
                try await SyncTransactionQueue.complete(
                    transaction,
                    response: .init(id: transaction.id, status: "committed", cursor: "imported", records: records),
                    dbQueue: reopened
                )
            }
            try await reopened.read { db throws in
                #expect(try LocalVaultImportRecord.fetchOne(db)?.completedAt != nil)
                #expect(try SyncTransactionQueue.hasPending(vaultId: fixture.target.id, in: db))
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meeting.id)?.name == "Edited while importing")
                #expect(try RecordingSessionRecord.hasActiveRecording(vaultId: fixture.target.id, in: db))
                #expect(try LocalVaultImportRecord.fetchOne(db)?.backupPath == "/tmp/preserved-backup.dahlia")
            }
        }

        @Test(arguments: ["collision", "pending", "blocked", "recording", "viewer", "unknown", "metadata", "connection", "rollback"])
        func failedPreflightAndCommitPreserveTheLocalWorkingCopy(reason: String) throws {
            let fixture = try LocalImportFixture(role: "editor")
            defer { fixture.close() }
            try fixture.database.dbQueue.write { db in
                if reason == "pending" || reason == "blocked" {
                    try SyncTransactionRecorder.record(
                        vaultId: fixture.target.id,
                        operations: [SyncInitialSnapshotBuilder.meetingOperation(fixture.existing, action: .update, in: db)],
                        in: db
                    )
                    if reason == "blocked" { try db.execute(sql: "UPDATE sync_transactions SET blockedReason = 'conflict'") }
                } else if reason == "recording" {
                    try db.execute(sql: "UPDATE recording_sessions SET endedAt = NULL WHERE id = ?", arguments: [fixture.session.id])
                } else if reason == "viewer" || reason == "unknown" {
                    try db.execute(
                        sql: "UPDATE vaults SET syncRole = ? WHERE id = ?",
                        arguments: [reason == "viewer" ? "viewer" : nil, fixture.target.id]
                    )
                } else if reason == "metadata" {
                    try db.execute(sql: "UPDATE vaults SET syncPullCursor = NULL WHERE id = ?", arguments: [fixture.target.id])
                } else if reason == "connection" {
                    try db.execute(sql: "UPDATE vaults SET syncConfirmedConnectionId = NULL WHERE id = ?", arguments: [fixture.target.id])
                } else if reason == "rollback" {
                    try db
                        .execute(
                            sql: "CREATE TRIGGER reject_import BEFORE INSERT ON sync_operations BEGIN SELECT RAISE(ABORT, 'injected failure'); END"
                        )
                }
            }
            #expect(throws: (any Error).self) {
                try fixture.database.dbQueue.write { db in
                    _ = try fixture.commit(collision: reason == "collision", in: db)
                }
            }
            try fixture.database.dbQueue.read { db throws in
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meeting.id)?.vaultId == fixture.source.id)
                #expect(try FileRecord.fetchOne(db, key: fixture.file.id)?.vaultId == fixture.source.id)
                #expect(try RecordingArchiveRecord.fetchOne(db, key: fixture.session.id)?.connectionId == nil)
                #expect(try LocalVaultImportRecord.fetchCount(db) == 0)
                #expect(try VaultRecord.fetchCount(db) == 2)
            }
        }

        @Test
        func preparesARealBackupAndImageBeforeCommittingTheImport() async throws {
            let fixture = try LocalImportFixture(role: "editor")
            defer { fixture.close() }
            let queue = fixture.database.dbQueue
            let bytes = try #require(TestScreenshotImageFixture.data(using: .png))
            try await queue.write { db in
                try db.execute(
                    sql: "UPDATE files SET size = ?, checksum = ? WHERE id = ?",
                    arguments: [bytes.count, "SHA-256:" + ScreenshotRemoteReference.digest(bytes), fixture.file.id]
                )
                try db.execute(sql: "INSERT INTO file_migration_content(fileId, imageData) VALUES (?, ?)", arguments: [fixture.file.id, bytes])
            }
            let files = try ScreenshotFileStore(directory: fixture.directory.appending(path: "FileStore"))
            let screenshots = ScreenshotContentProvider(cache: files)
            let vault: [String: Any] = try [
                "vaultId": fixture.target.id.uuidString,
                "organizationId": #require(fixture.target.organizationId?.uuidString),
                "role": "editor",
                "name": "Existing settings",
                "revision": 1,
                "createdAt": "2026-09-01T00:00:00Z",
                "updatedAt": "2026-09-01T00:00:00Z",
            ]
            let meeting: [String: Any] = [
                "meetingId": fixture.existing.id.uuidString,
                "vaultId": fixture.target.id.uuidString,
                "name": "Existing",
                "description": "",
                "projectId": NSNull(),
                "status": "READY",
                "revision": 1,
                "duration": NSNull(),
                "recordingStartedAt": NSNull(),
                "createdAt": "2026-09-01T00:00:00Z",
                "updatedAt": "2026-09-01T00:00:00Z",
            ]
            let listing = try JSONSerialization.data(withJSONObject: ["items": [vault], "nextCursor": NSNull()])
            let snapshot = try JSONSerialization.data(withJSONObject: [
                "items": [
                    ["entity": "vault", "id": fixture.target.id.uuidString, "revision": 1, "record": vault],
                    ["entity": "meeting", "id": fixture.existing.id.uuidString, "revision": 1, "record": meeting],
                ],
                "startCursor": "complete", "nextCursor": NSNull(),
            ])
            ImageURLProtocol.register(origin: fixture.connection.origin) { request in
                switch request.url!.lastPathComponent {
                case "capabilities": (200, [:], Data(#"{"sync":{"version":5}}"#.utf8))
                case "vaults": (200, [:], listing)
                case "snapshot": (200, [:], snapshot)
                case "changes": (200, [:], Data(#"{"items":[],"cursor":"complete","highWaterCursor":"complete","hasMore":false}"#.utf8))
                default: (404, [:], Data())
                }
            }
            defer { ImageURLProtocol.remove(origin: fixture.connection.origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let api = SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" })
            let destination = try CloudVaultRecord(
                vaultId: fixture.target.id,
                connectionId: fixture.connection.id,
                organizationId: #require(fixture.target.organizationId),
                name: "Existing",
                createdAt: .now,
                revision: 1,
                role: "editor"
            )
            _ = try await LocalVaultImport.run(
                sourceId: fixture.source.id,
                destination: destination,
                dbQueue: queue,
                backup: BackupService(dbQueue: queue, applicationSupportURL: fixture.directory),
                api: api,
                screenshots: screenshots
            )
            let record = try #require(try await queue.read { try LocalVaultImportRecord.fetchOne($0) })
            #expect(FileManager.default.fileExists(atPath: record.backupPath))
            #expect(try await screenshots.fileContent(id: fixture.file.id, dbQueue: queue).data == bytes)
            #expect(try await queue.read { try MeetingRecord.fetchOne($0, key: fixture.meeting.id)?.vaultId } == fixture.target.id)
        }

        @Test(arguments: [false, true])
        func laterDeletionCompletesTheFixedAudioOperationAfterItsReplacementReceipt(deletesHierarchy: Bool) async throws {
            let fixture = try LocalImportFixture(role: "editor")
            defer { fixture.close() }
            let queue = fixture.database.dbQueue
            try await queue.write { db in
                _ = try fixture.commit(in: db)
                if !deletesHierarchy {
                    try SyncTransactionRecorder.record(vaultId: fixture.target.id, operations: [
                        .init(entity: .meeting, action: .delete, entityId: fixture.meeting.id),
                    ], in: db)
                    try MeetingRecord.deleteOne(db, key: fixture.meeting.id)
                }
            }
            if deletesHierarchy {
                let service = ProjectWorkspaceService(
                    repository: MeetingRepository(dbQueue: queue), vault: fixture.target,
                    managedAudioRootURL: fixture.directory.appending(path: "managed-audio")
                )
                try await service.deleteProjectHierarchy(id: fixture.root.id, meetingDisposition: .deleteMeetings)
            }
            try await queue.read { db throws in
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM local_vault_import_operations WHERE replacementOperationId IS NOT NULL") == 1)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations WHERE entity = 'recording'") == 0)
            }
            while let transaction = try await SyncTransactionQueue.claim(dbQueue: queue) {
                if transaction.operations.contains(where: { $0.action == .delete }) {
                    #expect(try await queue.read { try LocalVaultImportRecord.fetchOne($0)?.completedAt } == nil)
                }
                try await SyncTransactionQueue.complete(transaction, response: .init(
                    id: transaction.id,
                    status: "committed",
                    cursor: "done",
                    records: transaction.operations.map { .init(entity: $0.entity, id: $0.entityId, revision: 1, record: nil) }
                ), dbQueue: queue)
            }
            #expect(try await queue.read { try LocalVaultImportRecord.fetchOne($0)?.completedAt } != nil)
        }

        @Test(arguments: ["conflict", "authorization"])
        func partialCommitStopsWithoutDiscardingTheRemainingImport(reason: String) async throws {
            let fixture = try LocalImportFixture(role: "editor")
            defer { fixture.close() }
            try await fixture.database.dbQueue.write { db in _ = try fixture.commit(in: db) }
            let first = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.database.dbQueue))
            let records = first.operations.map { SyncTransactionResponse.Record(entity: $0.entity, id: $0.entityId, revision: 1, record: nil) }
            try await SyncTransactionQueue.complete(first, response: .init(id: first.id, status: "committed", cursor: "partial", records: records),
                                                    dbQueue: fixture.database.dbQueue)
            let next = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.database.dbQueue))
            try await SyncTransactionQueue.block(
                next,
                reason: reason == "conflict" ? .conflict : .authorization,
                response: Data("{}".utf8),
                dbQueue: fixture.database.dbQueue
            )
            #expect(try await SyncTransactionQueue.claim(dbQueue: fixture.database.dbQueue) == nil)
            try await fixture.database.dbQueue.read { db throws in
                #expect(try LocalVaultImportRecord.fetchOne(db)?.completedAt == nil)
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meeting.id)?.vaultId == fixture.target.id)
                #expect(try VaultRecord.fetchOne(db, key: fixture.source.id) != nil)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM local_vault_import_operations WHERE completedAt IS NULL")! > 0)
            }
        }
    }

    @MainActor
    private struct LocalImportFixture {
        let directory: URL
        let database: AppDatabaseManager
        let connection: DahliaAccountConnectionRecord
        let source: VaultRecord
        let target: VaultRecord
        let root: ProjectRecord
        let child: ProjectRecord
        let meeting: MeetingRecord
        let existing: MeetingRecord
        let session: RecordingSessionRecord
        let file: FileRecord
        let attachment: MeetingAttachmentRecord
        let segmentId = UUID.v7()
        var path: String { directory.appending(path: "import.sqlite").path }

        init(role: String) throws {
            directory = FileManager.default.temporaryDirectory.appending(path: UUID.v7().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            database = try AppDatabaseManager(path: directory.appending(path: "import.sqlite").path)
            connection = .init(id: .v7(), origin: "https://\(UUID.v7().uuidString.lowercased()).invalid", clientID: "test", createdAt: .now)
            source = .init(id: .v7(), path: "/tmp/local-import-source", name: "Local settings", createdAt: .now, lastOpenedAt: .now)
            target = .init(
                id: .v7(),
                path: nil,
                name: "Existing settings",
                createdAt: .now,
                lastOpenedAt: .now,
                accountConnectionId: connection.id,
                organizationId: .v7(),
                syncRole: role,
                syncConfirmedConnectionId: connection.id,
                syncPullCursor: "complete"
            )
            root = .init(id: .v7(), vaultId: source.id, parentProjectId: nil, name: "Root", createdAt: .now, projectType: .undefined)
            child = .init(id: .v7(), vaultId: source.id, parentProjectId: root.id, name: "Child", createdAt: .now, projectType: nil)
            meeting = .init(id: .v7(), vaultId: source.id, projectId: child.id, name: "Original", createdAt: .now, updatedAt: .now)
            existing = .init(id: .v7(), vaultId: target.id, projectId: nil, name: "Existing", createdAt: .now, updatedAt: .now)
            session = .init(
                id: .v7(),
                meetingId: meeting.id,
                startedAt: .now,
                endedAt: .now,
                duration: 1,
                offsetSeconds: 0,
                createdAt: .now,
                updatedAt: .now,
                transcriptionMode: .batch
            )
            file = .init(
                id: .v7(),
                vaultId: source.id,
                size: 1,
                contentType: "image/png",
                checksum: "SHA-256:" + String(repeating: "a", count: 64),
                name: "image.png",
                metadata: .init(source: .screenshot),
                createdAt: .now,
                updatedAt: .now
            )
            attachment = .init(id: .v7(), meetingId: meeting.id, fileId: file.id, capturedAt: .now, sessionId: session.id, createdAt: .now)
            try database.dbQueue.write { db in
                try connection.insert(db)
                try source.insert(db)
                try target.insert(db)
                try root.insert(db)
                try child.insert(db)
                try meeting.insert(db)
                try existing.insert(db)
                try session.insert(db)
                try TranscriptRecord(meetingId: meeting.id, info: .init(
                    id: .v7(),
                    startedAt: .now,
                    endedAt: .now,
                    metadata: .init(provider: "apple", model: "apple-speech-live", runs: [])
                ))
                .insert(db)
                try TranscriptSegmentRecord(
                    id: segmentId,
                    meetingId: meeting.id,
                    sessionId: session.id,
                    startTime: .now,
                    endTime: .now,
                    translatedText: "translation"
                ).insert(db)
                try TranscriptSegmentBodyRecord(segmentId: segmentId, text: "原文").insert(db)
                try SummaryContent(meetingId: meeting.id, title: "Summary", document: "original summary", createdAt: .now).insert(db)
                try file.insert(db)
                try db.execute(sql: "INSERT INTO file_text_bodies(fileId, ocrText, caption) VALUES (?, 'OCR', 'Caption')", arguments: [file.id])
                try attachment.insert(db)
                let prepared = RecordingArchiveEncoder.Prepared(
                    relativePath: "archives/kept.m4a",
                    size: 1,
                    checksum: "SHA-256:" + String(repeating: "b", count: 64),
                    manifest: .init(sampleRate: 16000, frameCount: 1, ranges: [])
                )
                try RecordingArchiveRecord(
                    sessionId: session.id,
                    meetingId: meeting.id,
                    vaultId: source.id,
                    preparedJSON: String(decoding: SyncJSON.encoder.encode(["mic": prepared]), as: UTF8.self),
                    state: "saved"
                )
                .insert(db)
                try db.execute(sql: """
                INSERT INTO recording_audio_files(id, recordingSessionId, source, relativePath, storageLocation, sampleRate, channelCount, createdAt, updatedAt)
                VALUES (?, ?, 'mic', 'audio.caf', 'vault', 16000, 1, ?, ?)
                """, arguments: [UUID.v7(), session.id, Date.now, Date.now])
            }
        }

        nonisolated func commit(collision: Bool = false, in db: Database) throws -> VaultRecord {
            let destination = CloudVaultRecord(
                vaultId: target.id,
                connectionId: connection.id,
                organizationId: target.organizationId!,
                name: target.name,
                createdAt: target.createdAt,
                revision: 1,
                role: target.syncRole!
            )
            let reference = ScreenshotRemoteReference(
                origin: connection.origin,
                accountConnectionId: connection.id,
                fileId: file.id,
                contentHash: file.contentHash
            )
            return try LocalVaultImport.commit(
                sourceId: source.id,
                destination: destination,
                snapshot: .init(ids: [.meeting: collision ? [meeting.id, existing.id] : [existing.id]]),
                files: [.init(
                    file: file,
                    reference: reference.jsonString()
                )],
                backupPath: "/tmp/preserved-backup.dahlia",
                in: db
            )
        }

        func close() { try? database.dbQueue.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }
#endif
