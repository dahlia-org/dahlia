#if canImport(Testing)
    import DahliaMeetingAccess
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    @MainActor
    struct ScreenshotContentTests {
        @Test
        func missingSnapshotOriginalDoesNotStarveOtherVaultsAndCanRetry() async throws {
            let missing = try ScreenshotContentFixture()
            let pending = try ScreenshotContentFixture(dbQueue: missing.dbQueue)
            let queued = try ScreenshotContentFixture(dbQueue: missing.dbQueue)
            try await missing.makeRemoteOnly()
            try await missing.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE vaults SET syncConfirmedConnectionId = NULL WHERE id IN (?, ?)",
                    arguments: [missing.vaultId, pending.vaultId]
                )
                try SyncTransactionRecorder.record(vaultId: queued.vaultId, operations: [
                    SyncOperationDraft(entity: .meeting, action: .update, entityId: queued.meetingId),
                ], in: db)
            }
            let available = Mutex(false)
            let provider = makeProvider(fixture: missing) { _ in
                (available.withLock { $0 } ? 200 : 404, ["content-type": "image/png"], missing.bytes)
            }
            defer { ImageURLProtocol.remove(origin: missing.source.origin) }
            // Explicit recovery still reports the missing original to its caller.
            await #expect(throws: ScreenshotContentError.deleted) {
                try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: missing.dbQueue, screenshotContent: provider)
            }
            let failures = Mutex(0)
            try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: missing.dbQueue, screenshotContent: provider) { _ in
                failures.withLock { $0 += 1 }
            }
            #expect(failures.withLock { $0 } == 1)
            let transaction = try #require(try await SyncTransactionQueue.claim(dbQueue: missing.dbQueue))
            #expect(transaction.vaultId == queued.vaultId)
            try await missing.dbQueue.read { db throws in
                #expect(try VaultRecord.fetchOne(db, key: pending.vaultId)?.syncConfirmedConnectionId == pending.connectionId)
                #expect(try VaultRecord.fetchOne(db, key: missing.vaultId)?.syncConfirmedConnectionId == nil)
                #expect(try MeetingScreenshotRecord.fetchOne(db, key: missing.screenshotId)?.remoteSource == missing.source)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions WHERE vaultId = ?", arguments: [missing.vaultId]) == 0)
            }
            available.withLock { $0 = true }
            try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: missing.dbQueue, screenshotContent: provider)
            #expect(try await missing.storedBytes() == nil)
            #expect(try await provider.content(id: missing.screenshotId, dbQueue: missing.dbQueue).data == missing.bytes)
            #expect(try await missing.dbQueue.read { try VaultRecord.fetchOne($0, key: missing.vaultId)?.syncConfirmedConnectionId } == missing
                .connectionId)
        }

        @Test
        func gridRequestsThumbnailWhileLargerImagesRequestOriginal() async throws {
            let fixture = try ScreenshotContentFixture()
            #expect(ScreenshotVariant.thumbnail.rawValue == "thumb_360")
            #expect(ScreenshotVariant(rawValue: "thumbnail") == nil)
            #expect(fixture.source.cacheKey(variant: .thumbnail).hasSuffix("variants/v1/thumb_360.webp"))
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let variants = Mutex<[String]>([])
            let provider = try makeProvider(fixture: fixture, cache: ScreenshotFileStore(directory: root)) { request in
                let variant = request.url!.path.hasSuffix("variants/thumb_360") ? "thumb_360" : "original"
                variants.withLock { $0.append(variant) }
                return (200, [
                    "content-type": "image/png",
                    "x-dahlia-image-variant": variant,
                    "x-dahlia-original-sha256": fixture.source.contentHash,
                ], fixture.bytes)
            }
            defer { ImageURLProtocol.remove(origin: fixture.source.origin) }
            try await fixture.makeRemoteOnly()
            await provider.configure(dbQueue: fixture.dbQueue)
            let loader = ScreenshotImageLoader(contentProvider: provider, cacheableDecoder: { data, _ in
                #expect(data == fixture.bytes)
                return nil
            })
            _ = await loader.image(screenshotID: fixture.screenshotId, data: nil, maxPixelSize: ScreenshotGridSizing.maximumThumbnailPixelSize)
            _ = await loader.image(screenshotID: fixture.screenshotId, data: nil, maxPixelSize: 1200)
            #expect(variants.withLock { $0 } == ["thumb_360", "original"])
        }

        @Test(arguments: [false, true])
        func reapplyingMetadataOrDeletionDoesNotFetchUnneededOriginals(deletesScreenshot: Bool) async throws {
            let fixture = try ScreenshotContentFixture()
            try await fixture.makeRemoteOnly()
            try await fixture.confirm()
            let calls = Mutex(0)
            let provider = makeProvider(fixture: fixture) { _ in
                calls.withLock { $0 += 1 }
                return (404, [:], Data())
            }
            defer { ImageURLProtocol.remove(origin: fixture.source.origin) }
            let entity: SyncEntity = deletesScreenshot ? .meetingFile : .meeting
            let entityId = deletesScreenshot ? fixture.screenshotId : fixture.meetingId
            try await fixture.dbQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision) VALUES (?, 'meeting', ?, 1)",
                    arguments: [fixture.vaultId, fixture.meetingId]
                )
                try SyncTransactionRecorder.record(vaultId: fixture.vaultId, operations: [
                    SyncOperationDraft(entity: entity, action: deletesScreenshot ? .delete : .update, entityId: entityId),
                ], in: db)
            }
            let transaction = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.dbQueue))
            let revision = deletesScreenshot ? "null" : "2"
            try await SyncTransactionQueue.block(transaction, reason: .conflict, response: Data("""
            {"conflicts":[{"entity":"\(entity.rawValue)","id":"\(entityId)","serverRevision":\(revision)}]}
            """.utf8), dbQueue: fixture.dbQueue)

            try await SyncTransactionQueue.reapplyLocalVersion(vaultId: fixture.vaultId, dbQueue: fixture.dbQueue, screenshotContent: provider)

            #expect(calls.withLock { $0 } == 0)
            #expect(try await fixture.storedBytes() == nil)
            let retried = try await SyncTransactionQueue.claim(dbQueue: fixture.dbQueue)
            if deletesScreenshot {
                #expect(retried == nil)
            } else {
                let operation = try #require(retried?.operations.first)
                #expect(operation.entity == .meeting)
                #expect(operation.baseRevision == 2)
            }
        }

        @Test
        func reapplyingAssociationRecreatesItsMissingMeetingBeforeTheLink() async throws {
            let fixture = try ScreenshotContentFixture()
            try await fixture.makeRemoteOnly()
            try await fixture.dbQueue.write { db in
                let image = try #require(try MeetingScreenshotRecord.fetchOne(db, key: fixture.screenshotId))
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision) VALUES (?, 'meeting_file', ?, 1)",
                    arguments: [fixture.vaultId, image.id]
                )
                try SyncTransactionRecorder.record(
                    vaultId: fixture.vaultId,
                    operations: [SyncInitialSnapshotBuilder.meetingFileOperation(image)],
                    in: db
                )
            }
            let transaction = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.dbQueue))
            try await SyncTransactionQueue.block(transaction, reason: .conflict, response: Data("""
            {"conflicts":[
              {"entity":"meeting_file","id":"\(fixture.screenshotId)","serverRevision":null},
              {"entity":"meeting","id":"\(fixture.meetingId)","serverRevision":null}
            ]}
            """.utf8), dbQueue: fixture.dbQueue)
            try await SyncTransactionQueue.reapplyLocalVersion(
                vaultId: fixture.vaultId,
                dbQueue: fixture.dbQueue,
                screenshotContent: ScreenshotContentProvider()
            )
            try await fixture.dbQueue.read { db in
                let operations = try Row.fetchAll(db, sql: """
                SELECT o.entity, o.action, o.baseRevision, o.payloadJSON FROM sync_operations o
                JOIN sync_transactions t ON t.id = o.transactionId ORDER BY t.sequence, o.position
                """)
                #expect(operations.map { $0["entity"] as String } == ["meeting", "meeting_file"])
                #expect(operations.map { $0["action"] as String } == ["create", "upsert"])
                #expect(operations.allSatisfy { ($0["baseRevision"] as Int?) == nil })
                let link = try #require(operations.last)
                let payload = try SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: Data((link["payloadJSON"] as String).utf8))
                #expect(payload.meetingId == fixture.meetingId)
                #expect(payload.fileId == fixture.screenshotId)
                #expect(payload.createdAt != nil)
            }
        }

        @Test(.timeLimit(.minutes(1)), arguments: [false, true])
        func movingAnAccountRetainsAllItsVaultsUntilCompletion(failsSecondImage: Bool) async throws {
            let first = try ScreenshotContentFixture()
            let second = try ScreenshotContentFixture(dbQueue: first.dbQueue)
            let unrelated = try ScreenshotContentFixture(dbQueue: first.dbQueue)
            let secondSource = ScreenshotRemoteReference(
                origin: first.source.origin, accountConnectionId: first.connectionId,
                fileId: second.screenshotId, contentHash: second.source.contentHash
            )
            try await first.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE vaults SET accountConnectionId = ?, syncConfirmedConnectionId = ? WHERE id = ?",
                    arguments: [first.connectionId, first.connectionId, second.vaultId]
                )
                try db.execute(
                    sql: "UPDATE files SET remoteReference = ? WHERE id = ?",
                    arguments: [secondSource.jsonString(), second.screenshotId]
                )
            }
            try await first.confirm()
            try await second.confirm()
            try await unrelated.confirm()
            try await first.makeRemoteOnly()
            try await second.makeRemoteOnly()
            ImageURLProtocol.register(origin: first.source.origin) { request in
                let fails = failsSecondImage && request.url!.path.contains(second.screenshotId.uuidString.lowercased())
                return (fails ? 404 : 200, ["content-type": "image/png"], first.bytes)
            }
            defer { ImageURLProtocol.remove(origin: first.source.origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let requests = Mutex(0)
            let gate = ImageRequestGate()
            let provider = ScreenshotContentProvider(session: URLSession(configuration: configuration), tokenProvider: { _, _ in
                let count = requests.withLock { $0 += 1
                    return $0
                }
                if count == 2 { await gate.enter("second image") }
                return "test-token"
            })
            var events = gate.events.makeAsyncIterator()
            let moving = Task {
                try await MeetingRepository(dbQueue: first.dbQueue).resolveVaultsForSignOut(
                    connectionID: first.connectionId, disposition: .moveToLocalAccount, screenshotContent: provider
                )
            }
            #expect(await events.next() == "second image")
            #expect(try await first.storedBytes() == nil)
            #expect(try await provider.content(id: first.screenshotId, dbQueue: first.dbQueue).data == first.bytes)
            try await provider.trimFiles(dbQueue: first.dbQueue, budget: 0)
            #expect(try await first.storedBytes() == nil)
            #expect(try await provider.content(id: first.screenshotId, dbQueue: first.dbQueue).data == first.bytes)
            #expect(try await unrelated.storedBytes() == unrelated.bytes)
            await gate.releaseAll()
            if failsSecondImage {
                await #expect(throws: ScreenshotContentError.deleted) { try await moving.value }
                #expect(try await first.dbQueue.read { try VaultRecord.fetchOne($0, key: first.vaultId)?.accountConnectionId } == first.connectionId)
                // Failure releases the protection, so normal cache maintenance can resume.
                try await provider.trimFiles(dbQueue: first.dbQueue, budget: 0)
                #expect(try await first.storedBytes() == nil)
            } else {
                try await moving.value
                #expect(try await first.storedBytes() == nil)
                #expect(try await provider.content(id: first.screenshotId, dbQueue: first.dbQueue).data == first.bytes)
                #expect(try await second.storedBytes() == nil)
                #expect(try await provider.content(id: second.screenshotId, dbQueue: second.dbQueue).data == second.bytes)
                #expect(try await first.dbQueue.read {
                    try Int.fetchOne($0, sql: "SELECT count(*) FROM vaults WHERE accountConnectionId = ?", arguments: [first.connectionId])
                } == 0)
            }
        }

        @Test(arguments: ["screenshot", "meeting", "none"], [false, true])
        func v44UpgradeDropsOnlySupersededImageMetadata(deletion: String, keepsUnrelatedOperation: Bool) async throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v44_retireVectorSearch")
            let fixture = try ScreenshotContentFixture(dbQueue: queue, priorSchema: true)
            let updateTransaction = UUID.v7()
            let deleteTransaction = UUID.v7()
            let metadataOperation = UUID.v7()
            let unrelatedOperation = UUID.v7()
            let deleteOperation = UUID.v7()
            try await queue.write { db in
                for id in [updateTransaction, deleteTransaction] {
                    try db.execute(sql: """
                    INSERT INTO sync_transactions(id, vaultId, connectionId, createdAt, availableAt) VALUES (?, ?, ?, ?, ?)
                    """, arguments: [id, fixture.vaultId, fixture.connectionId, Date(), Date()])
                }
                let payload = "{\"meetingId\":\"\(fixture.meetingId.uuidString.lowercased())\",\"ocrText\":\"Pending OCR\",\"caption\":\"Pending caption\"}"
                try db.execute(sql: """
                INSERT INTO sync_operations(transactionId, position, id, entity, action, entityId, payloadJSON)
                VALUES (?, 0, ?, 'screenshot', 'upsert', ?, ?)
                """, arguments: [updateTransaction, metadataOperation, fixture.screenshotId, payload])
                if keepsUnrelatedOperation {
                    try db.execute(sql: """
                    INSERT INTO sync_operations(transactionId, position, id, entity, action, entityId, payloadJSON)
                    VALUES (?, 1, ?, 'vault', 'update', ?, '{"name":"Preserved"}')
                    """, arguments: [updateTransaction, unrelatedOperation, fixture.vaultId])
                }
                try db.execute(sql: "DELETE FROM screenshots WHERE id = ?", arguments: [fixture.screenshotId])
                if deletion != "none" {
                    let target = deletion == "meeting" ? fixture.meetingId : fixture.screenshotId
                    try db.execute(sql: """
                    INSERT INTO sync_operations(transactionId, position, id, entity, action, entityId, payloadJSON)
                    VALUES (?, 0, ?, ?, 'delete', ?, '{}')
                    """, arguments: [deleteTransaction, deleteOperation, deletion, target])
                    if deletion == "meeting" { try MeetingRecord.deleteOne(db, key: fixture.meetingId) }
                }
            }
            if deletion == "none" {
                #expect(throws: ScreenshotContentError.unavailable) { try AppDatabaseManager.migrator.migrate(queue) }
                return
            }
            try AppDatabaseManager.migrator.migrate(queue)
            try await queue.read { db throws in
                #expect(try FileRecord.fetchCount(db) == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations WHERE id = ?", arguments: [metadataOperation]) == 0)
                #expect(try String.fetchOne(db, sql: "SELECT action FROM sync_operations WHERE id = ?", arguments: [deleteOperation]) == "delete")
                #expect(try Int
                    .fetchOne(db, sql: "SELECT count(*) FROM sync_operations WHERE id = ?", arguments: [unrelatedOperation]) ==
                    (keepsUnrelatedOperation ? 1 : 0))
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions") == (keepsUnrelatedOperation ? 2 : 1))
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }

        @Test
        func v44UpgradeExternalizesImagesAndPreservesQueuedAttachments() async throws {
            let dbQueue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(dbQueue, upTo: "v44_retireVectorSearch")
            let fixture = try ScreenshotContentFixture(dbQueue: dbQueue, priorSchema: true)
            let transactionId = UUID.v7()
            let operationId = UUID.v7()
            try await dbQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO sync_transactions(id, vaultId, connectionId, createdAt, availableAt) VALUES (?, ?, ?, ?, ?)",
                    arguments: [transactionId, fixture.vaultId, fixture.connectionId, Date(), Date()]
                )
                try db.execute(sql: """
                INSERT INTO sync_operations(transactionId, position, id, entity, action, entityId, attachmentMimeType, attachmentSHA256)
                VALUES (?, 0, ?, 'screenshot', 'upsert', ?, 'image/png', ?)
                """, arguments: [transactionId, operationId, fixture.screenshotId, fixture.source.contentHash])
            }
            try AppDatabaseManager.migrator.migrate(dbQueue)
            try await dbQueue.read { db in
                let row = try #require(try MeetingScreenshotRecord.fetchOne(db, key: fixture.screenshotId))
                #expect(row.imageData == fixture.bytes)
                #expect(row.ocrText == "durable OCR")
                #expect(row.caption == "durable caption")
                #expect(row.contentLength == fixture.bytes.count)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
                #expect(try db.tableExists("screenshots") == false)
                #expect(try db.tableExists("files"))
                #expect(try db.tableExists("meeting_files"))
            }
            let provider = ScreenshotContentProvider()
            try await provider.migrateLegacyImages(vaultId: fixture.vaultId, dbQueue: dbQueue)
            try await provider.migrateLegacyImages(vaultId: fixture.vaultId, dbQueue: dbQueue)
            #expect(try await fixture.storedBytes() == nil)
            #expect(try await provider.content(id: fixture.screenshotId, dbQueue: dbQueue).data == fixture.bytes)
            try await dbQueue.write { db in
                #expect(try String.fetchOne(db, sql: "SELECT attachmentReference FROM sync_operations WHERE id = ?", arguments: [operationId]) != nil)
                #expect(try Data.fetchOne(db, sql: "SELECT attachmentBytes FROM sync_operations WHERE id = ?", arguments: [operationId]) == nil)
                _ = try MeetingFileRecord.deleteOne(db, key: fixture.screenshotId)
                #expect(try Data.fetchOne(db, sql: "SELECT attachmentBytes FROM sync_operations WHERE id = ?", arguments: [operationId]) == nil)
            }
            #expect(try await provider.attachment(operationId: operationId, dbQueue: dbQueue)?.bytes == fixture.bytes)
        }

        @Test(arguments: [false, true])
        func evictionProtectsUnconfirmedQueuedAndRecoveryOriginals(remoteOnly: Bool) async throws {
            let fixture = try ScreenshotContentFixture()
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = try ScreenshotFileStore(directory: root)
            let provider = ScreenshotContentProvider(cache: cache)
            let queue = fixture.dbQueue
            let vaultId = fixture.vaultId
            try await provider.prepareOriginals(vaultId: vaultId, dbQueue: queue)
            #expect(try await fixture.storedBytes() == nil)
            try await provider.trimFiles(dbQueue: queue, budget: 0)
            #expect(try cache.read(fixture.source, variant: .original)?.data == fixture.bytes)
            try await fixture.confirm()
            if remoteOnly {
                try await queue.write { db in
                    try db.execute(sql: "UPDATE files SET localReference = NULL WHERE id = ?", arguments: [fixture.screenshotId])
                }
            }
            try await queue.write { db in
                let record = try #require(try MeetingScreenshotRecord.fetchOne(db, key: fixture.screenshotId))
                let operation = try SyncInitialSnapshotBuilder.screenshotOperation(record, action: .upsert, contentHash: fixture.source.contentHash)
                try SyncTransactionRecorder.record(
                    vaultId: vaultId,
                    operations: [operation],
                    in: db
                )
            }
            try await provider.trimFiles(dbQueue: queue, budget: 0)
            #expect(try cache.read(fixture.source, variant: .original)?.data == fixture.bytes)
            let transaction = try #require(try await SyncTransactionQueue.claim(dbQueue: queue))
            try await SyncTransactionQueue.block(transaction, reason: .conflict, response: Data("{}".utf8), dbQueue: queue)
            try await provider.trimFiles(dbQueue: queue, budget: 0)
            #expect(try cache.read(fixture.source, variant: .original)?.data == fixture.bytes)
            try await queue.write { db in
                try SyncTransactionQueue.discard(vaultId: vaultId, in: db)
                try db.execute(sql: "UPDATE vaults SET syncRecoveryState = 'pending' WHERE id = ?", arguments: [vaultId])
            }
            try await provider.trimFiles(dbQueue: queue, budget: 0)
            #expect(try cache.read(fixture.source, variant: .original)?.data == fixture.bytes)
            try await queue.write { db in
                try db.execute(sql: "UPDATE vaults SET syncRecoveryState = NULL WHERE id = ?", arguments: [vaultId])
            }
            try await provider.trimFiles(dbQueue: queue, budget: 0)
            #expect(try cache.read(fixture.source, variant: .original) == nil)
            #expect(try await queue.read { try VaultRecord.fetchOne($0, key: vaultId)?.syncPullCursor } == "cursor")
            #expect(try await !SyncTransactionQueue.hasPending(vaultId: vaultId, dbQueue: queue))
        }

        @Test
        func originalFallbackIsCachedAndCorruptionCausesARefetch() async throws {
            let fixture = try ScreenshotContentFixture()
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = try ScreenshotFileStore(directory: root)
            let calls = Mutex(0)
            let provider = makeProvider(fixture: fixture, cache: cache) { request in
                calls.withLock { $0 += 1 }
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
                return (200, ["content-type": "image/png", "x-dahlia-image-variant": "original"], fixture.bytes)
            }
            defer { ImageURLProtocol.remove(origin: fixture.source.origin) }
            try await fixture.makeRemoteOnly()
            let thumbnail = try await provider.content(id: fixture.screenshotId, variant: .thumbnail, dbQueue: fixture.dbQueue)
            #expect(thumbnail.variant == .original)
            #expect(thumbnail.data == fixture.bytes)
            #expect(try await provider.content(id: fixture.screenshotId, dbQueue: fixture.dbQueue).data == fixture.bytes)
            #expect(calls.withLock { $0 } == 1)
            try Data([0]).write(to: root.appending(path: "\(fixture.source.cacheKey(variant: .original))"))
            #expect(try await provider.content(id: fixture.screenshotId, dbQueue: fixture.dbQueue).data == fixture.bytes)
            #expect(calls.withLock { $0 } == 2)
        }

        @Test
        func wrongOriginalHashAndDetachedAccountCannotSupplyImages() async throws {
            let fixture = try ScreenshotContentFixture()
            let provider = makeProvider(fixture: fixture) { _ in (200, ["content-type": "image/png"], Data([9])) }
            defer { ImageURLProtocol.remove(origin: fixture.source.origin) }
            try await fixture.makeRemoteOnly()
            await #expect(throws: ScreenshotContentError.integrityFailure) {
                try await provider.content(id: fixture.screenshotId, dbQueue: fixture.dbQueue)
            }
            try await fixture.dbQueue.write { db in
                try db.execute(sql: "UPDATE vaults SET accountConnectionId = NULL WHERE id = ?", arguments: [fixture.vaultId])
            }
            await #expect(throws: ScreenshotContentError.authorizationRequired) {
                try await provider.content(id: fixture.screenshotId, dbQueue: fixture.dbQueue)
            }
        }

        @Test
        func refreshesAuthenticationOnceAndRejectsResultsAfterDisconnect() async throws {
            let fixture = try ScreenshotContentFixture()
            let attempts = Mutex(0)
            let refreshes = Mutex<[Bool]>([])
            ImageURLProtocol.register(origin: fixture.source.origin) { _ in
                let attempt = attempts.withLock { $0 += 1
                    return $0
                }
                return (attempt == 1 ? 401 : 200, ["content-type": "image/png"], fixture.bytes)
            }
            defer { ImageURLProtocol.remove(origin: fixture.source.origin) }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ImageURLProtocol.self]
            let provider = ScreenshotContentProvider(session: URLSession(configuration: config), tokenProvider: { _, refresh in
                refreshes.withLock { $0.append(refresh) }
                return "test-token"
            })
            try await fixture.makeRemoteOnly()
            #expect(try await provider.content(id: fixture.screenshotId, dbQueue: fixture.dbQueue).data == fixture.bytes)
            #expect(refreshes.withLock { $0 } == [false, true])
            let disconnecting = ScreenshotContentProvider(session: URLSession(configuration: config), tokenProvider: { _, _ in
                try await fixture.dbQueue.write { db in
                    try db.execute(sql: "UPDATE vaults SET accountConnectionId = NULL WHERE id = ?", arguments: [fixture.vaultId])
                }
                return "test-token"
            })
            await #expect(throws: ScreenshotContentError.deleted) {
                try await disconnecting.content(id: fixture.screenshotId, dbQueue: fixture.dbQueue)
            }
        }

        @Test(.timeLimit(.minutes(1)))
        func openingOriginalHasReservedCapacityAndCancelledThumbnailsDoNotFetch() async throws {
            let fixture = try ScreenshotContentFixture()
            ImageURLProtocol.register(origin: fixture.source.origin) { _ in
                (200, ["content-type": "image/png"], fixture.bytes)
            }
            defer { ImageURLProtocol.remove(origin: fixture.source.origin) }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ImageURLProtocol.self]
            let gate = ImageRequestGate()
            let provider = ScreenshotContentProvider(session: URLSession(configuration: config), tokenProvider: { _, _ in
                await gate.enter(ImageRequestContext.kind)
                return "test-token"
            })
            try await fixture.makeRemoteOnly()
            var events = gate.events.makeAsyncIterator()
            var thumbnails: [Task<ScreenshotContent, any Error>] = []
            for _ in 0 ..< 3 {
                thumbnails.append(Task {
                    try await ImageRequestContext.$kind.withValue("thumbnail") {
                        try await provider.content(id: fixture.screenshotId, variant: .thumbnail, dbQueue: fixture.dbQueue)
                    }
                })
                #expect(await events.next() == "thumbnail")
            }
            let cancelled = Task {
                try await provider.content(id: fixture.screenshotId, variant: .thumbnail, dbQueue: fixture.dbQueue)
            }
            let original = Task {
                try await ImageRequestContext.$kind.withValue("original") {
                    try await provider.content(id: fixture.screenshotId, dbQueue: fixture.dbQueue)
                }
            }
            #expect(await events.next() == "original")
            cancelled.cancel()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            await gate.releaseAll()
            #expect(try await original.value.data == fixture.bytes)
            for thumbnail in thumbnails {
                #expect(try await thumbnail.value.data == fixture.bytes)
            }
        }

        @Test
        func backupIncludesLocalOriginalsWithoutCloudReads() async throws {
            let fixture = try ScreenshotContentFixture()
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let calls = Mutex(0)
            let provider = try makeProvider(fixture: fixture, cache: ScreenshotFileStore(directory: root.appending(path: "FileStore"))) { _ in
                calls.withLock { $0 += 1 }
                return (404, [:], Data())
            }
            defer { ImageURLProtocol.remove(origin: fixture.source.origin) }
            let backup = BackupService(dbQueue: fixture.dbQueue, applicationSupportURL: root)
            await #expect(throws: BackupServiceError.localVaultsOnly) { try await backup.createGeneration(vaultIds: [fixture.vaultId]) }
            try await MeetingRepository(dbQueue: fixture.dbQueue).resolveVaultsForSignOut(
                connectionID: fixture.connectionId, disposition: .moveToLocalAccount, screenshotContent: provider
            )
            let generation = try await backup.createGeneration(vaultIds: [fixture.vaultId])
            let marker = try await backup.prepareRestore(from: generation, requests: [VaultBackupRestoreRequest(
                sourceVaultId: fixture.vaultId, targetVaultId: .v7(), mode: .newVault, name: "Restored"
            )])
            #expect(calls.withLock { $0 } == 0)
            let archiveURL = root.appending(path: "Restore/\(marker.stagedFilename)")
            let original = try BackupArchive.withExtracted(at: archiveURL) { directory, _ in
                try Data(contentsOf: directory.appending(path: "files/\(fixture.screenshotId.uuidString.lowercased())/original"))
            }
            #expect(original == fixture.bytes)
            let staged = try DatabaseQueue(path: extractedBackupDatabase(archiveURL).path)
            let restored = try await staged.read { try MeetingScreenshotRecord.fetchOne($0, key: fixture.screenshotId) }
            #expect(restored?.imageData == nil)
            #expect(restored?.localReference == nil)
            #expect(restored?.remoteReference == nil)
            try staged.close()
        }

        @Test(arguments: [false, true])
        func cachedThumbnailsFollowTheOriginalChecksum(readOnly: Bool) throws {
            let fixture = try ScreenshotContentFixture()
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = try ScreenshotFileStore(directory: root)
            let replacement = ScreenshotRemoteReference(
                origin: fixture.source.origin,
                accountConnectionId: fixture.connectionId,
                fileId: fixture.screenshotId,
                contentHash: ScreenshotRemoteReference.digest(Data([2]))
            )
            try cache.write(ScreenshotContent(data: fixture.bytes, mimeType: "image/png", variant: .original), source: fixture.source)
            try cache.write(ScreenshotContent(data: Data([1]), mimeType: "image/webp", variant: .thumbnail), source: fixture.source)
            let reopened = try ScreenshotFileStore(directory: root, readOnly: readOnly)
            #expect(try reopened.read(replacement, variant: .thumbnail) == nil)
            #expect(try reopened.read(fixture.source, variant: .thumbnail)?.data == Data([1]))
            try cache.write(ScreenshotContent(data: Data([3]), mimeType: "image/webp", variant: .thumbnail), source: replacement)
            #expect(try reopened.read(fixture.source, variant: .thumbnail) == nil)
            #expect(try reopened.read(replacement, variant: .thumbnail)?.data == Data([3]))
            #expect(try reopened.read(fixture.source, variant: .original)?.data == fixture.bytes)
        }

        @Test
        func cacheIndexUpgradePreservesOriginalsAndRefetchesUnboundThumbnails() throws {
            let fixture = try ScreenshotContentFixture()
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let index = try DatabaseQueue(path: root.appending(path: "index.sqlite").path)
            try index.write { db in
                try db
                    .execute(
                        sql: "CREATE TABLE images (key TEXT PRIMARY KEY, mimeType TEXT NOT NULL, variant TEXT NOT NULL, byteCount INTEGER NOT NULL, digest TEXT NOT NULL, accessedAt REAL NOT NULL)"
                    )
                for variant in [ScreenshotVariant.original, .thumbnail] {
                    let key = fixture.source.cacheKey(variant: variant)
                    let file = root.appending(path: key)
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fixture.bytes.write(to: file)
                    try db.execute(
                        sql: "INSERT INTO images VALUES (?, 'image/png', ?, ?, ?, 0)",
                        arguments: [key, variant.rawValue, fixture.bytes.count, fixture.source.contentHash]
                    )
                }
            }
            try index.close()
            let helper = try ScreenshotFileStore(directory: root, readOnly: true)
            #expect(try helper.read(fixture.source, variant: .original)?.data == fixture.bytes)
            #expect(try helper.read(fixture.source, variant: .thumbnail) == nil)
            let upgraded = try ScreenshotFileStore(directory: root)
            #expect(try upgraded.read(fixture.source, variant: .original)?.data == fixture.bytes)
            #expect(try upgraded.read(fixture.source, variant: .thumbnail) == nil)
            try upgraded.write(ScreenshotContent(data: fixture.bytes, mimeType: "image/png", variant: .thumbnail), source: fixture.source)
            #expect(try upgraded.read(fixture.source, variant: .thumbnail)?.data == fixture.bytes)
        }

        @Test
        func cacheEnforcesBudgetAndVacuumActuallyShrinksTheFile() async throws {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = try ScreenshotFileStore(directory: root.appending(path: "cache"))
            let fixture = try ScreenshotContentFixture()
            let content = ScreenshotContent(data: fixture.bytes, mimeType: "image/png", variant: .original)
            try cache.write(content, source: fixture.source, budget: fixture.bytes.count)
            let second = ScreenshotRemoteReference(
                origin: fixture.source.origin,
                accountConnectionId: fixture.connectionId,
                fileId: .v7(),
                contentHash: fixture.source.contentHash
            )
            try cache.write(content, source: second, budget: fixture.bytes.count)
            try cache.trim(budget: fixture.bytes.count, protecting: [])
            #expect(try cache.read(fixture.source, variant: .original) == nil)
            try cache.write(content, source: fixture.source, budget: 100)
            try cache.trim(budget: 0, protecting: [])
            #expect(try cache.read(fixture.source, variant: .original) == nil)
            let path = root.appending(path: "compact.sqlite")
            let database = try AppDatabaseManager(path: path.path)
            let retained = try ScreenshotContentFixture(dbQueue: database.dbQueue)
            try await database.dbQueue.write { db in
                try db
                    .execute(
                        sql: "CREATE TABLE compaction_fixture(bytes BLOB); INSERT INTO compaction_fixture VALUES (zeroblob(8388608)); DELETE FROM compaction_fixture"
                    )
            }
            let before = try #require(path.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            try await ScreenshotStorageMaintenance.compactAtStartup(dbQueue: database.dbQueue, minimumFreeBytes: 1)
            let after = try #require(path.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            #expect(after < before)
            #expect(try await retained.storedBytes() == retained.bytes)
            #expect(try await database.dbQueue.read { try Int.fetchOne($0, sql: "PRAGMA auto_vacuum") } == 2)
            try database.close()
        }

        @Test
        func backupRejectsServerOnlyAndMixedSelections() async throws {
            let server = try ScreenshotContentFixture()
            let local = try ScreenshotContentFixture(dbQueue: server.dbQueue)
            try await local.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE vaults SET accountConnectionId = NULL, syncConfirmedConnectionId = NULL WHERE id = ?",
                    arguments: [local.vaultId]
                )
            }
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let service = BackupService(dbQueue: server.dbQueue, applicationSupportURL: root)
            #expect(try await service.listVaults().map(\.id) == [local.vaultId])
            await #expect(throws: BackupServiceError.localVaultsOnly) { try await service.createGeneration(vaultIds: [server.vaultId]) }
            await #expect(throws: BackupServiceError.localVaultsOnly) { try await service.createGeneration(vaultIds: [server.vaultId, local.vaultId])
            }
            #expect(try await service.listGenerations().isEmpty)
            #expect(try await server.storedBytes() == server.bytes)
            #expect(try await local.storedBytes() == local.bytes)
        }

        private func temporaryDirectory() -> URL {
            FileManager.default.temporaryDirectory.appending(path: "screenshot-content-\(UUID().uuidString)")
        }

        private func makeProvider(
            fixture: ScreenshotContentFixture,
            cache: ScreenshotFileStore? = nil,
            handler: @escaping ImageURLProtocol.Handler
        ) -> ScreenshotContentProvider {
            ImageURLProtocol.register(origin: fixture.source.origin, handler: handler)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ImageURLProtocol.self]
            return ScreenshotContentProvider(session: URLSession(configuration: config), cache: cache, tokenProvider: { _, _ in "test-token" })
        }
    }

    private enum ImageRequestContext {
        @TaskLocal static var kind = ""
    }

    private actor ImageRequestGate {
        nonisolated let events: AsyncStream<String>
        private let continuation: AsyncStream<String>.Continuation
        private var waiting: [CheckedContinuation<Void, Never>] = []

        init() {
            (events, continuation) = AsyncStream.makeStream(of: String.self)
        }

        func enter(_ kind: String) async {
            await withCheckedContinuation { waiter in
                waiting.append(waiter)
                continuation.yield(kind)
            }
        }

        func releaseAll() {
            let current = waiting
            waiting.removeAll()
            current.forEach { $0.resume() }
        }
    }

    private struct ScreenshotContentFixture: Sendable {
        let dbQueue: DatabaseQueue
        let vaultId = UUID.v7()
        let connectionId = UUID.v7()
        let meetingId = UUID.v7()
        let screenshotId = UUID.v7()
        let bytes = Data([1, 2, 3, 4, 5, 6])
        let source: ScreenshotRemoteReference

        init(dbQueue: DatabaseQueue? = nil, priorSchema: Bool = false) throws {
            self.dbQueue = try dbQueue ?? AppDatabaseManager(path: ":memory:").dbQueue
            source = ScreenshotRemoteReference(
                origin: "https://\(UUID().uuidString.lowercased()).example.test",
                accountConnectionId: connectionId,
                fileId: screenshotId,
                contentHash: ScreenshotRemoteReference.digest(bytes)
            )
            let connection = DahliaAccountConnectionRecord(id: connectionId, origin: source.origin, clientID: "test", createdAt: .now)
            var vault = VaultRecord(id: vaultId, path: nil, name: "Vault", createdAt: .now, lastOpenedAt: .now)
            vault.accountConnectionId = connectionId
            vault.syncConfirmedConnectionId = connectionId
            vault.syncPullCursor = "cursor"
            let meeting = MeetingRecord(id: meetingId, vaultId: vaultId, projectId: nil, name: "Meeting", createdAt: .now, updatedAt: .now)
            try self.dbQueue.write { db in
                try connection.insert(db)
                try vault.insert(db)
                try meeting.insert(db)
                if priorSchema {
                    try db.execute(
                        sql: "INSERT INTO screenshots(id, meetingId, capturedAt, imageData, mimeType, ocrText, caption) VALUES (?, ?, ?, ?, 'image/png', 'durable OCR', 'durable caption')",
                        arguments: [screenshotId, meetingId, Date(), bytes]
                    )
                } else {
                    try MeetingScreenshotRecord(
                        id: screenshotId,
                        meetingId: meetingId,
                        capturedAt: .now,
                        imageData: bytes,
                        mimeType: "image/png",
                        ocrText: "durable OCR",
                        caption: "durable caption",
                        remoteReference: source.jsonString()
                    ).insertLegacyForTesting(db)
                }
            }
        }

        func confirm() async throws {
            try await dbQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision) VALUES (?, 'file', ?, 1)",
                    arguments: [vaultId, screenshotId]
                )
            }
        }

        func makeRemoteOnly() async throws {
            try await dbQueue.write { db in
                try db.execute(sql: "DELETE FROM file_migration_content WHERE fileId = ?", arguments: [screenshotId])
            }
        }

        func storedBytes() async throws -> Data? {
            try await dbQueue.read { try MeetingScreenshotRecord.fetchOne($0, key: screenshotId)?.imageData }
        }
    }

    /// URLProtocol callbacks are synchronous here; handler registration is protected across parallel tests.
    private final class ImageURLProtocol: URLProtocol, @unchecked Sendable {
        typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], Data)
        private static let handlers = Mutex<[String: Handler]>([:])

        static func register(origin: String, handler: @escaping Handler) { handlers.withLock { $0[URL(string: origin)!.host!] = handler } }
        static func remove(origin: String) { _ = handlers.withLock { $0.removeValue(forKey: URL(string: origin)!.host!) } }
        override static func canInit(with _: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url, let host = url.host, let handler = Self.handlers.withLock({ $0[host] }) else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
                return
            }
            let (status, headers, bytes) = handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
#endif
