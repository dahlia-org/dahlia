#if canImport(Testing)
    import DahliaMeetingAccess
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    @MainActor
    struct SyncTransferTests {
        @Test(.timeLimit(.minutes(1)))
        func initialSnapshotPublishesAllMeetingContentsBeforeUploadingFiles() async throws {
            let fixture = try SyncTransferFixture()
            defer { fixture.close() }
            let unrelatedAttachmentId = UUID.v7()
            try await fixture.queue.write { db in
                let vaultId = UUID.v7(), meetingId = UUID.v7(), fileId = UUID.v7()
                try VaultRecord(id: vaultId, path: nil, name: "Other", createdAt: .now, lastOpenedAt: .now).insert(db)
                try MeetingRecord(id: meetingId, vaultId: vaultId, projectId: nil, name: "Other", createdAt: .now, updatedAt: .now).insert(db)
                try FileRecord(
                    id: fileId, vaultId: vaultId, size: 0, contentType: "image/png", checksum: "SHA-256:" + String(repeating: "0", count: 64),
                    name: "other.png", metadata: .init(source: .upload), createdAt: .now, updatedAt: .now
                ).insert(db)
                try MeetingAttachmentRecord(
                    id: unrelatedAttachmentId, meetingId: meetingId, fileId: fileId, capturedAt: .now, createdAt: .now
                ).insert(db)
            }
            for _ in 0 ..< 3 {
                let meetingId = try await fixture.addMeeting()
                for _ in 0 ..< 4 {
                    _ = try await fixture.addFile(meetingId: meetingId, enqueue: false)
                }
            }
            try await fixture.queue.write { db in
                try db.execute(sql: "DELETE FROM sync_entity_state")
                try db.execute(sql: "UPDATE vaults SET syncConfirmedConnectionId = NULL, syncPullCursor = NULL")
            }
            try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: fixture.queue)
            let entities = try await fixture.queue.read { db in
                try String.fetchAll(db, sql: """
                SELECT o.entity FROM sync_transactions t JOIN sync_operations o ON o.transactionId = t.id
                ORDER BY t.sequence, o.position
                """)
            }
            let firstFile = try #require(entities.firstIndex(of: "file"))
            let firstAttachment = try #require(entities.firstIndex(of: "meeting_attachment"))
            #expect(entities[..<firstFile].filter { $0 == "meeting" }.count == 3)
            #expect(entities[..<firstFile].filter { $0 == "summary" }.count == 3)
            #expect(entities[..<firstFile].filter { $0 == "transcript" }.count == 3)
            #expect(entities[firstFile ..< firstAttachment].allSatisfy { $0 == "file" })
            let attachmentIds = try await fixture.queue.read { db in
                try UUID.fetchAll(db, sql: """
                SELECT o.entityId FROM sync_operations o JOIN sync_transactions t ON t.id = o.transactionId
                WHERE o.entity = 'meeting_attachment' ORDER BY t.sequence, o.position
                """)
            }
            #expect(attachmentIds.count == 12)
            #expect(!attachmentIds.contains(unrelatedAttachmentId))
            #expect(attachmentIds.map(\.uuidString) == attachmentIds.map(\.uuidString).sorted())
            let worker = fixture.worker()
            try await fixture.drain(worker)
            await worker.stop()
            let events = await fixture.server.events
            let firstUpload = try #require(events.firstIndex(of: "upload"))
            #expect(events[..<firstUpload].filter { $0 == "commit:meeting" }.count == 3)
            #expect(events[..<firstUpload].filter { $0 == "commit:transcript" }.count == 3)
            #expect(await fixture.server.resolveCount == 0)
        }

        @Test(.timeLimit(.minutes(1)))
        func continuingSyncStagesFourFilesAndKeepsCommitOrder() async throws {
            let fixture = try SyncTransferFixture()
            defer { fixture.close() }
            let meeting = try await fixture.addMeeting()
            try await fixture.queue.write { db in
                try RecordingSessionRecord(
                    id: .v7(),
                    meetingId: meeting,
                    startedAt: .now,
                    endedAt: nil,
                    duration: nil,
                    offsetSeconds: 0,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            for _ in 0 ..< 12 {
                _ = try await fixture.addFile()
            }
            await fixture.server.setUploadDelay(.milliseconds(40))
            let ids = try await fixture.queue.read { try UUID.fetchAll($0, sql: "SELECT id FROM sync_transactions ORDER BY sequence") }
            let first = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.queue))
            let candidates = try await fixture.queue.read { try SyncTransactionQueue.fileUploads(for: first, origin: fixture.origin, in: $0) }
            #expect(candidates.count == 8)
            let worker = fixture.worker()
            let response = try #require(try await worker.push(first))
            try await SyncTransactionQueue.complete(first, response: response, dbQueue: fixture.queue)
            try await fixture.drain(worker)
            await worker.stop()
            #expect(await fixture.server.maximumUploads == 4)
            #expect(await fixture.server.commitIds == ids)
            #expect(await fixture.server.uploadCount == 12)
            #expect(await fixture.server.resolveCount == 0)
        }

        @Test(.timeLimit(.minutes(1)), arguments: [false, true])
        func retryResolvesBeforeRestagingAndKeepsTheOriginalRequest(committed: Bool) async throws {
            let fixture = try SyncTransferFixture()
            defer { fixture.close() }
            _ = try await fixture.addFile()
            let first = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.queue))
            let worker = fixture.worker()
            await fixture.server.failNextCommit(afterSaving: committed)
            await #expect(throws: SyncHTTPError.self) { _ = try await worker.push(first) }
            try await SyncTransactionQueue.retry(first, code: "http_503", dbQueue: fixture.queue)
            try await fixture.makeRetryAvailable()
            let retry = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.queue))
            let response = try #require(try await worker.push(retry))
            try await SyncTransactionQueue.complete(retry, response: response, dbQueue: fixture.queue)
            await worker.stop()
            #expect(retry.id == first.id)
            #expect(await fixture.server.resolveCount == 1)
            #expect(await fixture.server.uploadCount == (committed ? 1 : 2))
            #expect(await fixture.server.commitIds == [first.id])
            let requests = await fixture.server.transactionBodies
            #expect(requests.allSatisfy { $0 == requests.first })
        }

        @Test(.timeLimit(.minutes(1)), arguments: ["expiredCursor", "compactReceipt", "recovering"])
        func snapshotRecoveryCanDrainQueuedFiles(boundary: String) async throws {
            let fixture = try SyncTransferFixture()
            defer { fixture.close() }
            for _ in 0 ..< 2 {
                _ = try await fixture.addFile()
            }
            switch boundary {
            case "expiredCursor": await fixture.server.expirePullCursor()
            case "compactReceipt": await fixture.server.useCompactReceipts()
            default: try await fixture.queue.write { try $0.execute(sql: "UPDATE vaults SET syncRecoveryState = 'recovering'") }
            }
            #expect(try await RemoteChangeApplier.recoveryGeneration(
                vaultId: fixture.vaultId, expectedConnectionId: fixture.connectionId, dbQueue: fixture.queue
            ) == nil)
            let worker = fixture.worker()
            await worker.drain()
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                if try await fixture.queue.read({ try !SyncTransactionQueue.hasPending(vaultId: fixture.vaultId, in: $0) }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            await worker.stop()
            #expect(await fixture.server.commitIds.count == 2)
            #expect(try await fixture.queue.read { try !SyncTransactionQueue.hasPending(vaultId: fixture.vaultId, in: $0) })
            #expect(try await RemoteChangeApplier.recoveryGeneration(
                vaultId: fixture.vaultId, expectedConnectionId: fixture.connectionId, dbQueue: fixture.queue
            ) != nil)
            #expect(try await fixture.queue.read { try String.fetchOne($0, sql: "SELECT syncRecoveryState FROM vaults") } != nil)
        }

        @Test(.timeLimit(.minutes(1)), arguments: ["disconnect", "discard", "stop", "authorization", "relocation", "updateRequired"])
        func invalidationCancelsUploadsWithoutAcknowledgingThem(boundary: String) async throws {
            let fixture = try SyncTransferFixture()
            defer { fixture.close() }
            for _ in 0 ..< 8 {
                _ = try await fixture.addFile()
            }
            await fixture.server.setUploadDelay(.seconds(30))
            let worker = fixture.worker()
            let first = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.queue))
            try await worker.prepareFileUploads(for: first, origin: fixture.origin)
            for await count in fixture.server.uploadStarts where count == 4 {
                break
            }
            if boundary == "stop" {
                await worker.stop()
                for await count in fixture.server.uploadCancellations where count == 4 {
                    break
                }
            } else {
                try await fixture.queue.write { db in
                    switch boundary {
                    case "disconnect": try db.execute(sql: "UPDATE vaults SET accountConnectionId = NULL")
                    case "discard": try SyncTransactionQueue.discard(vaultId: fixture.vaultId, in: db)
                    case "authorization": try db.execute(
                            sql: "UPDATE sync_transactions SET blockedReason = 'authorization' WHERE id = ?",
                            arguments: [first.id]
                        )
                    case "relocation": try db.execute(sql: "UPDATE vaults SET syncRecoveryState = 'transferBlocked'")
                    default: try db.execute(sql: "UPDATE vaults SET syncRecoveryState = 'updateRequired'")
                    }
                }
                for await count in fixture.server.uploadCancellations where count == 4 {
                    break
                }
                await worker.stop()
            }
            #expect(await fixture.server.commitIds.isEmpty)
            #expect(await fixture.server.cancelledUploads == 4)
            if boundary != "discard" {
                #expect(try await fixture.queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sync_transactions") } == 8)
            }
        }

        @Test(.timeLimit(.minutes(1)))
        func boundedStagingReducesFixedLatencyTransferTime() async throws {
            let serial = try SyncTransferFixture(), parallel = try SyncTransferFixture()
            defer { serial.close()
                parallel.close()
            }
            for fixture in [serial, parallel] {
                for _ in 0 ..< 8 {
                    _ = try await fixture.addFile()
                }
                await fixture.server.setUploadDelay(.milliseconds(200))
            }
            func measure(_ fixture: SyncTransferFixture, prefetch: Bool) async throws -> Duration {
                let worker = fixture.worker()
                let head = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.queue))
                let candidates = try await fixture.queue.read { try SyncTransactionQueue.fileUploads(for: head, origin: fixture.origin, in: $0) }
                let start = ContinuousClock.now
                if prefetch { try await worker.prepareFileUploads(for: head, origin: fixture.origin) }
                for candidate in candidates {
                    try await worker.stageFileUpload(candidate)
                }
                let duration = start.duration(to: .now)
                await worker.stop()
                return duration
            }
            let serialTime = try await measure(serial, prefetch: false)
            let parallelTime = try await measure(parallel, prefetch: true)
            #expect(await serial.server.maximumUploads == 1)
            #expect(await parallel.server.maximumUploads == 4)
            #expect(parallelTime < serialTime)
            print("Sync upload benchmark (8 files, 200 ms/request): serial=\(serialTime), parallel=\(parallelTime)")
        }

        @Test(.timeLimit(.minutes(1)), arguments: [429, 503, 403, 409])
        func aLaterUploadFailureDoesNotPreventEarlierCommit(status: Int) async throws {
            let fixture = try SyncTransferFixture()
            defer { fixture.close() }
            _ = try await fixture.addFile()
            let later = try await fixture.addFile()
            await fixture.server.failUpload(later.id, status: status)
            let worker = fixture.worker()
            let first = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.queue))
            let response = try #require(try await worker.push(first))
            try await SyncTransactionQueue.complete(first, response: response, dbQueue: fixture.queue)
            let second = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.queue))
            do {
                _ = try await worker.push(second)
                Issue.record("Expected the deferred upload failure")
            } catch let error as SyncHTTPError {
                #expect(error.status == status)
                if let reason = error.blockedReason {
                    try await SyncTransactionQueue.block(second, reason: reason, response: error.body, dbQueue: fixture.queue)
                    #expect(reason == (status == 403 ? .authorization : .conflict))
                } else {
                    try await SyncTransactionQueue.retry(second, code: "http_\(status)", dbQueue: fixture.queue)
                    try await fixture.makeRetryAvailable()
                    let retry = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.queue))
                    let receipt = try #require(try await worker.push(retry))
                    try await SyncTransactionQueue.complete(retry, response: receipt, dbQueue: fixture.queue)
                }
            }
            await worker.stop()
            #expect(await fixture.server.commitIds.first == first.id)
        }

        @Test(.timeLimit(.minutes(1)))
        func expiredStagingIsUploadedAgainBeforeCommit() async throws {
            let fixture = try SyncTransferFixture()
            defer { fixture.close() }
            _ = try await fixture.addFile()
            let worker = fixture.worker()
            let first = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.queue))
            try await worker.prepareFileUploads(for: first, origin: fixture.origin)
            try await worker.ageCompletedUploadsForTesting()
            #expect(await fixture.server.uploadCount == 1)
            let receipt = try #require(try await worker.push(first))
            try await SyncTransactionQueue.complete(first, response: receipt, dbQueue: fixture.queue)
            await worker.stop()
            #expect(await fixture.server.uploadCount == 2)
            #expect(await fixture.server.commitIds == [first.id])
        }

        @Test(.timeLimit(.minutes(1)), arguments: ["delete", "reset", "vault", "retry", "blocked", "sameFile"])
        func lookaheadStopsAtBarriersAndDoesNotStageTheSameFileTwice(boundary: String) async throws {
            let fixture = try SyncTransferFixture()
            defer { fixture.close() }
            let file = try await fixture.addFile()
            if boundary == "sameFile" {
                try await fixture.enqueue(file)
            } else if ["retry", "blocked"].contains(boundary) {
                _ = try await fixture.addFile()
                try await fixture.queue.write { db in
                    let suffix = boundary == "retry" ? "attempts = 1" : "blockedReason = 'validation'"
                    try db.execute(sql: "UPDATE sync_transactions SET \(suffix) WHERE sequence = (SELECT max(sequence) FROM sync_transactions)")
                }
            } else {
                _ = try await fixture.queue.write { db in
                    try SyncTransactionRecorder.record(
                        vaultId: fixture.vaultId,
                        operations: [.init(
                            entity: boundary == "delete" ? .meeting : .vault,
                            action: boundary == "vault" ? .create : boundary == "reset" ? .reset : .delete,
                            entityId: boundary == "delete" ? .v7() : fixture.vaultId
                        )], in: db
                    )
                }
            }
            // Reset blocks new local writes; these cases need only the existing prefix.
            if boundary != "reset" { _ = try await fixture.addFile() }
            let first = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.queue))
            let candidates = try await fixture.queue.read { try SyncTransactionQueue.fileUploads(for: first, origin: fixture.origin, in: $0) }
            #expect(candidates.filter { $0.operation.entityId == file.id }.count == 1)
            #expect(candidates.count == (boundary == "sameFile" ? 2 : 1))
        }
    }

    @MainActor
    private struct SyncTransferFixture {
        let queue: DatabaseQueue
        let vaultId = UUID.v7()
        let connectionId = UUID.v7()
        let origin = URL(string: "https://sync-\(UUID().uuidString.lowercased()).invalid")!
        let server = SyncTransferServer()
        let bytes = Data([1, 2, 3, 4])

        init() throws {
            queue = try AppDatabaseManager(path: ":memory:").dbQueue
            try queue.write { db in
                try DahliaAccountConnectionRecord(id: connectionId, origin: origin.absoluteString, clientID: "test", createdAt: .now).insert(db)
                try VaultRecord(
                    id: vaultId,
                    path: nil,
                    name: "Sync",
                    createdAt: .now,
                    lastOpenedAt: .now,
                    accountConnectionId: connectionId,
                    syncRole: "owner",
                    syncConfirmedConnectionId: connectionId,
                    syncPullCursor: "before"
                ).insert(db)
                try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'vault', ?, 1)", arguments: [vaultId, vaultId])
            }
        }

        func addMeeting() async throws -> UUID {
            let id = UUID.v7()
            try await queue.write { db in
                try MeetingRecord(id: id, vaultId: vaultId, projectId: nil, name: "Meeting", createdAt: .now, updatedAt: .now).insert(db)
                try SummaryContent(meetingId: id, title: "Summary", document: "Text", createdAt: .now).save(db)
                try TranscriptContent(id: .v7(), meetingId: id, startTime: .now, text: "Speech", isConfirmed: true).insert(db)
            }
            return id
        }

        func addFile(meetingId: UUID? = nil, enqueue: Bool = true) async throws -> FileRecord {
            let id = UUID.v7()
            let source = ScreenshotRemoteReference(
                origin: origin.absoluteString,
                accountConnectionId: connectionId,
                fileId: id,
                contentHash: ScreenshotRemoteReference.digest(bytes)
            )
            let file = try FileRecord(
                id: id,
                vaultId: vaultId,
                size: Int64(bytes.count),
                contentType: "image/png",
                checksum: "SHA-256:" + source.contentHash,
                name: "image.png",
                metadata: .init(source: .screenshot),
                createdAt: .now,
                updatedAt: .now,
                localReference: source.jsonString()
            )
            let store = try await ScreenshotContentProvider.shared.fileStore(for: queue)
            try store.write(.init(data: bytes, mimeType: "image/png", variant: .original), source: source, required: true)
            try await queue.write { db in
                try file.insert(db)
                try FileTextBodyRecord(fileId: id, ocrText: nil, caption: nil).insert(db)
                try TextContentStore.registerLocal(entity: .file, id: id, vaultId: vaultId, in: db)
                if let meetingId {
                    try MeetingAttachmentRecord(id: .v7(), meetingId: meetingId, fileId: id, capturedAt: .now, createdAt: .now).insert(db)
                }
            }
            await server.register(file)
            if enqueue { try await self.enqueue(file) }
            return file
        }

        func enqueue(_ file: FileRecord) async throws {
            let source = try JSONDecoder().decode(ScreenshotRemoteReference.self, from: Data(#require(file.localReference).utf8))
            _ = try await queue.write { db in
                let operation = try SyncInitialSnapshotBuilder.fileOperation(file, in: db)
                try SyncTransactionRecorder.record(vaultId: vaultId, operations: [operation], screenshotAttachments: [
                    operation.id: .init(mimeType: file.contentType, source: source),
                ], in: db)
            }
        }

        func close() { _ = SyncTransferURLProtocol.handlers.withLock { $0.removeValue(forKey: origin.host!) } }

        func worker() -> SyncWorker {
            SyncTransferURLProtocol.handlers.withLock { $0[origin.host!] = { [server] in try await server.handle($0) } }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SyncTransferURLProtocol.self]
            let session = URLSession(configuration: configuration)
            return SyncWorker(dbQueue: queue, session: session, apiClient: SyncAPIClient(session: session, tokenProvider: { _, _ in "test" }))
        }

        func drain(_ worker: SyncWorker) async throws {
            while let transaction = try await SyncTransactionQueue.claim(dbQueue: queue) {
                let receipt = try #require(try await worker.push(transaction))
                try await SyncTransactionQueue.complete(transaction, response: receipt, dbQueue: queue)
            }
            #expect(try await queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sync_transactions") } == 0)
        }

        func makeRetryAvailable() async throws {
            try await queue.write { try $0.execute(sql: "UPDATE sync_transactions SET availableAt = ?", arguments: [Date.distantPast]) }
        }
    }

    private actor SyncTransferServer {
        nonisolated let uploadStarts: AsyncStream<Int>
        nonisolated let uploadCancellations: AsyncStream<Int>
        private let started: AsyncStream<Int>.Continuation
        private let cancelled: AsyncStream<Int>.Continuation
        var events: [String] = []
        var commitIds: [UUID] = []
        var transactionBodies: [Data] = []
        var resolveCount = 0
        var uploadCount = 0
        var cancelledUploads = 0
        var maximumUploads = 0
        private var activeUploads = 0
        private var uploadDelay = Duration.zero
        private var commitFailure: Bool?
        private var expiredPullCursor = false
        private var compactReceipts = false
        private var files: [String: FileRecord] = [:]
        private var uploadFailures: [String: Int] = [:]
        private var receipts: [String: Data] = [:]

        init() {
            (uploadStarts, started) = AsyncStream.makeStream(of: Int.self)
            (uploadCancellations, cancelled) = AsyncStream.makeStream(of: Int.self)
        }

        func register(_ file: FileRecord) { files[file.id.uuidString.lowercased()] = file }
        func setUploadDelay(_ delay: Duration) { uploadDelay = delay }
        func failNextCommit(afterSaving: Bool) { commitFailure = afterSaving }
        func failUpload(_ id: UUID, status: Int) { uploadFailures[id.uuidString.lowercased()] = status }
        func expirePullCursor() { expiredPullCursor = true }
        func useCompactReceipts() { compactReceipts = true }

        func handle(_ request: URLRequest) async throws -> (Int, Data) {
            let path = request.url!.path
            if expiredPullCursor {
                if path.hasSuffix("/capabilities") { return (200, Data("{\"sync\":{\"version\":4}}".utf8)) }
                if path.hasSuffix("/changes") { return (410, Data("{\"code\":\"sync_cursor_expired\"}".utf8)) }
            }
            if path == "/api/v1/file-uploads" {
                let id = try #require(ImageURLProtocol.requestJSON(request)?["id"] as? String)
                return try (201, fileResponse(id))
            }
            if path.hasPrefix("/api/v1/file-uploads/"), path.hasSuffix("/content") {
                let id = String(path.split(separator: "/")[3])
                uploadCount += 1
                activeUploads += 1
                maximumUploads = max(maximumUploads, activeUploads)
                events.append("upload")
                started.yield(uploadCount)
                defer { activeUploads -= 1 }
                do {
                    // Deliberate server latency, not a completion barrier for the test.
                    try await Task.sleep(for: uploadDelay)
                } catch {
                    cancelledUploads += 1
                    cancelled.yield(cancelledUploads)
                    throw error
                }
                if let status = uploadFailures.removeValue(forKey: id) { return (status, Data()) }
                return try (201, fileResponse(id))
            }
            if path.contains("/transcript-chunks/") || path.contains("/chunks/") { return (204, Data()) }
            if path == "/api/v1/transactions" || path == "/api/v1/transactions/resolve" {
                let body = try #require(ImageURLProtocol.requestJSON(request))
                let id = try #require(body["id"] as? String)
                try transactionBodies.append(JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
                if path.hasSuffix("/resolve") {
                    resolveCount += 1
                    return try (200, receipts[id] ?? JSONSerialization.data(withJSONObject: ["id": id, "status": "unknown"]))
                }
                if commitFailure == false {
                    commitFailure = nil
                    return (503, Data())
                }
                let operations = try #require(body["operations"] as? [[String: Any]])
                let records: [[String: Any]] = operations.map { operation in
                    ["entity": operation["entity"]!, "id": operation["entityId"]!, "revision": 1, "record": NSNull()]
                }
                var response: [String: Any] = [
                    "id": id, "status": "committed", "cursor": "after", "records": records,
                ]
                if compactReceipts { response["receipt"] = "compact" }
                let receipt = try JSONSerialization.data(withJSONObject: response)
                receipts[id] = receipt
                try commitIds.append(#require(UUID(uuidString: id)))
                events += operations.map { "commit:\($0["entity"]!)" }
                if commitFailure == true {
                    commitFailure = nil
                    return (503, Data())
                }
                return (200, receipt)
            }
            return (503, Data())
        }

        private func fileResponse(_ id: String) throws -> Data {
            let file = try #require(files[id])
            return try JSONSerialization.data(withJSONObject: [
                "id": id, "vaultId": file.vaultId.uuidString, "size": file.size, "checksum": file.checksum,
                "uri": "/files/\(id)", "offset": 0, "contentType": file.contentType, "name": file.name,
                "metadata": ["source": "screenshot"], "revision": 1,
                "createdAt": "2026-09-11T00:00:00Z", "updatedAt": "2026-09-11T00:00:00Z",
            ])
        }
    }

    private extension SyncWorker {
        func ageCompletedUploadsForTesting() async throws {
            for upload in Array(fileUploads.values) {
                try await upload.task.value
            }
            for id in fileUploads.keys {
                fileUploads[id]?.finishedAt = .distantPast
            }
        }
    }

    private final class SyncTransferURLProtocol: URLProtocol, @unchecked Sendable {
        typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data)
        static let handlers = Mutex<[String: Handler]>([:])
        // Foundation invokes start/stop from its queues; the task handle is mutex-protected.
        private let requestTask = Mutex<Task<Void, Never>?>(nil)
        override static func canInit(with _: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let work = Task {
                do {
                    let url = try #require(request.url)
                    let handler = try #require(Self.handlers.withLock { $0[url.host!] })
                    let (status, bytes) = try await handler(PublicIDTestClient.internalRequest(request))
                    try Task.checkCancellation()
                    let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
                    let publicBytes = try PublicIDTestClient.publicResponse(bytes, request: request, status: status)
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: publicBytes)
                    client?.urlProtocolDidFinishLoading(self)
                } catch { client?.urlProtocol(self, didFailWithError: error) }
            }
            requestTask.withLock { $0 = work }
        }

        override func stopLoading() { requestTask.withLock { $0?.cancel() } }
    }
#endif
