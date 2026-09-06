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
            #expect(try await missing.storedBytes() == missing.bytes)
            #expect(try await missing.dbQueue.read { try VaultRecord.fetchOne($0, key: missing.vaultId)?.syncConfirmedConnectionId } == missing
                .connectionId)
        }

        @Test
        func gridRequestsThumbnailWhileLargerImagesRequestOriginal() async throws {
            let fixture = try ScreenshotContentFixture()
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let variants = Mutex<[String]>([])
            let provider = try makeProvider(fixture: fixture, cache: ScreenshotDiskCache(directory: root)) { request in
                let variant = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "variant" })?.value ?? "original"
                variants.withLock { $0.append(variant) }
                return (200, [
                    "content-type": "image/png",
                    "x-dahlia-image-variant": variant,
                    "x-dahlia-original-sha256": fixture.source.contentHash,
                ], fixture.bytes)
            }
            defer { ImageURLProtocol.remove(origin: fixture.source.origin) }
            await provider.configure(dbQueue: fixture.dbQueue)
            try await fixture.makeRemoteOnly()
            let loader = ScreenshotImageLoader(contentProvider: provider, cacheableDecoder: { data, _ in
                #expect(data == fixture.bytes)
                return nil
            })
            _ = await loader.image(screenshotID: fixture.screenshotId, data: nil, maxPixelSize: ScreenshotGridSizing.maximumThumbnailPixelSize)
            _ = await loader.image(screenshotID: fixture.screenshotId, data: nil, maxPixelSize: 1200)
            #expect(variants.withLock { $0 } == ["thumbnail", "original"])
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
            let entity: SyncEntity = deletesScreenshot ? .screenshot : .meeting
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

        @Test(.timeLimit(.minutes(1)), arguments: [false, true])
        func movingAnAccountRetainsAllItsVaultsUntilCompletion(failsSecondImage: Bool) async throws {
            let first = try ScreenshotContentFixture()
            let second = try ScreenshotContentFixture(dbQueue: first.dbQueue)
            let unrelated = try ScreenshotContentFixture(dbQueue: first.dbQueue)
            let secondSource = ScreenshotRemoteReference(
                origin: first.source.origin, vaultId: second.vaultId, meetingId: second.meetingId,
                screenshotId: second.screenshotId, contentHash: second.source.contentHash
            )
            try await first.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE vaults SET accountConnectionId = ?, syncConfirmedConnectionId = ? WHERE id = ?",
                    arguments: [first.connectionId, first.connectionId, second.vaultId]
                )
                try db.execute(
                    sql: "UPDATE screenshots SET remoteReference = ? WHERE id = ?",
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
            #expect(try await first.storedBytes() == first.bytes)
            try await provider.evictConfirmedOriginals(dbQueue: first.dbQueue)
            #expect(try await first.storedBytes() == first.bytes)
            #expect(try await unrelated.storedBytes() == nil)
            await gate.releaseAll()
            if failsSecondImage {
                await #expect(throws: ScreenshotContentError.deleted) { try await moving.value }
                #expect(try await first.dbQueue.read { try VaultRecord.fetchOne($0, key: first.vaultId)?.accountConnectionId } == first.connectionId)
                // Failure releases the protection, so normal cache maintenance can resume.
                try await provider.evictConfirmedOriginals(dbQueue: first.dbQueue)
                #expect(try await first.storedBytes() == nil)
            } else {
                try await moving.value
                #expect(try await first.storedBytes() == first.bytes)
                #expect(try await second.storedBytes() == second.bytes)
                #expect(try await first.dbQueue.read {
                    try Int.fetchOne($0, sql: "SELECT count(*) FROM vaults WHERE accountConnectionId = ?", arguments: [first.connectionId])
                } == 0)
            }
        }

        @Test
        func v44UpgradePreservesOriginalAndQueuedAttachmentGuards() throws {
            let dbQueue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(dbQueue, upTo: "v44_retireVectorSearch")
            let fixture = try ScreenshotContentFixture(dbQueue: dbQueue, priorSchema: true)
            let objects = try dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT sql FROM sqlite_master WHERE tbl_name = 'screenshots' AND type = 'trigger' ORDER BY name")
            }
            try AppDatabaseManager.migrator.migrate(dbQueue)
            try dbQueue.write { db in
                let row = try #require(try MeetingScreenshotRecord.fetchOne(db, key: fixture.screenshotId))
                #expect(row.imageData == fixture.bytes)
                #expect(row.ocrText == "durable OCR")
                #expect(row.caption == "durable caption")
                #expect(row.contentLength == fixture.bytes.count)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
                #expect(try String.fetchAll(
                    db,
                    sql: "SELECT sql FROM sqlite_master WHERE tbl_name = 'screenshots' AND type = 'trigger' ORDER BY name"
                ) == objects)
                let operation = try SyncInitialSnapshotBuilder.screenshotOperation(row, action: .upsert, contentHash: fixture.source.contentHash)
                _ = try SyncTransactionRecorder.record(
                    vaultId: fixture.vaultId, operations: [operation],
                    screenshotAttachments: [operation.id: SyncScreenshotAttachment(mimeType: "image/png", bytes: fixture.bytes)], in: db
                )
                try db.execute(sql: "UPDATE screenshots SET imageData = NULL WHERE id = ?", arguments: [fixture.screenshotId])
                #expect(try Data.fetchOne(db, sql: "SELECT attachmentBytes FROM sync_operations WHERE id = ?", arguments: [operation.id]) == fixture
                    .bytes)
                #expect(try MeetingScreenshotRecord.fetchOne(db, key: fixture.screenshotId)?.imageData == nil)
            }
        }

        @Test
        func evictionProtectsPendingRecoveryRecordingAndLocalOriginals() async throws {
            let fixture = try ScreenshotContentFixture()
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = try ScreenshotDiskCache(directory: root)
            let provider = ScreenshotContentProvider(cache: cache)
            try await fixture.confirm()
            let queue = fixture.dbQueue
            let vaultId = fixture.vaultId
            try await queue.write { db in
                try db.execute(
                    sql: "INSERT INTO sync_transactions(id, vaultId, connectionId, createdAt, availableAt) VALUES (?, ?, ?, ?, ?)",
                    arguments: [UUID.v7(), vaultId, fixture.connectionId, Date(), Date()]
                )
            }
            try await provider.evictConfirmedOriginals(dbQueue: queue)
            #expect(try await fixture.storedBytes() == fixture.bytes)
            try await queue.write { db in
                try SyncTransactionQueue.discard(vaultId: vaultId, in: db)
                try db.execute(sql: "UPDATE vaults SET syncRecoveryState = 'pending' WHERE id = ?", arguments: [vaultId])
            }
            try await provider.evictConfirmedOriginals(dbQueue: queue)
            #expect(try await fixture.storedBytes() == fixture.bytes)
            let session = RecordingSessionRecord(
                id: .v7(),
                meetingId: fixture.meetingId,
                startedAt: .now,
                endedAt: nil,
                offsetSeconds: 0,
                createdAt: .now,
                updatedAt: .now
            )
            try await queue.write { db in
                try db.execute(sql: "UPDATE vaults SET syncRecoveryState = NULL WHERE id = ?", arguments: [vaultId])
                try session.insert(db)
            }
            try await provider.evictConfirmedOriginals(dbQueue: queue)
            #expect(try await fixture.storedBytes() == fixture.bytes)
            try await queue.write { db in
                try db.execute(sql: "UPDATE recording_sessions SET endedAt = ? WHERE id = ?", arguments: [Date(), session.id])
            }
            try await provider.evictConfirmedOriginals(dbQueue: queue)
            #expect(try await fixture.storedBytes() == nil)
            #expect(try await provider.content(id: fixture.screenshotId, dbQueue: queue).data == fixture.bytes)
            #expect(try await queue.read { try VaultRecord.fetchOne($0, key: vaultId)?.syncPullCursor } == "cursor")
            #expect(try await !SyncTransactionQueue.hasPending(vaultId: vaultId, dbQueue: queue))
            try await provider.hydrateOriginals(vaultId: vaultId, dbQueue: queue)
            try await MeetingRepository(dbQueue: queue).resolveVaultsForSignOut(connectionID: fixture.connectionId, disposition: .moveToLocalAccount)
            try await provider.evictConfirmedOriginals(dbQueue: queue)
            #expect(try await fixture.storedBytes() == fixture.bytes)
        }

        @Test
        func originalFallbackIsCachedAndCorruptionCausesARefetch() async throws {
            let fixture = try ScreenshotContentFixture()
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = try ScreenshotDiskCache(directory: root)
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
            try Data([0]).write(to: root.appending(path: "\(fixture.source.cacheKey(variant: .original)).bin"))
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
        func backupSavesReferencesAndRestoreHydratesOnlyItsStagedCopy() async throws {
            let fixture = try ScreenshotContentFixture()
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let calls = Mutex(0)
            let provider = makeProvider(fixture: fixture) { _ in
                calls.withLock { $0 += 1 }
                return (200, ["content-type": "image/png"], fixture.bytes)
            }
            defer { ImageURLProtocol.remove(origin: fixture.source.origin) }
            try await fixture.makeRemoteOnly()
            let backup = BackupService(dbQueue: fixture.dbQueue, applicationSupportURL: root, screenshotContent: provider)
            let generation = try await backup.createGeneration(vaultIds: [fixture.vaultId])
            #expect(calls.withLock { $0 } == 0)
            let marker = try await backup.prepareRestore(from: generation, requests: [VaultBackupRestoreRequest(
                sourceVaultId: fixture.vaultId, targetVaultId: .v7(), mode: .newVault, name: "Restored"
            )])
            #expect(calls.withLock { $0 } == 1)
            let staged = try DatabaseQueue(path: root.appending(path: "Restore/\(marker.stagedFilename)").path)
            let restored = try await staged.read { try MeetingScreenshotRecord.fetchOne($0, key: fixture.screenshotId) }
            #expect(restored?.imageData == fixture.bytes)
            #expect(try await fixture.storedBytes() == nil)
            let saved = try DatabaseQueue(path: generation.fileURL.path)
            #expect(try await saved.read { try MeetingScreenshotRecord.fetchOne($0, key: fixture.screenshotId)?.imageData } == nil)
            try staged.close()
            try saved.close()
        }

        @Test
        func cacheEnforcesBudgetAndVacuumActuallyShrinksTheFile() async throws {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = try ScreenshotDiskCache(directory: root.appending(path: "cache"))
            let fixture = try ScreenshotContentFixture()
            let content = ScreenshotContent(data: fixture.bytes, mimeType: "image/png", variant: .original)
            try cache.write(content, source: fixture.source, budget: fixture.bytes.count)
            let second = ScreenshotRemoteReference(
                origin: fixture.source.origin,
                vaultId: fixture.vaultId,
                meetingId: fixture.meetingId,
                screenshotId: .v7(),
                contentHash: fixture.source.contentHash
            )
            try cache.write(content, source: second, budget: fixture.bytes.count)
            #expect(try cache.read(fixture.source, variant: .original) == nil)
            try cache.write(content, source: fixture.source, budget: 100)
            try cache.trim(budget: 0)
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

        @Test(arguments: [false, true])
        func unavailableBackupImagesFailOnlyTheirVault(failAll: Bool) async throws {
            let first = try ScreenshotContentFixture()
            let second = try ScreenshotContentFixture(dbQueue: first.dbQueue)
            try await first.makeRemoteOnly()
            try await second.makeRemoteOnly()
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let provider = makeProvider(fixture: first) { _ in
                (failAll ? 404 : 200, ["content-type": "image/png"], first.bytes)
            }
            defer { ImageURLProtocol.remove(origin: first.source.origin) }
            let service = BackupService(dbQueue: first.dbQueue, applicationSupportURL: root, screenshotContent: provider)
            let generation = try await service.createGeneration(vaultIds: [first.vaultId, second.vaultId])
            let requests = [first, second].map {
                VaultBackupRestoreRequest(sourceVaultId: $0.vaultId, targetVaultId: .v7(), mode: .newVault, name: "Restored")
            }
            if failAll {
                await #expect(throws: ScreenshotContentError.deleted) { try await service.prepareRestore(from: generation, requests: requests) }
                #expect(!FileManager.default.fileExists(atPath: BackupService.pendingRestoreURL(applicationSupportURL: root).path))
                return
            }
            _ = try await service.prepareRestore(from: generation, requests: requests)
            let path = root.appending(path: "live.sqlite")
            let live = try AppDatabaseManager(path: path.path)
            try first.dbQueue.backup(to: live.dbQueue)
            try live.close()
            let outcome = BackupRestoreStartupProcessor.applyPendingRestore(applicationSupportURL: root, databaseURL: path)
            guard case let .completed(results) = outcome else { Issue.record("Restore failed: \(outcome)")
                return
            }
            #expect(results.count == 2)
            #expect(results.first?.error == nil)
            #expect(results.last?.error != nil)
            let restored = try AppDatabaseManager(path: path.path)
            defer { try? restored.close() }
            let firstTarget = requests[0].targetVaultId
            let secondTarget = requests[1].targetVaultId
            try await restored.dbQueue.read { db throws in
                #expect(try VaultRecord.fetchOne(db, key: firstTarget) != nil)
                #expect(try VaultRecord.fetchOne(db, key: secondTarget) == nil)
                #expect(try Data.fetchOne(
                    db,
                    sql: "SELECT s.imageData FROM screenshots s JOIN meetings m ON m.id = s.meetingId WHERE m.vaultId = ?",
                    arguments: [firstTarget]
                ) == first.bytes)
            }
        }

        private func temporaryDirectory() -> URL {
            FileManager.default.temporaryDirectory.appending(path: "screenshot-content-\(UUID().uuidString)")
        }

        private func makeProvider(
            fixture: ScreenshotContentFixture,
            cache: ScreenshotDiskCache? = nil,
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
                vaultId: vaultId,
                meetingId: meetingId,
                screenshotId: screenshotId,
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
                try db.execute(
                    sql: "INSERT INTO screenshots(id, meetingId, capturedAt, imageData, mimeType, ocrText, caption) VALUES (?, ?, ?, ?, 'image/png', 'durable OCR', 'durable caption')",
                    arguments: [screenshotId, meetingId, Date(), bytes]
                )
                if !priorSchema {
                    try db.execute(
                        sql: "UPDATE screenshots SET contentHash = ?, contentLength = ?, remoteReference = ? WHERE id = ?",
                        arguments: [source.contentHash, bytes.count, source.jsonString(), screenshotId]
                    )
                }
            }
        }

        func confirm() async throws {
            try await dbQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision) VALUES (?, 'screenshot', ?, 1)",
                    arguments: [vaultId, screenshotId]
                )
            }
        }

        func makeRemoteOnly() async throws {
            try await dbQueue.write { db in
                try db.execute(sql: "UPDATE screenshots SET imageData = NULL WHERE id = ?", arguments: [screenshotId])
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
