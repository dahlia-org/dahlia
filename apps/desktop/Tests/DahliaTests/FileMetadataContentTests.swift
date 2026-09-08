#if canImport(Testing)
    import DahliaMeetingAccess
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    extension TextContentTests {
        @Test(arguments: [false, true])
        func fileMetadataRetriesAfterCursorAdvanceAndDatabaseReopen(resident: Bool) async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID.v7().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("retry.sqlite").path
            let fixture = try textFixture(path: path)
            let file = try await fileMetadataFixture(fixture)
            if !resident {
                try await fixture.queue.write { db in
                    try db.execute(sql: "DELETE FROM file_text_bodies WHERE fileId = ?", arguments: [file.id])
                    try db.execute(sql: "UPDATE sync_content_state SET complete = 0, residentRevision = NULL WHERE entity = 'file'")
                }
            }
            let changeData = try file.changes(revision: 2)
            let failedProvider = provider(fixture) { request in
                #expect(request.url?.query?.contains("content=") != true)
                if request.url!.path.hasSuffix("/capabilities") { return (200, [:], Data(#"{"syncVersion":3}"#.utf8)) }
                if request.url!.path.hasSuffix("/changes") { return (200, [:], changeData) }
                #expect(request.url!.path.hasSuffix("/metadata"))
                return (503, [:], Data())
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            let connectionId = try await fixture.queue.read { try #require(try VaultRecord.fetchOne($0, key: fixture.vaultId)?.accountConnectionId) }
            let worker = await SyncWorker(dbQueue: fixture.queue, apiClient: failedProvider.client)
            try await worker.synchronizeForTransfer(vaultId: fixture.vaultId, connectionId: connectionId)
            await #expect(throws: TextContentError.unavailable) {
                try await failedProvider.ensure(entity: .file, id: file.id, dbQueue: fixture.queue, refresh: resident)
            }
            try fixture.queue.close()

            let reopened = try AppDatabaseManager(path: path).dbQueue
            defer { try? reopened.close() }
            try await reopened.read { db throws in
                #expect(try String.fetchOne(db, sql: "SELECT syncPullCursor FROM vaults") == "after")
                #expect(try TextContentAccess.cachedFileText(fileId: file.id, in: db)?.caption == (resident ? "old" : nil))
                #expect(try TextContentAccess.availability(entity: .file, id: file.id, in: db).revision == (resident ? 1 : nil))
                #expect(try String.fetchOne(db, sql: "SELECT fetchError FROM sync_content_state WHERE entity = 'file'") == "unavailable")
            }
            let body = try file.body(revision: 2)
            let calls = Mutex(0)
            let restarted = provider(fixture) { request in
                calls.withLock { $0 += 1 }
                #expect(request.url!.path == "/api/v1/files/\(file.id.uuidString.lowercased())/metadata")
                #expect(request.url!.query == nil)
                return (200, [:], body)
            }
            try await restarted.ensure(entity: .file, id: file.id, dbQueue: reopened, refresh: resident)
            try await restarted.ensure(entity: .file, id: file.id, dbQueue: reopened)
            #expect(calls.withLock { $0 } == 1)
            try await reopened.read { db throws in
                #expect(try TextContentAccess.fileText(fileId: file.id, in: db)?.caption == "new")
                #expect(try TextContentAccess.availability(entity: .file, id: file.id, in: db).revision == 2)
                #expect(try String.fetchOne(db, sql: "SELECT syncPullCursor FROM vaults") == "after")
            }
        }

        @Test(arguments: [false, true])
        func fileMetadataResynchronizesOnceWithoutMixingRevisions(changesAgain: Bool) async throws {
            let fixture = try textFixture()
            let file = try await fileMetadataFixture(fixture)
            let changes = try file.changes(revision: 2)
            let first = try file.body(revision: 2)
            let second = try file.body(revision: changesAgain ? 3 : 2)
            let calls = Mutex(0)
            let provider = provider(fixture) { request in
                if request.url!.path.hasSuffix("/capabilities") { return (200, [:], Data(#"{"syncVersion":3}"#.utf8)) }
                if request.url!.path.hasSuffix("/changes") { return (200, [:], changes) }
                let count = calls.withLock { $0 += 1
                    return $0
                }
                return (200, [:], count == 1 ? first : second)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            if changesAgain {
                await #expect(throws: TextContentError.changed) {
                    try await provider.ensure(entity: .file, id: file.id, dbQueue: fixture.queue, refresh: true)
                }
            } else {
                try await provider.ensure(entity: .file, id: file.id, dbQueue: fixture.queue, refresh: true)
            }
            #expect(calls.withLock { $0 } == 2)
            try await fixture.queue.read { db throws in
                #expect(try TextContentStore.source(entity: .file, id: file.id, in: db)?.revision == 2)
                #expect(try TextContentAccess.cachedFileText(fileId: file.id, in: db)?.caption == (changesAgain ? "old" : "new"))
                #expect(try TextContentAccess.availability(entity: .file, id: file.id, in: db).revision == (changesAgain ? 1 : 2))
            }
        }

        @Test(arguments: ["edit", "missing-field", "wrong-id", "wrong-vault", "checksum"])
        func fileMetadataRejectsInvalidOrLocallySupersededBodies(scenario: String) async throws {
            let fixture = try textFixture()
            let file = try await fileMetadataFixture(fixture)
            var json = file.record(revision: 1)
            json["metadata"] = ["ocr_text": "", "caption": "new"]
            if scenario == "missing-field" { json["metadata"] = ["ocr_text": ""] }
            if scenario == "wrong-id" { json["id"] = UUID.v7().uuidString }
            if scenario == "wrong-vault" { json["vaultId"] = UUID.v7().uuidString }
            if scenario == "checksum" { json["checksum"] = "SHA-256:" + String(repeating: "b", count: 64) }
            let body = try JSONSerialization.data(withJSONObject: json)
            let provider = provider(fixture) { request in
                if request.url!.path.hasSuffix("/capabilities") { return (200, [:], Data(#"{"syncVersion":3}"#.utf8)) }
                if request.url!.path.hasSuffix("/changes") { return (
                    200,
                    [:],
                    Data(#"{"items":[],"cursor":"before","highWaterCursor":"before","hasMore":false}"#.utf8)
                ) }
                if scenario == "edit" {
                    do {
                        try fixture.queue.write { db in
                            try FileTextBodyRecord(fileId: file.id, ocrText: nil, caption: "local edit").save(db)
                            try SyncTransactionRecorder.record(
                                vaultId: fixture.vaultId,
                                operations: [.init(entity: .file, action: .upsert, entityId: file.id)],
                                in: db
                            )
                        }
                    } catch {
                        Issue.record(error)
                        return (500, [:], Data())
                    }
                }
                return (200, [:], body)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            await #expect(throws: (any Error).self) {
                try await provider.ensure(entity: .file, id: file.id, dbQueue: fixture.queue, refresh: true)
            }
            try await fixture.queue.read { db throws in
                #expect(try TextContentAccess.cachedFileText(fileId: file.id, in: db)?.caption == (scenario == "edit" ? "local edit" : "old"))
                #expect(try SyncTransactionQueue.hasPending(vaultId: fixture.vaultId, in: db) == (scenario == "edit"))
                #expect(try TextContentStore.source(entity: .file, id: file.id, in: db)?.revision == 1)
            }
        }

        private struct FileMetadataFixture: Sendable {
            let id: UUID
            let vaultId: UUID
            let checksum = "SHA-256:" + String(repeating: "a", count: 64)

            func record(revision: Int) -> [String: Any] {
                [
                    "id": id.uuidString,
                    "vaultId": vaultId.uuidString,
                    "revision": revision,
                    "uri": "/Volumes/test/app/file",
                    "offset": 0,
                    "size": 1,
                    "content_type": "image/png",
                    "checksum": checksum,
                    "name": "Image",
                    "metadata": ["source": "screenshot"],
                    "createdAt": "2026-01-01T00:00:00Z",
                    "updatedAt": "2026-01-01T00:00:00Z",
                ]
            }

            func body(revision: Int) throws -> Data {
                var json = record(revision: revision)
                json["metadata"] = ["source": "screenshot", "ocr_text": "", "caption": "new"]
                return try JSONSerialization.data(withJSONObject: json)
            }

            func changes(revision: Int) throws -> Data {
                var json = record(revision: revision)
                json["contentOmitted"] = true
                json["contentPresent"] = true
                return try JSONSerialization.data(withJSONObject: [
                    "items": [[
                        "sequence": revision,
                        "entity": "file",
                        "entityId": id.uuidString,
                        "action": "upsert",
                        "revision": revision,
                        "record": json,
                    ]],
                    "cursor": "after", "highWaterCursor": "after", "hasMore": false,
                ])
            }
        }

        private func fileMetadataFixture(_ fixture: TextFixture) async throws -> FileMetadataFixture {
            let file = FileMetadataFixture(id: .v7(), vaultId: fixture.vaultId)
            try await fixture.queue.write { db in
                try FileRecord(
                    id: file.id,
                    vaultId: fixture.vaultId,
                    size: 1,
                    contentType: "image/png",
                    checksum: file.checksum,
                    name: "Image",
                    metadata: .init(source: .screenshot),
                    createdAt: .now,
                    updatedAt: .now
                )
                .insert(db)
                try FileTextBodyRecord(fileId: file.id, ocrText: nil, caption: "old").save(db)
                try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'file', ?, 1)", arguments: [fixture.vaultId, file.id])
                try db.execute(
                    sql: "INSERT INTO sync_content_state(vaultId, entity, entityId, residentRevision, complete) VALUES (?, 'file', ?, 1, 1)",
                    arguments: [fixture.vaultId, file.id]
                )
                try db.execute(sql: "UPDATE vaults SET syncPullCursor = 'before'")
            }
            return file
        }
    }
#endif
