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
        @Test(arguments: [nil, "", " \n\t"] as [String?])
        func remoteAnalysisWaitIsBoundedWithoutDiscardingText(caption: String?) {
            let pending = ScreenshotOCRState.remote(ocrText: "OCR", caption: caption, state: .ready)
            #expect(!pending.isTerminal)
            #expect(pending.limitingRemoteWait(to: .seconds(299)) == pending)
            let timedOut = pending.limitingRemoteWait(to: .seconds(300))
            #expect(timedOut == .remote(ocrText: "OCR", caption: caption, state: .failed))
            #expect(timedOut.isTerminal)
            let complete = ScreenshotOCRState.remote(ocrText: "", caption: "Caption", state: .ready)
            #expect(complete.isTerminal)
            #expect(complete.limitingRemoteWait(to: .seconds(300)) == complete)
            #expect(ScreenshotOCRState.processing.limitingRemoteWait(to: .seconds(300)) == .processing)
        }

        @Test(.timeLimit(.minutes(1)), arguments: ["retry", "checksum", "size", "id", "vaultId"])
        func rawFileUploadPreservesTheQueuedTransactionAcrossRetries(firstFailure: String) async throws {
            let fixture = try ScreenshotContentFixture()
            let fileStore = try await ScreenshotContentProvider.shared.fileStore(for: fixture.dbQueue)
            try fileStore.write(
                ScreenshotContent(data: fixture.bytes, mimeType: "image/png", variant: .original),
                source: fixture.source,
                required: true
            )
            let filename = "会議 + 売上&#?.png"
            let payload = FileOperationPayload(
                name: filename,
                checksum: "SHA-256:" + fixture.source.contentHash,
                metadata: FileMetadata(
                    source: .screenshot,
                    width: 1800,
                    height: 900,
                    ocrText: "durable OCR",
                    caption: "durable caption"
                )
            )
            let operation = try SyncOperationDraft(
                entity: .file,
                action: .upsert,
                entityId: fixture.screenshotId,
                payloadJSON: SyncJSON.encoder.encode(payload)
            )
            let transactionId = try await fixture.dbQueue.write { db in
                // This is an established Vault, so an empty queue must not trigger initial snapshot recovery.
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision) VALUES (?, 'vault', ?, 1)",
                    arguments: [fixture.vaultId, fixture.vaultId]
                )
                return try #require(try SyncTransactionRecorder.record(vaultId: fixture.vaultId, operations: [operation], screenshotAttachments: [
                    operation.id: SyncScreenshotAttachmentReference(mimeType: "image/png", source: fixture.source),
                ], in: db))
            }
            let metadataData = try SyncJSON.encoder.encode(payload.metadata)
            var wireMetadata: [String: JSONValue] = [:]
            wireMetadata = try SyncJSON.decoder.decode(type(of: wireMetadata), from: metadataData)
            wireMetadata["ocrText"] = wireMetadata.removeValue(forKey: "ocr_text")
            let uploadRecord: [String: JSONValue] = [
                "id": .string(fixture.screenshotId.uuidString), "vaultId": .string(fixture.vaultId.uuidString),
                "size": .number(Double(fixture.bytes.count)), "checksum": .string(payload.checksum),
                "uri": .string("/Volumes/test/app/files/files/\(fixture.screenshotId.uuidString.lowercased())/original"),
                "offset": .number(0), "contentType": .string("image/png"), "name": .string(filename),
                "metadata": .object(wireMetadata),
                "revision": .number(1), "createdAt": .string("2026-09-07T00:00:00Z"), "updatedAt": .string("2026-09-07T00:00:00Z"),
            ]
            let uploaded = try SyncJSON.encoder.encode(uploadRecord)
            var incorrect = uploadRecord
            switch firstFailure {
            case "checksum": incorrect["checksum"] = .string("SHA-256:" + String(repeating: "0", count: 64))
            case "size": incorrect["size"] = .number(0)
            case "id", "vaultId": incorrect[firstFailure] = .string(UUID.v7().uuidString)
            default: break
            }
            let firstUpload = try SyncJSON.encoder.encode(incorrect)
            let receipt = try SyncJSON.encoder.encode(JSONValue.object([
                "id": .string(transactionId.uuidString), "status": .string("committed"), "cursor": .string("after"),
                "records": .array([.object([
                    "entity": .string("file"),
                    "id": .string(fixture.screenshotId.uuidString),
                    "revision": .number(1),
                    "record": .object(uploadRecord),
                ])]),
            ]))
            let requests = Mutex<[URLRequest]>([])
            ImageURLProtocol.register(origin: fixture.source.origin) { request in
                var recorded = request
                if let stream = request.httpBodyStream, request.httpBody == nil {
                    stream.open()
                    defer { stream.close() }
                    var body = Data()
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while true {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        body.append(contentsOf: buffer.prefix(count))
                    }
                    recorded.httpBody = body
                }
                requests.withLock { $0.append(recorded) }
                let path = request.url!.path
                if path == "/api/v1/transactions/resolve" {
                    return (200, [:], Data("{\"id\":\"\(transactionId)\",\"status\":\"unknown\"}".utf8))
                }
                if path == "/api/v1/file-uploads" { return (201, [:], uploaded) }
                if path == "/api/v1/file-uploads/\(fixture.screenshotId.uuidString.lowercased())/content" {
                    let first = requests.withLock { $0.filter { $0.url?.path == path }.count } == 1
                    return (first ? 201 : 200, [:], first ? firstUpload : uploaded)
                }
                if path == "/api/v1/transactions" {
                    let first = requests.withLock { $0.filter { $0.url?.path == path }.count } == 1
                    return firstFailure == "retry" && first ? (503, [:], Data()) : (200, [:], receipt)
                }
                return (503, [:], Data())
            }
            defer { ImageURLProtocol.remove(origin: fixture.source.origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let worker = SyncWorker(
                dbQueue: fixture.dbQueue,
                session: session,
                apiClient: SyncAPIClient(session: session, tokenProvider: { _, _ in "test-token" })
            )
            let retries = ValueObservation.tracking { db in
                try String.fetchOne(db, sql: "SELECT serverResponseJSON FROM sync_transactions WHERE id = ?", arguments: [transactionId])
            }.values(in: fixture.dbQueue)
            await worker.drain()
            for try await retry in retries where retry == (firstFailure == "retry" ? "http_503" : "sync_failed") {
                break
            }
            await worker.stop()
            try await fixture.dbQueue.write { db in
                #expect(try Data.fetchOne(db, sql: "SELECT payloadJSON FROM sync_operations WHERE id = ?", arguments: [operation.id]) == operation
                    .payloadJSON)
                try db.execute(sql: "UPDATE sync_transactions SET availableAt = ? WHERE id = ?", arguments: [Date.distantPast, transactionId])
            }
            let counts = ValueObservation.tracking { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions WHERE id = ?", arguments: [transactionId]) ?? 0
            }.values(in: fixture.dbQueue)
            await worker.drain()
            for try await count in counts where count == 0 {
                break
            }
            await worker.stop()
            let all = requests.withLock { $0 }
            let uploads = all.filter { $0.url?.path == "/api/v1/file-uploads/\(fixture.screenshotId.uuidString.lowercased())/content" }
            #expect(uploads.count == 2)
            for upload in uploads {
                #expect(upload.httpMethod == "PUT")
                #expect(upload.httpBody == fixture.bytes)
                #expect(upload.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
                #expect(upload.value(forHTTPHeaderField: "Content-Length") == String(fixture.bytes.count))
                #expect(upload.url?.query == nil)
            }
            let reservations = all.filter { $0.url?.path == "/api/v1/file-uploads" }
            #expect(reservations.count == 2)
            for reservation in reservations {
                let data = try #require(reservation.httpBody)
                let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                #expect(reservation.httpMethod == "POST")
                #expect(body["id"] as? String == fixture.screenshotId.uuidString.lowercased())
                #expect(body["vaultId"] as? String == fixture.vaultId.uuidString.lowercased())
                #expect(body["name"] as? String == filename)
                #expect(body["contentType"] as? String == "image/png")
                let metadata = try #require(body["metadata"] as? [String: Any])
                #expect(metadata["source"] as? String == "screenshot")
                #expect(metadata["width"] as? Int == 1800)
                #expect(metadata["height"] as? Int == 900)
            }
            let resolves = try all.filter { request in
                guard request.url?.path == "/api/v1/transactions/resolve", let body = request.httpBody else { return false }
                let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                return (object?["id"] as? String).flatMap(UUID.init(uuidString:)) == transactionId
            }
            #expect(resolves.count == 1)
            let resolvedBody = try #require(resolves.first?.httpBody)
            #expect(resolves.last?.httpBody == resolvedBody)
            let commits = all.filter { $0.url?.path == "/api/v1/transactions" }
            #expect(commits.count == (firstFailure == "retry" ? 2 : 1))
            #expect(commits.allSatisfy { $0.httpBody == resolvedBody })

            // Exercise the next drain iteration even when stop wins the race with the worker.
            try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: fixture.dbQueue)
            #expect(try await fixture.dbQueue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sync_transactions") } == 0)
        }

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

        @Test(arguments: [false, true])
        func newlyCapturedServerImageUsesRemoteStateOnceUploaded(uploaded: Bool) async throws {
            let fixture = try ScreenshotContentFixture()
            try await fixture.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE files SET remoteReference = ?, localReference = ? WHERE id = ?",
                    arguments: [uploaded ? fixture.source.jsonString() : nil, uploaded ? fixture.source.jsonString() : nil, fixture.screenshotId]
                )
                try db.execute(sql: "UPDATE file_text_bodies SET ocrText = NULL, caption = NULL WHERE fileId = ?", arguments: [fixture.screenshotId])
                try db.execute(
                    sql: "INSERT INTO jobs_search_index(indexKind, targetKind, targetKey, priority, availableAt, updatedAt) VALUES ('fts', 'screenshotAnalysis', ?, -10, ?, ?)",
                    arguments: [fixture.screenshotId, Date(), Date()]
                )
                try SyncTransactionRecorder.record(vaultId: fixture.vaultId, operations: [
                    SyncOperationDraft(entity: .file, action: .upsert, entityId: fixture.screenshotId),
                ], in: db)
                if uploaded {
                    try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'file', ?, 1)", arguments: [fixture.vaultId, fixture.screenshotId])
                    try db.execute(sql: "UPDATE sync_content_state SET residentRevision = 1 WHERE entity = 'file'")
                }
            }
            let viewModel = CaptionViewModel()
            defer { viewModel.clearCurrentMeeting() }
            viewModel.loadMeeting(fixture.meetingId, dbQueue: fixture.dbQueue, projectURL: nil, projectId: nil, vaultURL: nil)
            let remotePending = ScreenshotOCRState.remote(ocrText: nil, caption: nil, state: .ready)
            #expect(await viewModel.screenshotOCRState(id: fixture.screenshotId) == (uploaded ? remotePending : .pending))
            try await fixture.dbQueue.write { db in
                try db.execute(sql: "UPDATE jobs_search_index SET status = 'processing', attempts = 1 WHERE targetKind = 'screenshotAnalysis'")
            }
            #expect(await viewModel.screenshotOCRState(id: fixture.screenshotId) == (uploaded ? remotePending : .processing))
            try await fixture.dbQueue.write { db in
                try db.execute(sql: "UPDATE jobs_search_index SET status = 'pending', attempts = 5 WHERE targetKind = 'screenshotAnalysis'")
            }
            #expect(await viewModel.screenshotOCRState(id: fixture.screenshotId) == (uploaded ? remotePending : .failed))
            try await fixture.dbQueue.write { db in
                try db.execute(sql: "UPDATE jobs_search_index SET status = 'pending', attempts = 0 WHERE targetKind = 'screenshotAnalysis'")
            }
            #expect(await viewModel.screenshotOCRState(id: fixture.screenshotId) == (uploaded ? remotePending : .pending))
            try await fixture.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE file_text_bodies SET ocrText = 'Recognized text', caption = 'Image caption' WHERE fileId = ?",
                    arguments: [fixture.screenshotId]
                )
            }
            #expect(await viewModel.screenshotOCRState(id: fixture.screenshotId) == (uploaded
                    ? .remote(ocrText: "Recognized text", caption: "Image caption", state: .ready)
                    : .completed(ocrText: "Recognized text", caption: "Image caption")))
        }

        @Test
        func gridRequestsThumbnailWhileLargerImagesRequestOriginal() async throws {
            let fixture = try ScreenshotContentFixture()
            #expect(ScreenshotVariant.thumbnail.rawValue == "thumb_480")
            #expect(ScreenshotVariant(rawValue: "thumbnail") == nil)
            #expect(ScreenshotVariant(rawValue: "thumb_360") == nil)
            #expect(fixture.source.cacheKey(variant: .thumbnail).hasSuffix("variants/v1/thumb_480.webp"))
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let variants = Mutex<[String]>([])
            let provider = try makeProvider(fixture: fixture, cache: ScreenshotFileStore(directory: root)) { request in
                let variant = request.url!.path.hasSuffix("variants/thumb_480") ? "thumb_480" : "original"
                if variant == "original" {
                    #expect(request.url!.path == "/api/v1/files/\(fixture.source.fileId.uuidString.lowercased())/content")
                }
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
            #expect(variants.withLock { $0 } == ["thumb_480", "original"])
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
            let entity: SyncEntity = deletesScreenshot ? .meetingAttachment : .meeting
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
                    sql: "INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision) VALUES (?, 'meeting_attachment', ?, 1)",
                    arguments: [fixture.vaultId, image.id]
                )
                try SyncTransactionRecorder.record(
                    vaultId: fixture.vaultId,
                    operations: [SyncInitialSnapshotBuilder.meetingAttachmentOperation(image)],
                    in: db
                )
            }
            let transaction = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.dbQueue))
            try await SyncTransactionQueue.block(transaction, reason: .conflict, response: Data("""
            {"conflicts":[
              {"entity":"meeting_attachment","id":"\(fixture.screenshotId)","serverRevision":null},
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
                #expect(operations.map { $0["entity"] as String } == ["meeting", "meeting_attachment"])
                #expect(operations.map { $0["action"] as String } == ["create", "upsert"])
                #expect(operations.allSatisfy { ($0["baseRevision"] as Int?) == nil })
                let link = try #require(operations.last)
                let payload = try SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: Data((link["payloadJSON"] as String).utf8))
                #expect(payload.meetingId == fixture.meetingId)
                #expect(payload.fileId == fixture.screenshotId)
                #expect(payload.createdAt != nil)
            }
        }

        @Test(.timeLimit(.minutes(1)), arguments: ["success", "missingImage", "serverChanged"])
        func movingAnAccountRetainsAllItsVaultsUntilCompletion(scenario: String) async throws {
            let failsSecondImage = scenario == "missingImage"
            let serverChanged = Mutex(false)
            let first = try ScreenshotContentFixture()
            let second = try ScreenshotContentFixture(dbQueue: first.dbQueue)
            let unrelated = try ScreenshotContentFixture(dbQueue: first.dbQueue)
            let secondSource = ScreenshotRemoteReference(
                origin: first.source.origin, accountConnectionId: first.connectionId,
                fileId: second.screenshotId, contentHash: second.source.contentHash
            )
            try await first.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE vaults SET accountConnectionId = ?, organizationId = COALESCE(organizationId, id), syncConfirmedConnectionId = ? WHERE id = ?",
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
                let path = request.url!.path
                if path.hasSuffix("/changes"), path.contains(first.vaultId.uuidString.lowercased()), serverChanged.withLock({ $0 }) {
                    return (200, [:], Data("""
                    {"items":[],"cursor":"new-server-update","highWaterCursor":"new-server-update","hasMore":false}
                    """.utf8))
                }
                if let text = cachedTextResponse(request, queue: first.dbQueue) { return text }
                let secondImage = path.contains(second.screenshotId.uuidString.lowercased())
                if secondImage, scenario == "serverChanged" { serverChanged.withLock { $0 = true } }
                let fails = failsSecondImage && secondImage
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
                    connectionID: first.connectionId, disposition: .moveToLocalAccount, screenshotContent: provider,
                    textContent: MeetingContentProvider(client: SyncAPIClient(
                        session: URLSession(configuration: configuration),
                        tokenProvider: { _, _ in "test-token" }
                    ))
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
            if scenario != "success" {
                if failsSecondImage {
                    await #expect(throws: ScreenshotContentError.deleted) { try await moving.value }
                } else {
                    await #expect(throws: TextContentError.changed) { try await moving.value }
                }
                try await first.dbQueue.read { db throws in
                    for vaultId in [first.vaultId, second.vaultId] {
                        #expect(try VaultRecord.fetchOne(db, key: vaultId)?.accountConnectionId == first.connectionId)
                        #expect(try VaultRecord.fetchOne(db, key: vaultId)?.syncPullCursor == "after")
                        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_entity_state WHERE vaultId = ?", arguments: [vaultId])! > 0)
                    }
                }
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
                try db.execute(sql: "UPDATE vaults SET accountConnectionId = NULL, organizationId = NULL WHERE id = ?", arguments: [fixture.vaultId])
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
                    try db.execute(
                        sql: "UPDATE vaults SET accountConnectionId = NULL, organizationId = NULL WHERE id = ?",
                        arguments: [fixture.vaultId]
                    )
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
            let provider = try makeProvider(fixture: fixture, cache: ScreenshotFileStore(directory: root.appending(path: "FileStore"))) { request in
                if let text = cachedTextResponse(request, queue: fixture.dbQueue) { return text }
                calls.withLock { $0 += 1 }
                return (404, [:], Data())
            }
            defer { ImageURLProtocol.remove(origin: fixture.source.origin) }
            let backup = BackupService(dbQueue: fixture.dbQueue, applicationSupportURL: root)
            await #expect(throws: BackupServiceError.localVaultsOnly) { try await backup.createGeneration(vaultIds: [fixture.vaultId]) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let textProvider = MeetingContentProvider(client: SyncAPIClient(
                session: URLSession(configuration: configuration),
                tokenProvider: { _, _ in "test-token" }
            ))
            try await MeetingRepository(dbQueue: fixture.dbQueue).resolveVaultsForSignOut(
                connectionID: fixture.connectionId, disposition: .moveToLocalAccount, screenshotContent: provider, textContent: textProvider
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
                    sql: "UPDATE vaults SET accountConnectionId = NULL, organizationId = NULL, syncRole = NULL, syncConfirmedConnectionId = NULL WHERE id = ?",
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

    /// Canonical text responses for cached bodies and the fixtures' empty transcripts.
    private func cachedTextResponse(_ request: URLRequest, queue: DatabaseQueue) -> (Int, [String: String], Data)? {
        guard let url = request.url else { return nil }
        if url.path.hasSuffix("/capabilities") { return (200, [:], Data("{\"sync\":{\"version\":5}}".utf8)) }
        if url.path.hasSuffix("/changes") {
            return (
                200,
                [:],
                Data("{\"items\":[],\"cursor\":\"after\",\"highWaterCursor\":\"after\",\"hasMore\":false}".utf8)
            )
        }
        if url.path.hasPrefix("/api/v1/files/"), UUID(uuidString: url.lastPathComponent) != nil {
            do {
                let id = try #require(UUID(uuidString: url.lastPathComponent))
                let data = try queue.read { db in
                    let file = try #require(try FileRecord.fetchOne(db, key: id))
                    let source = try #require(try TextContentStore.source(entity: .file, id: id, in: db))
                    let body = try TextContentAccess.cachedFileText(fileId: id, in: db)
                    return try JSONSerialization.data(withJSONObject: [
                        "id": id.uuidString, "vaultId": source.vaultId.uuidString, "revision": source.revision,
                        "checksum": file.checksum, "name": file.name, "contentType": file.contentType, "size": file.size,
                        "createdAt": "2026-09-07T00:00:00Z", "updatedAt": "2026-09-07T00:00:00Z", "metadata": [
                            "source": "screenshot",
                            "ocrText": body?.ocrText as Any? ?? NSNull(),
                            "caption": body?.caption as Any? ?? NSNull(),
                        ],
                    ])
                }
                return (200, [:], data)
            } catch { return (500, [:], Data()) }
        }
        let isLatestSummary = url.path.hasSuffix("/summaries/latest")
        guard isLatestSummary || url.path.hasSuffix("/transcripts/latest") else { return nil }
        do {
            let resourceURL = url.deletingLastPathComponent().deletingLastPathComponent()
            let id = try #require(UUID(uuidString: resourceURL.lastPathComponent))
            let entity: TextContentEntity = isLatestSummary ? .summary : .transcript
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let revision = try queue.read { try #require(try TextContentStore.source(entity: entity, id: id, in: $0)).revision }
            let body = try queue.read { db in try #require(try TextContentStore.fingerprint(entity: entity, id: id, in: db)) }
            let itemCount = body.count
            var json: [String: Any] = [
                "version": 1,
                "entity": entity.rawValue,
                "entityId": id.uuidString,
                entity == .transcript ? "syncRevision" : "revision": revision,
                "formatVersion": 1,
                "present": entity != .summary || itemCount > 0,
                "count": body.count,
                "byteCount": body.bytes,
                "sha256": body.hash,
            ]
            if isLatestSummary {
                json["formatVersion"] = 1
                json["version"] = itemCount > 0 ? 1 : 0
            }
            if query.first(where: { $0.name == "manifest" })?.value != "1", entity == .transcript {
                try #require(itemCount == 0)
                json["items"] = [] as [String]
                json["nextCursor"] = NSNull()
            }
            return try (200, [:], JSONSerialization.data(withJSONObject: json))
        } catch { return (500, [:], Data()) }
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

        init(dbQueue: DatabaseQueue? = nil) throws {
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
            if vault.syncRole == nil { vault.syncRole = "admin" }
            if vault.organizationId == nil { vault.organizationId = .v7() }
            vault.syncConfirmedConnectionId = connectionId
            vault.syncPullCursor = "cursor"
            let meeting = MeetingRecord(id: meetingId, vaultId: vaultId, projectId: nil, name: "Meeting", createdAt: .now, updatedAt: .now)
            try self.dbQueue.write { db in
                try connection.insert(db)
                try vault.insert(db)
                try meeting.insert(db)
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
    final class ImageURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated static func requestJSON(_ request: URLRequest) -> [String: Any]? {
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream, request.httpBody == nil {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bytes.append(buffer, count: count)
                }
            }
            return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        }

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
            do {
                let (status, headers, bytes) = try handler(PublicIDTestClient.internalRequest(request))
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
                let publicBytes = try PublicIDTestClient.publicResponse(bytes, request: request, status: status)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: publicBytes)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }

        override func stopLoading() {}
    }
#endif
