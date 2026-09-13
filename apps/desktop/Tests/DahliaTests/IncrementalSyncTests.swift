#if canImport(Testing)
    import CryptoKit
    import DahliaMeetingAccess
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    @MainActor
    struct IncrementalSyncTests {
        @Test
        func resetRechecksRelocationsAfterFetchingAllPages() async throws {
            let fixture = try Fixture()
            let destination = UUID.v7()
            let sessionId = UUID.v7()
            try await fixture.queue.write { db in
                try RecordingSessionRecord(
                    id: sessionId,
                    meetingId: fixture.meetingId,
                    startedAt: .now,
                    endedAt: .now,
                    duration: 1,
                    offsetSeconds: 0,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            let workspace = try fixture.change(
                .workspace,
                id: fixture.workspaceId,
                revision: 2,
                fields: ["name": "Server", "createdAt": "2026-09-09T00:00:00Z"]
            )
            let first = try page(workspaceId: fixture.workspaceId, [.init(
                sequence: 2,
                entity: .workspace,
                entityId: fixture.workspaceId,
                action: "reset",
                revision: 2,
                record: workspace.record
            )], cursor: "middle", more: true)
            let last = try page(workspaceId: fixture.workspaceId, [.init(
                sequence: 3,
                entity: .meeting,
                entityId: fixture.meetingId,
                action: "delete",
                revision: nil,
                record: nil
            )], cursor: "after")
            let relocation = try JSONSerialization.data(withJSONObject: [
                "workspaces": [[
                    "workspaceId": destination.uuidString,
                    "organizationId": destination.uuidString,
                    "name": "Moved",
                    "createdAt": "2026-09-09T00:00:00Z",
                    "updatedAt": "2026-09-09T00:00:00Z",
                    "revision": 1,
                    "role": "admin",
                ]],
                "items": [
                    ["entity": "meeting", "id": fixture.meetingId.uuidString, "workspaceId": destination.uuidString],
                    ["entity": "file", "id": fixture.fileId.uuidString, "workspaceId": destination.uuidString],
                ],
            ])
            let fetchedLastPage = Mutex(false)
            let client = fixture.client { request in
                let path = request.url!.path
                if path.hasSuffix("capabilities") {
                    return (200, [:], Data(#"{"sync":{"version":5},"workspaceTransfers":{"version":1}}"#.utf8))
                }
                if path.hasSuffix("/changes") {
                    if request.url!.query?.contains("cursor=middle") == true {
                        fetchedLastPage.withLock { $0 = true }
                        return (200, [:], last)
                    }
                    return (200, [:], first)
                }
                if path.hasSuffix("/relocations") {
                    return (200, [:], fetchedLastPage.withLock { $0 } ? relocation : Data(#"{"workspaces":[],"items":[]}"#.utf8))
                }
                return (503, [:], Data())
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            await #expect(throws: TextContentError.changed) {
                try await SyncWorker(dbQueue: fixture.queue, apiClient: client).synchronizeForTransfer(
                    workspaceId: fixture.workspaceId, connectionId: fixture.connectionId
                )
            }
            #expect(fetchedLastPage.withLock { $0 })
            try await fixture.queue.read { db throws in
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meetingId)?.workspaceId == destination)
                #expect(try RecordingSessionRecord.fetchOne(db, key: sessionId)?.meetingId == fixture.meetingId)
                #expect(try FileRecord.fetchOne(db, key: fixture.fileId)?.workspaceId == destination)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }

        @Test
        // swiftlint:disable:next function_body_length
        func largeTranscriptSnapshotUploadsWithStableChunkHashes() async throws {
            let fixture = try Fixture()
            let info = TranscriptInfo(id: .v7(), startedAt: nil, endedAt: .now, metadata: nil)
            let transactionId = try await fixture.queue.write { db in
                try db.execute(
                    sql: "INSERT INTO sync_entity_state VALUES (?, 'workspace', ?, 1)",
                    arguments: [fixture.workspaceId, fixture.workspaceId]
                )
                try db.execute(sql: """
                WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n + 1 FROM numbers WHERE n < 50001)
                INSERT INTO transcript_segments(id, meetingId, startedAt, createdAt)
                SELECT printf('019d0000-0000-7000-8000-%012x', n), ?, ?, ? FROM numbers;
                INSERT INTO transcript_segment_bodies(segmentId, text)
                SELECT id, CASE WHEN id <= '019d0000-0000-7000-8000-0000000001f5' THEN ? ELSE 'snapshot text' END
                FROM transcript_segments WHERE meetingId = ?;
                """, arguments: [fixture.meetingId, Date.now, Date.now, String(repeating: "x", count: 13000), fixture.meetingId])
                try TranscriptRecord(meetingId: fixture.meetingId, info: info).save(db)
                try TranscriptRecord.enqueueSnapshot(meetingId: fixture.meetingId, info: info, in: db)
                return try #require(try UUID.fetchOne(db, sql: "SELECT id FROM sync_transactions"))
            }
            let operationId = try await fixture.queue.read { try #require(try UUID.fetchOne($0, sql: "SELECT id FROM sync_operations")) }
            let expected = try await SyncWorker.transcriptChunks(
                SyncTransactionQueue.transcriptPatch(operationId: operationId, dbQueue: fixture.queue)
            )
            let expectedManifest = try expected.map { chunk in
                try SHA256.hash(data: PublicIDWire.data(chunk.data, shape: "chunk", direction: .encode)).map { String(format: "%02x", $0) }.joined()
            }
            let manifests = Mutex<[Data]>([])
            let uploadedHashes = Mutex<[String]>([])
            let receipt = try JSONSerialization.data(withJSONObject: [
                "id": transactionId.uuidString, "status": "committed", "cursor": "after",
                "records": [["entity": "transcript", "id": fixture.meetingId.uuidString, "revision": 1, "record": NSNull()]],
            ])
            let client = fixture.client { request in
                let body = Self.requestBody(request)
                if request.url?.path == "/api/v1/transactions/resolve" {
                    manifests.withLock { $0.append(body) }
                    return (200, [:], Data("{\"id\":\"\(transactionId)\",\"status\":\"unknown\"}".utf8))
                }
                if request.httpMethod == "PUT" {
                    #expect(body.count <= 6 * 1024 * 1024)
                    guard let publicBody = try? PublicIDWire.data(body, shape: "chunk", direction: .encode) else {
                        Issue.record("Invalid transcript chunk")
                        return (400, [:], Data())
                    }
                    let hash = SHA256.hash(data: publicBody).map { String(format: "%02x", $0) }.joined()
                    #expect(request.value(forHTTPHeaderField: "X-Dahlia-Content-SHA256") == hash)
                    uploadedHashes.withLock { $0.append(hash) }
                    return (204, [:], Data())
                }
                if request.url?.path == "/api/v1/transactions" {
                    manifests.withLock { $0.append(body) }
                    return (200, [:], receipt)
                }
                return (503, [:], Data())
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            let worker = SyncWorker(dbQueue: fixture.queue, apiClient: client)
            let outcomes = ValueObservation.tracking { db in
                try String.fetchOne(db, sql: """
                SELECT coalesce(blockedReason, serverResponseJSON, 'pending') FROM sync_transactions WHERE id = ?
                """, arguments: [transactionId])
            }.values(in: fixture.queue)
            await worker.drain()
            for try await outcome in outcomes where outcome != "pending" {
                break
            }
            await worker.stop()
            #expect(try await fixture.queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sync_transactions") } == 0)
            #expect(uploadedHashes.withLock { $0 } == expectedManifest)
            let bodies = manifests.withLock { $0 }
            #expect(bodies.count == 1)
            let committed = try #require(bodies.first)
            let request = try #require(JSONSerialization.jsonObject(with: committed) as? [String: Any])
            let operations = try #require(request["operations"] as? [[String: Any]])
            let data = try #require(operations.first?["data"] as? [String: Any])
            #expect(data["segmentCount"] as? Int == 50001)
            #expect((data["chunks"] as? [Any])?.count == expected.count)
        }

        @Test(arguments: ["committed", "unknown"])
        func transferResolvesRetriesBeforeProtectingPendingChanges(status: String) async throws {
            let fixture = try Fixture()
            try await fixture.queue.write { db in
                try db.execute(
                    sql: "INSERT INTO sync_entity_state VALUES (?, 'workspace', ?, 1)",
                    arguments: [fixture.workspaceId, fixture.workspaceId]
                )
            }
            try await fixture.queueFile()
            try await fixture.queue.write { db in
                try db.execute(sql: "UPDATE sync_transactions SET attempts = 1")
            }
            let transactionId = try await fixture.queue.read { try #require(try UUID.fetchOne($0, sql: "SELECT id FROM sync_transactions")) }
            let destination = UUID.v7()
            let relocation = try JSONSerialization.data(withJSONObject: [
                "workspaces": [[
                    "workspaceId": destination.uuidString,
                    "organizationId": destination.uuidString,
                    "name": "Moved",
                    "createdAt": "2026-09-09T00:00:00Z",
                    "updatedAt": "2026-09-09T00:00:00Z",
                    "revision": 1,
                    "role": "admin",
                ]],
                "items": [["entity": "meeting", "id": fixture.meetingId.uuidString, "workspaceId": destination.uuidString]],
            ])
            let receipt = try JSONSerialization.data(withJSONObject: [
                "id": transactionId.uuidString, "status": status, "cursor": "after",
                "records": [["entity": "file", "id": fixture.fileId.uuidString, "revision": 2, "record": NSNull()]],
            ])
            let requests = Mutex<[String]>([])
            let changes = try page(workspaceId: fixture.workspaceId, [], cursor: "before")
            let client = fixture.client { request in
                let path = request.url!.path
                requests.withLock { $0.append(path) }
                if path.hasSuffix("capabilities") {
                    return (200, [:], Data("{\"sync\":{\"version\":5},\"workspaceTransfers\":{\"version\":1}}".utf8))
                }
                if path.hasSuffix("/changes") { return (200, [:], changes) }
                if path.hasSuffix("/relocations") { return (200, [:], relocation) }
                if path.hasSuffix("/resolve") { return (200, [:], receipt) }
                return (503, [:], Data())
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            let worker = SyncWorker(dbQueue: fixture.queue, apiClient: client)
            await worker.drain()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline {
                let pending = try await fixture.queue.read { db in
                    try String.fetchOne(
                        db,
                        sql: "SELECT coalesce(blockedReason, 'pending') FROM sync_transactions WHERE id = ?",
                        arguments: [transactionId]
                    )
                }
                if pending != "pending" { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            await worker.stop()
            let paths = requests.withLock { $0 }
            #expect(paths.contains("/api/v1/transactions/resolve"))
            #expect(!paths.contains("/api/v1/transactions"))
            try await fixture.queue.read { db throws in
                #expect(try SyncTransactionQueue.hasPending(workspaceId: fixture.workspaceId, in: db) == (status == "unknown"))
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meetingId)?.workspaceId == fixture.workspaceId)
            }
        }

        @Test
        func unavailableRelocationDoesNotStarveAnotherWorkspace() async throws {
            let fixture = try Fixture()
            let healthy = UUID.v7()
            let transactionId = try await fixture.queue.write { db in
                try db.execute(
                    sql: "INSERT INTO sync_entity_state VALUES (?, 'workspace', ?, 1)",
                    arguments: [fixture.workspaceId, fixture.workspaceId]
                )
                var workspace = WorkspaceRecord(id: healthy, path: nil, name: "Healthy", createdAt: .now, lastOpenedAt: .now)
                workspace.accountConnectionId = fixture.connectionId
                if workspace.syncRole == nil { workspace.syncRole = "admin" }
                if workspace.organizationId == nil { workspace.organizationId = .v7() }
                workspace.syncConfirmedConnectionId = fixture.connectionId
                workspace.syncPullCursor = "before"
                try workspace.insert(db)
                try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'workspace', ?, 1)", arguments: [healthy, healthy])
                try SyncTransactionRecorder.record(
                    workspaceId: healthy,
                    operations: [SyncInitialSnapshotBuilder.workspaceOperation(workspace, action: .update)],
                    in: db
                )
                return try #require(try UUID.fetchOne(db, sql: "SELECT id FROM sync_transactions"))
            }
            let receipt = try JSONSerialization.data(withJSONObject: [
                "id": transactionId.uuidString, "status": "committed", "cursor": "after",
                "records": [["entity": "workspace", "id": healthy.uuidString, "revision": 2, "record": NSNull()]],
            ])
            let changes = try page(workspaceId: fixture.workspaceId, [], cursor: "before")
            let healthyPulls = Mutex(0)
            let paths = Mutex<[String]>([])
            let client = fixture.client { request in
                let path = request.url!.path
                paths.withLock { $0.append(path) }
                if path.hasSuffix("capabilities") {
                    return (200, [:], Data("{\"sync\":{\"version\":5},\"workspaceTransfers\":{\"version\":1}}".utf8))
                }
                if path.contains(fixture.workspaceId.uuidString.lowercased()) {
                    if path.hasSuffix("/relocations") { return (403, [:], Data("{\"code\":\"transfer_access_required\"}".utf8)) }
                    return (404, [:], Data("{\"code\":\"workspace_not_found\"}".utf8))
                }
                if path.hasSuffix("/changes") {
                    healthyPulls.withLock { $0 += 1 }
                    return (200, [:], changes)
                }
                if path.hasSuffix("/relocations") { return (200, [:], Data("{\"workspaces\":[],\"items\":[]}".utf8)) }
                if path == "/api/v1/transactions" { return (200, [:], receipt) }
                return (503, [:], Data())
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            let worker = SyncWorker(dbQueue: fixture.queue, apiClient: client)
            await worker.drain()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline {
                if try await fixture.queue.read({ try !SyncTransactionQueue.hasPending(workspaceId: healthy, in: $0) }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            await worker.stop()
            #expect(healthyPulls.withLock { $0 } > 0)
            let seen = paths.withLock { $0 }
            #expect(seen.contains("/api/v1/workspaces/\(fixture.workspaceId.uuidString.lowercased())/relocations"))
            try await fixture.queue.read { db throws in
                #expect(try !SyncTransactionQueue.hasPending(workspaceId: healthy, in: db))
                let state = try WorkspaceRecord.fetchOne(db, key: fixture.workspaceId)?.syncRecoveryState
                #expect(state == "transferBlocked")
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meetingId) != nil)
            }
        }

        @Test
        func capabilityRemovalStopsRelocationPollingAndAppliesChanges() async throws {
            let fixture = try Fixture()
            let initialPage = try page(workspaceId: fixture.workspaceId, [], cursor: "middle")
            let changedPage = try page(workspaceId: fixture.workspaceId, [fixture.fileChange(revision: 2)], cursor: "after")
            let capabilityRequestCount = Mutex(0)
            let changeRequestCount = Mutex(0)
            let relocationRequestCount = Mutex(0)
            let client = fixture.client { request in
                let path = request.url!.path
                if path.hasSuffix("capabilities") {
                    let requestNumber = capabilityRequestCount.withLock { count in
                        count += 1
                        return count
                    }
                    if requestNumber == 1 {
                        return (200, [:], Data(#"{"sync":{"version":5},"workspaceTransfers":{"version":1}}"#.utf8))
                    }
                    return (200, [:], Data(#"{"sync":{"version":5}}"#.utf8))
                }
                if path.hasSuffix("/changes") {
                    let requestNumber = changeRequestCount.withLock { count in
                        count += 1
                        return count
                    }
                    return (200, [:], requestNumber == 1 ? initialPage : changedPage)
                }
                if path.hasSuffix("/relocations") {
                    relocationRequestCount.withLock { count in
                        count += 1
                    }
                    return (200, [:], Data(#"{"workspaces":[],"items":[]}"#.utf8))
                }
                return (503, [:], Data())
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            let worker = SyncWorker(dbQueue: fixture.queue, apiClient: client)
            try await worker.synchronizeForTransfer(workspaceId: fixture.workspaceId, connectionId: fixture.connectionId)
            try await worker.synchronizeForTransfer(workspaceId: fixture.workspaceId, connectionId: fixture.connectionId)
            #expect(capabilityRequestCount.withLock { $0 } == 2)
            #expect(relocationRequestCount.withLock { $0 } == 1)
            try await fixture.queue.read { db throws in
                #expect(try Int.fetchOne(
                    db,
                    sql: "SELECT confirmedRevision FROM sync_entity_state WHERE entity = 'file' AND entityId = ?",
                    arguments: [fixture.fileId]
                ) == 2)
                #expect(try String.fetchOne(
                    db,
                    sql: "SELECT syncPullCursor FROM workspaces WHERE id = ?",
                    arguments: [fixture.workspaceId]
                ) == "after")
            }
        }

        @Test
        func eventCapabilityRefreshStopsStaleRelocationPolling() async throws {
            let fixture = try Fixture()
            let initialPage = try page(workspaceId: fixture.workspaceId, [], cursor: "middle")
            let capabilityRequestCount = Mutex(0)
            let relocationRequestCount = Mutex(0)
            let receipt = Mutex<Data?>(nil)
            let client = fixture.client { request in
                let path = request.url!.path
                if path.hasSuffix("capabilities") {
                    let requestNumber = capabilityRequestCount.withLock { count in
                        count += 1
                        return count
                    }
                    return requestNumber == 1
                        ? (200, [:], Data(#"{"sync":{"version":5},"meetingEvents":{"version":1},"workspaceTransfers":{"version":1}}"#.utf8))
                        : (200, [:], Data(#"{"sync":{"version":5},"meetingEvents":{"version":1}}"#.utf8))
                }
                if path.hasSuffix("/changes") { return (200, [:], initialPage) }
                if path.hasSuffix("/relocations") {
                    let requestNumber = relocationRequestCount.withLock { count in
                        count += 1
                        return count
                    }
                    return requestNumber == 1
                        ? (200, [:], Data(#"{"workspaces":[],"items":[]}"#.utf8))
                        : (503, [:], Data())
                }
                if path == "/api/v1/transactions", let receipt = receipt.withLock({ $0 }) { return (200, [:], receipt) }
                return (503, [:], Data())
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            let worker = SyncWorker(dbQueue: fixture.queue, apiClient: client)
            try await worker.synchronizeForTransfer(workspaceId: fixture.workspaceId, connectionId: fixture.connectionId)
            try await fixture.queue.write { db in
                try MeetingEventRecorder.record(.tagAdded, meetingId: fixture.meetingId, relatedId: "tag", in: db)
            }
            let transaction = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.queue))
            let operation = try #require(transaction.operations.first)
            receipt.withLock { value in
                value = Data(
                    #"{"id":"\#(transaction.id)","status":"committed","cursor":"event","records":[{"entity":"meeting_event","id":"\#(operation.entityId)","revision":null,"record":null}]}"#
                        .utf8
                )
            }
            let response = try await worker.push(transaction)
            #expect(response?.id == transaction.id)
            #expect(capabilityRequestCount.withLock { $0 } == 2)
            #expect(relocationRequestCount.withLock { $0 } == 1)
        }

        @Test(arguments: [false, true])
        func transferBlockSurvivesCapabilityRemoval(pendingEvent: Bool) async throws {
            let fixture = try Fixture()
            let queued = try await fixture.queue.write { db -> (transaction: UUID, operation: UUID)? in
                try db.execute(sql: "UPDATE workspaces SET syncMeetingEventsVersion = 1 WHERE id = ?", arguments: [fixture.workspaceId])
                try db.execute(
                    sql: "INSERT INTO sync_entity_state VALUES (?, 'workspace', ?, 1)",
                    arguments: [fixture.workspaceId, fixture.workspaceId]
                )
                let result: (UUID, UUID)?
                if pendingEvent {
                    try MeetingEventRecorder.record(.tagAdded, meetingId: fixture.meetingId, relatedId: "tag", in: db)
                    result = try Row.fetchOne(db, sql: """
                    SELECT t.id, o.entityId FROM sync_transactions t
                    JOIN sync_operations o ON o.transactionId = t.id WHERE o.entity = 'meeting_event'
                    """).map { ($0["id"], $0["entityId"]) }
                } else {
                    result = nil
                }
                try db.execute(sql: "UPDATE workspaces SET syncRecoveryState = 'transferBlocked' WHERE id = ?", arguments: [fixture.workspaceId])
                return result
            }
            let capabilityRequests = Mutex(0)
            let changeRequests = Mutex(0)
            let relocationRequests = Mutex(0)
            let commits = Mutex(0)
            let client = fixture.client { request in
                let path = request.url!.path
                if path.hasSuffix("capabilities") {
                    capabilityRequests.withLock { $0 += 1 }
                    return (200, [:], Data(#"{"sync":{"version":5},"meetingEvents":{"version":1}}"#.utf8))
                }
                if path.hasSuffix("/changes") {
                    changeRequests.withLock { $0 += 1 }
                    return (404, [:], Data(#"{"code":"workspace_not_found"}"#.utf8))
                }
                if path.hasSuffix("/relocations") {
                    relocationRequests.withLock { $0 += 1 }
                    return (503, [:], Data())
                }
                if path == "/api/v1/transactions", let queued {
                    commits.withLock { $0 += 1 }
                    return (
                        200,
                        [:],
                        Data(
                            #"{"id":"\#(queued.transaction)","status":"committed","cursor":"event","records":[{"entity":"meeting_event","id":"\#(queued.operation)","revision":null,"record":null}]}"#
                                .utf8
                        )
                    )
                }
                return (503, [:], Data())
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            let worker = SyncWorker(dbQueue: fixture.queue, apiClient: client)
            await worker.drain()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline, changeRequests.withLock({ $0 }) == 0, commits.withLock({ $0 }) == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
            await worker.stop()
            #expect(capabilityRequests.withLock { $0 } > 0)
            #expect(changeRequests.withLock { $0 } == 0)
            #expect(relocationRequests.withLock { $0 } == 0)
            #expect(commits.withLock { $0 } == 0)
            try await fixture.queue.read { db throws in
                let workspace = try #require(try WorkspaceRecord.fetchOne(db, key: fixture.workspaceId))
                #expect(workspace.syncConfirmedConnectionId == fixture.connectionId)
                #expect(workspace.syncPullCursor == "before")
                #expect(workspace.syncRecoveryState == "transferBlocked")
                #expect(try SyncTransactionQueue.hasPending(workspaceId: fixture.workspaceId, in: db) == pendingEvent)
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meetingId) != nil)
                #expect(try FileRecord.fetchOne(db, key: fixture.fileId) != nil)
            }
        }

        @Test
        func cursorlessTransferBlockReconcilesBeforeResumingQueuedWrites() async throws {
            let fixture = try Fixture()
            try await fixture.queue.write { db in
                try db.execute(
                    sql: """
                    UPDATE workspaces SET syncMeetingEventsVersion = 1, syncPullCursor = NULL,
                        syncRecoveryState = 'transferBlocked' WHERE id = ?
                    """,
                    arguments: [fixture.workspaceId]
                )
                try db.execute(
                    sql: "INSERT INTO sync_entity_state VALUES (?, 'workspace', ?, 1)",
                    arguments: [fixture.workspaceId, fixture.workspaceId]
                )
                try MeetingEventRecorder.record(.tagAdded, meetingId: fixture.meetingId, relatedId: "tag", in: db)
            }
            let relocationRequests = Mutex(0)
            let client = fixture.client { request in
                let path = request.url!.path
                if path.hasSuffix("capabilities") {
                    return (200, [:], Data(#"{"sync":{"version":5},"meetingEvents":{"version":1},"workspaceTransfers":{"version":1}}"#.utf8))
                }
                if path.hasSuffix("/relocations") {
                    relocationRequests.withLock { $0 += 1 }
                    return (200, [:], Data(#"{"workspaces":[],"items":[]}"#.utf8))
                }
                return (503, [:], Data())
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            let worker = SyncWorker(dbQueue: fixture.queue, apiClient: client)
            #expect(try await worker.pullRemoteChanges(workspaceId: fixture.workspaceId, connectionId: fixture.connectionId))
            #expect(relocationRequests.withLock { $0 } == 1)
            let transaction = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.queue))
            #expect(transaction.operations.allSatisfy { $0.entity == .meetingEvent })
            #expect(try await fixture.queue.read { try String.fetchOne($0, sql: "SELECT syncRecoveryState FROM workspaces") } == "pending")
        }

        private nonisolated static func requestBody(_ request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            return body
        }

        @Test
        func protectedTranscriptDoesNotBlockLaterPagesAndRestartReplaysTheGap() async throws {
            let fixture = try Fixture()
            try await fixture.queueTranscript(recording: true)
            let transcript = try fixture.change(.transcript, id: fixture.meetingId, revision: 2, fields: [
                "contentOmitted": true, "contentPresent": true, "contentCount": 1,
            ])
            let first = try page(workspaceId: fixture.workspaceId, [transcript], cursor: "middle", more: true)
            let second = try page(workspaceId: fixture.workspaceId, [fixture.fileChange(revision: 2)], cursor: "after")
            let cursors = Mutex<[String]>([])
            let client = fixture.client { request in
                if request.url!.path.hasSuffix("capabilities") { return (
                    200,
                    [:],
                    Data("{\"sync\":{\"version\":5},\"meetingEvents\":{\"version\":1}}".utf8)
                ) }
                let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "cursor" }!.value!
                cursors.withLock { $0.append(cursor) }
                return (200, [:], cursor == "before" ? first : second)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            for _ in 0 ..< 2 {
                // A fresh worker models restart: only the durable cursor and entity state survive.
                let worker = SyncWorker(dbQueue: fixture.queue, apiClient: client)
                await #expect(throws: TextContentError.changed) {
                    try await worker.synchronizeForTransfer(workspaceId: fixture.workspaceId, connectionId: fixture.connectionId)
                }
                try await fixture.queue.read { db throws in
                    #expect(try String.fetchOne(db, sql: "SELECT syncPullCursor FROM workspaces") == "before")
                    #expect(try Int.fetchOne(db, sql: "SELECT confirmedRevision FROM sync_entity_state WHERE entity = 'file'") == 2)
                    #expect(try Int.fetchOne(db, sql: "SELECT confirmedRevision FROM sync_entity_state WHERE entity = 'transcript'") == 1)
                    #expect(try String.fetchOne(db, sql: "SELECT text FROM transcript_segment_bodies") == "local recording")
                    #expect(try SyncTransactionQueue.hasPending(workspaceId: fixture.workspaceId, in: db))
                }
            }
            #expect(cursors.withLock { $0 } == ["before", "middle", "before", "middle"])
            let sent = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.queue))
            try await fixture.queue.write { db in try db.execute(sql: "UPDATE recording_sessions SET endedAt = ?", arguments: [Date()]) }
            try await SyncTransactionQueue.complete(sent, response: .init(
                id: sent.id, status: "committed", cursor: "ack", records: [.init(
                    entity: .transcript,
                    id: fixture.meetingId,
                    revision: 2,
                    record: nil
                )]
            ), dbQueue: fixture.queue)
            try await SyncWorker(dbQueue: fixture.queue, apiClient: client).synchronizeForTransfer(
                workspaceId: fixture.workspaceId,
                connectionId: fixture.connectionId
            )
            #expect(try await fixture.queue.read { try String.fetchOne($0, sql: "SELECT syncPullCursor FROM workspaces") } == "after")
            #expect(try await fixture.queue.read { try String.fetchOne($0, sql: "SELECT text FROM transcript_segment_bodies") } == "local recording")
        }

        @Test(arguments: ["queued", "sending", "conflict"])
        func aProtectedFileIsDeferredButAnUnrelatedMeetingIsApplied(state: String) async throws {
            let fixture = try Fixture()
            try await fixture.queueFile()
            if state != "queued" {
                let transaction = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.queue))
                if state == "conflict" {
                    try await SyncTransactionQueue.block(transaction, reason: .conflict, response: Data("{}".utf8), dbQueue: fixture.queue)
                }
            }
            let other = UUID.v7()
            let changes = try page(workspaceId: fixture.workspaceId, [
                fixture.fileChange(revision: 2),
                fixture.change(.meeting, id: other, revision: 1, fields: [
                    "name": "Other meeting", "status": "READY", "createdAt": "2026-09-07T00:00:00Z", "updatedAt": "2026-09-07T00:00:00Z",
                ]),
            ], cursor: "after")
            let client = fixture.client { request in
                (
                    200,
                    [:],
                    request.url!.path.hasSuffix("capabilities") ? Data("{\"sync\":{\"version\":5},\"meetingEvents\":{\"version\":1}}".utf8) : changes
                )
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            await #expect(throws: TextContentError.changed) {
                try await SyncWorker(dbQueue: fixture.queue, apiClient: client).synchronizeForTransfer(
                    workspaceId: fixture.workspaceId,
                    connectionId: fixture.connectionId
                )
            }
            try await fixture.queue.read { db throws in
                #expect(try String.fetchOne(db, sql: "SELECT syncPullCursor FROM workspaces") == "before")
                #expect(try Int.fetchOne(db, sql: "SELECT confirmedRevision FROM sync_entity_state WHERE entity = 'file'") == 1)
                #expect(try MeetingRecord.fetchOne(db, key: other)?.name == "Other meeting")
            }
        }

        @Test(arguments: ["ack", "reconnect", "recovery", "cancel"])
        func inFlightReadsCannotOutliveTheirProtectionOrOverlapAnotherWorker(boundary: String) async throws {
            let fixture = try Fixture()
            if boundary == "ack" { try await fixture.queueFile() }
            let gate = Gate()
            let changes = try page(workspaceId: fixture.workspaceId, [fixture.fileChange(revision: 2, action: "delete")], cursor: "after")
            var client = fixture.client { request in
                (
                    200,
                    [:],
                    request.url!.path.hasSuffix("capabilities") ? Data("{\"sync\":{\"version\":5},\"meetingEvents\":{\"version\":1}}".utf8) : changes
                )
            }
            client.tokenProvider = { _, _ in await gate.wait()
                return "test"
            }
            let worker = SyncWorker(dbQueue: fixture.queue, apiClient: client)
            let task = Task { try await worker.synchronizeForTransfer(workspaceId: fixture.workspaceId, connectionId: fixture.connectionId) }
            await gate.waitUntilStarted()
            await #expect(throws: TextContentError.changed) {
                try await SyncWorker(dbQueue: fixture.queue, apiClient: client).synchronizeForTransfer(
                    workspaceId: fixture.workspaceId,
                    connectionId: fixture.connectionId
                )
            }
            if boundary == "ack" {
                let sent = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.queue))
                try await SyncTransactionQueue.complete(sent, response: .init(
                    id: sent.id, status: "committed", cursor: "ack", records: [.init(entity: .file, id: fixture.fileId, revision: 3, record: nil)]
                ), dbQueue: fixture.queue)
            } else if boundary == "reconnect" {
                try await fixture.queue.write { db in
                    try db.execute(sql: "UPDATE workspaces SET syncConfirmedConnectionId = NULL")
                    try db.execute(sql: "UPDATE workspaces SET syncConfirmedConnectionId = ?", arguments: [fixture.connectionId])
                }
            } else if boundary == "recovery" {
                try await fixture.queue.write { db in try db.execute(sql: "UPDATE workspaces SET syncRecoveryState = 'pending'") }
            } else {
                task.cancel()
            }
            await gate.release()
            do {
                try await task.value
                Issue.record("An invalidated read must not succeed")
            } catch {}
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            try await fixture.queue.read { db throws in
                #expect(try FileRecord.fetchOne(db, key: fixture.fileId) != nil)
                #expect(try String.fetchOne(db, sql: "SELECT syncPullCursor FROM workspaces") == "before")
                #expect(try Int
                    .fetchOne(db, sql: "SELECT confirmedRevision FROM sync_entity_state WHERE entity = 'file'") == (boundary == "ack" ? 3 : 1))
            }
        }

        @Test
        func revisionsTombstonesAndRecordingOwnershipUseTheSamePolicy() async throws {
            #expect(!ScreenshotOCRState.remote(ocrText: "cached", caption: "cached", state: .stale).isTerminal)
            let fixture = try Fixture()
            try await fixture.queueTranscript(recording: true)
            var context = try await fixture.context()
            let update = try fixture.fileChange(revision: 3)
            #expect(try await RemoteChangeApplier.applyIncremental(update, context: context, dbQueue: fixture.queue) == .applied)
            #expect(try await RemoteChangeApplier
                .applyIncremental(fixture.fileChange(revision: 2), context: context, dbQueue: fixture.queue) == .retry)
            #expect(try await RemoteChangeApplier.applyIncremental(update, context: context, dbQueue: fixture.queue) == .alreadyApplied)
            #expect(try await RemoteChangeApplier.applyIncremental(
                fixture.fileChange(revision: nil, action: "delete"),
                context: context,
                dbQueue: fixture.queue
            ) == .deferred)
            let replacement = try fixture.fileChange(revision: 4, checksum: "SHA-256:" + String(repeating: "b", count: 64))
            #expect(try await RemoteChangeApplier.applyIncremental(replacement, context: context, dbQueue: fixture.queue) == .deferred)
            let other = UUID.v7()
            try await fixture.queue.write { db in
                try MeetingRecord(id: other, workspaceId: fixture.workspaceId, projectId: nil, name: "Other", createdAt: .now, updatedAt: .now)
                    .insert(db)
            }
            let transcript = try fixture.change(
                .transcript,
                id: other,
                revision: 1,
                fields: ["contentOmitted": true, "contentPresent": true, "contentCount": 0]
            )
            #expect(try await RemoteChangeApplier.applyIncremental(transcript, context: context, dbQueue: fixture.queue) == .applied)
            #expect(try await RemoteChangeApplier.applyIncremental(
                .init(sequence: 4, entity: .meeting, entityId: fixture.meetingId, action: "delete", revision: nil, record: nil),
                context: context, dbQueue: fixture.queue
            ) == .deferred)
            #expect(try await RemoteChangeApplier.applyIncremental(
                .init(sequence: 5, entity: .meeting, entityId: other, action: "delete", revision: nil, record: nil),
                context: context, dbQueue: fixture.queue
            ) == .applied)
            try await fixture.queue.write { db in
                try db.execute(sql: "UPDATE recording_sessions SET endedAt = ?", arguments: [Date()])
                try SyncTransactionQueue.discard(workspaceId: fixture.workspaceId, in: db)
                try db.execute(sql: "DELETE FROM meeting_attachments WHERE fileId = ?", arguments: [fixture.fileId])
            }
            context = try await fixture.context()
            #expect(try await RemoteChangeApplier.applyIncremental(
                fixture.fileChange(revision: nil, action: "delete"),
                context: context,
                dbQueue: fixture.queue
            ) == .applied)
            #expect(try await fixture.queue.read { try FileRecord.fetchOne($0, key: fixture.fileId) } == nil)
            // The server can recreate an ID at revision 1; a NULL deletion is not a numeric maximum.
            #expect(try await RemoteChangeApplier
                .applyIncremental(fixture.fileChange(revision: 1), context: context, dbQueue: fixture.queue) == .applied)
            #expect(try await fixture.queue.read { try FileRecord.fetchOne($0, key: fixture.fileId) } != nil)
        }

        @Test(arguments: [false, true])
        func lowerCanonicalRevisionUsesSnapshotRecoveryWithoutOverwritingRecording(recording: Bool) async throws {
            let fixture = try Fixture()
            try await fixture.queue.write { db in try db.execute(sql: "UPDATE sync_entity_state SET confirmedRevision = 3 WHERE entity = 'file'") }
            if recording { try await fixture.queueTranscript(recording: true) }
            let file = try fixture.fileChange(revision: 1)
            let lower = try page(workspaceId: fixture.workspaceId, [file], cursor: "after")
            let empty = try page(workspaceId: fixture.workspaceId, [], cursor: "after")
            let meeting = try fixture.change(.meeting, id: fixture.meetingId, revision: 1, fields: [
                "name": "Restored", "status": "READY", "createdAt": "2026-09-07T00:00:00Z", "updatedAt": "2026-09-07T00:00:00Z",
                "contentOmitted": true, "hasSummary": false, "contentCount": 0,
            ])
            let link = try fixture.change(.meetingAttachment, id: fixture.fileId, revision: 1, fields: [
                "meetingId": fixture.meetingId.uuidString, "fileId": fixture.fileId.uuidString, "createdAt": "2026-09-07T00:00:00Z",
            ])
            let records = try [meeting, file, link].map { try wireChange($0, workspaceId: fixture.workspaceId) }
            let snapshot = try JSONSerialization.data(withJSONObject: [
                "items": records.map { row in var value = row
                    value["id"] = value.removeValue(forKey: "entityId")
                    return value
                },
                "startCursor": "after", "nextCursor": NSNull(),
            ])
            let snapshots = Mutex(0)
            let client = fixture.client { request in
                if request.url!.path.hasSuffix("capabilities") { return (
                    200,
                    [:],
                    Data("{\"sync\":{\"version\":5},\"meetingEvents\":{\"version\":1}}".utf8)
                ) }
                if request.url!.path.hasSuffix("snapshot") {
                    snapshots.withLock { $0 += 1 }
                    return (200, [:], snapshot)
                }
                return (200, [:], request.url!.query!.contains("cursor=before") ? lower : empty)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            await #expect(throws: TextContentError.changed) {
                try await SyncWorker(dbQueue: fixture.queue, apiClient: client).synchronizeForTransfer(
                    workspaceId: fixture.workspaceId,
                    connectionId: fixture.connectionId
                )
            }
            #expect(snapshots.withLock { $0 } == (recording ? 0 : 1))
            try await fixture.queue.read { db throws in
                #expect(try Int.fetchOne(db, sql: "SELECT confirmedRevision FROM sync_entity_state WHERE entity = 'file'") == (recording ? 3 : 1))
                #expect(try String.fetchOne(db, sql: "SELECT syncRecoveryState FROM workspaces") == (recording ? "pending" : nil))
                if recording { #expect(try String.fetchOne(db, sql: "SELECT text FROM transcript_segment_bodies") == "local recording") }
            }
        }

        @Test
        func equalProjectRevisionStillReconcilesRecreatedProject() async throws {
            let fixture = try Fixture()
            let projectId = UUID.v7()
            try await fixture.queue.write { db in
                try ProjectRecord(
                    id: projectId, workspaceId: fixture.workspaceId, parentProjectId: nil,
                    name: "Old", createdAt: .now, projectType: .undefined
                ).insert(db)
                try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'project', ?, 1)", arguments: [fixture.workspaceId, projectId])
            }
            let fields: [String: Any] = [
                "projectId": projectId.uuidString, "workspaceId": fixture.workspaceId.uuidString, "name": "Recreated", "description": "",
                "projectType": "undefined", "revision": 1, "createdAt": "2026-09-07T00:00:00Z",
            ]
            let changes = try page(
                workspaceId: fixture.workspaceId,
                [fixture.change(.project, id: projectId, revision: 1, fields: fields)],
                cursor: "after"
            )
            let projects = try JSONSerialization.data(withJSONObject: ["items": [fields]])
            let snapshots = Mutex(0)
            let client = fixture.client { request in
                if request.url!.path.hasSuffix("capabilities") { return (
                    200,
                    [:],
                    Data("{\"sync\":{\"version\":5},\"meetingEvents\":{\"version\":1}}".utf8)
                ) }
                if request.url!.path.hasSuffix("projects") {
                    snapshots.withLock { $0 += 1 }
                    return (200, [:], projects)
                }
                #expect(request.url!.path.hasSuffix("changes"))
                return (200, [:], changes)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            try await SyncWorker(dbQueue: fixture.queue, apiClient: client).synchronizeForTransfer(
                workspaceId: fixture.workspaceId, connectionId: fixture.connectionId
            )
            #expect(snapshots.withLock { $0 } == 1)
            try await fixture.queue.read { db throws in
                #expect(try ProjectRecord.fetchOne(db, key: projectId)?.name == "Recreated")
                #expect(try String.fetchOne(db, sql: "SELECT syncPullCursor FROM workspaces") == "after")
            }
        }

        @Test
        func summaryDependencyFetchUsesMeetingMetadataWithoutAContentQuery() async throws {
            let fixture = try Fixture()
            let meetingId = UUID.v7()
            let timestamp = "2026-09-07T00:00:00Z"
            let changes = try page(workspaceId: fixture.workspaceId, [fixture.change(.summary, id: meetingId, revision: 1, fields: [
                "title": "Summary", "createdAt": timestamp, "contentOmitted": true, "contentPresent": true,
            ])], cursor: "after")
            let parent = try JSONSerialization.data(withJSONObject: [
                "meetingId": meetingId.uuidString.lowercased(), "workspaceId": fixture.workspaceId.uuidString.lowercased(),
                "name": "Parent", "description": "", "status": "READY", "createdAt": timestamp, "updatedAt": timestamp,
                "revision": 1, "summaryRevision": 1, "transcriptRevision": 0, "contentOmitted": true, "hasSummary": true,
            ])
            let client = fixture.client { request in
                if request.url!.path.hasSuffix("capabilities") { return (
                    200,
                    [:],
                    Data("{\"sync\":{\"version\":5},\"meetingEvents\":{\"version\":1}}".utf8)
                ) }
                if request.url!.path.hasSuffix("changes") { return (200, [:], changes) }
                #expect(request.url!
                    .path == "/api/v1/meetings/\(meetingId.uuidString.lowercased())")
                #expect(request.url!.query == nil)
                return (200, [:], parent)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            try await SyncWorker(dbQueue: fixture.queue, apiClient: client).synchronizeForTransfer(
                workspaceId: fixture.workspaceId, connectionId: fixture.connectionId
            )
            try await fixture.queue.read { db throws in
                #expect(try MeetingRecord.fetchOne(db, key: meetingId)?.name == "Parent")
                #expect(try Int.fetchOne(
                    db,
                    sql: "SELECT confirmedRevision FROM sync_entity_state WHERE entity = 'summary' AND entityId = ?",
                    arguments: [meetingId]
                ) == 1)
                #expect(try Bool.fetchOne(
                    db,
                    sql: "SELECT present FROM sync_content_state WHERE entity = 'summary' AND entityId = ?",
                    arguments: [meetingId]
                ) == true)
                #expect(try Bool.fetchOne(
                    db,
                    sql: "SELECT complete FROM sync_content_state WHERE entity = 'summary' AND entityId = ?",
                    arguments: [meetingId]
                ) == false)
            }
        }

        @Test
        func fileDependencyUsesMetadataWithoutCompletingTheBody() async throws {
            let fixture = try Fixture()
            let fileId = UUID.v7()
            let timestamp = "2026-09-07T00:00:00Z"
            let changes = try page(workspaceId: fixture.workspaceId, [fixture.change(.meetingAttachment, id: .v7(), revision: 1, fields: [
                "fileId": fileId.uuidString, "meetingId": fixture.meetingId.uuidString,
                "capturedAt": timestamp, "createdAt": timestamp,
            ])], cursor: "after")
            let parent = try JSONSerialization.data(withJSONObject: [
                "id": fileId.uuidString, "workspaceId": fixture.workspaceId.uuidString, "revision": 2,
                "uri": "/Volumes/test/app/file", "offset": 0, "size": 1, "contentType": "image/png",
                "checksum": fixture.checksum, "name": "Image", "createdAt": timestamp, "updatedAt": timestamp,
                "metadata": ["source": "screenshot", "ocrText": "OCR", "caption": "Caption"],
            ])
            let calls = Mutex(0)
            let client = fixture.client { request in
                if request.url!.path.hasSuffix("capabilities") { return (200, [:], Data(#"{"sync":{"version":5}}"#.utf8)) }
                if request.url!.path.hasSuffix("changes") { return (200, [:], changes) }
                calls.withLock { $0 += 1 }
                #expect(request.url!.path == "/api/v1/files/\(fileId.uuidString.lowercased())")
                #expect(request.url!.query == nil)
                return (200, [:], parent)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            try await SyncWorker(dbQueue: fixture.queue, apiClient: client).synchronizeForTransfer(
                workspaceId: fixture.workspaceId, connectionId: fixture.connectionId
            )
            try await fixture.queue.read { db throws in
                #expect(try TextContentStore.source(entity: .file, id: fileId, in: db)?.revision == 2)
                #expect(try TextContentAccess.cachedFileText(fileId: fileId, in: db) == nil)
                #expect(try Bool.fetchOne(
                    db,
                    sql: "SELECT complete FROM sync_content_state WHERE entity = 'file' AND entityId = ?",
                    arguments: [fileId]
                ) == false)
                #expect(try String.fetchOne(db, sql: "SELECT syncPullCursor FROM workspaces") == "after")
            }
            try await MeetingContentProvider(client: client).ensure(entity: .file, id: fileId, dbQueue: fixture.queue)
            #expect(calls.withLock { $0 } == 2)
            #expect(try await fixture.queue.read { try TextContentAccess.fileText(fileId: fileId, in: $0)?.ocrText } == "OCR")
        }

        @Test
        func pendingParentDeletionDoesNotResurrectThroughDependencyFetch() async throws {
            let fixture = try Fixture()
            try await fixture.queue.write { db in
                try SyncTransactionRecorder.record(
                    workspaceId: fixture.workspaceId,
                    operations: [.init(entity: .meeting, action: .delete, entityId: fixture.meetingId)],
                    in: db
                )
                try MeetingRecord.deleteOne(db, key: fixture.meetingId)
            }
            let summary = try fixture.change(
                .summary,
                id: fixture.meetingId,
                revision: 2,
                fields: ["contentOmitted": true, "contentPresent": true, "contentCount": 1]
            )
            let changes = try page(workspaceId: fixture.workspaceId, [summary, fixture.fileChange(revision: 2)], cursor: "after")
            let client = fixture.client { request in
                if request.url!.path.hasSuffix("capabilities") { return (
                    200,
                    [:],
                    Data("{\"sync\":{\"version\":5},\"meetingEvents\":{\"version\":1}}".utf8)
                ) }
                #expect(request.url!.path.hasSuffix("changes"))
                return (200, [:], changes)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            await #expect(throws: TextContentError.changed) {
                try await SyncWorker(dbQueue: fixture.queue, apiClient: client).synchronizeForTransfer(
                    workspaceId: fixture.workspaceId,
                    connectionId: fixture.connectionId
                )
            }
            try await fixture.queue.read { db throws in
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meetingId) == nil)
                #expect(try Int.fetchOne(db, sql: "SELECT confirmedRevision FROM sync_entity_state WHERE entity = 'file'") == 2)
                #expect(try String.fetchOne(db, sql: "SELECT syncPullCursor FROM workspaces") == "before")
            }
        }

        @Test
        func pendingMeetingEventProtectsItsMeetingWithoutBlockingImageAnalysis() async throws {
            let fixture = try Fixture()
            try await fixture.queue.write { db in
                try db.execute(sql: "UPDATE workspaces SET syncMeetingEventsVersion = 1")
                try MeetingEventRecorder.record(.tagAdded, meetingId: fixture.meetingId, relatedId: "42", in: db)
                #expect(try SyncTransactionQueue.hasPending(workspaceId: fixture.workspaceId, in: db))
            }
            let context = try await fixture.context()
            #expect(try await RemoteChangeApplier.applyIncremental(
                .init(sequence: 1, entity: .meeting, entityId: fixture.meetingId, action: "delete", revision: nil, record: nil),
                context: context, dbQueue: fixture.queue
            ) == .deferred)
            #expect(try await RemoteChangeApplier.applyIncremental(
                fixture.fileChange(revision: 2), context: context, dbQueue: fixture.queue
            ) == .applied)
        }

        @Test
        func aFailedPageLeavesTheGapForTheNextRead() async throws {
            let fixture = try Fixture()
            try await fixture.queueTranscript(recording: true)
            let transcript = try fixture.change(
                .transcript,
                id: fixture.meetingId,
                revision: 2,
                fields: ["contentOmitted": true, "contentPresent": true, "contentCount": 1]
            )
            let first = try page(workspaceId: fixture.workspaceId, [transcript], cursor: "middle", more: true)
            let second = try page(workspaceId: fixture.workspaceId, [fixture.fileChange(revision: 2)], cursor: "after")
            let fail = Mutex(true)
            let client = fixture.client { request in
                if request.url!.path.hasSuffix("capabilities") { return (
                    200,
                    [:],
                    Data("{\"sync\":{\"version\":5},\"meetingEvents\":{\"version\":1}}".utf8)
                ) }
                if request.url!.query!.contains("cursor=before") { return (200, [:], first) }
                return fail.withLock { $0 } ? (503, [:], Data()) : (200, [:], second)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            await #expect(throws: SyncHTTPError.self) {
                try await SyncWorker(dbQueue: fixture.queue, apiClient: client).synchronizeForTransfer(
                    workspaceId: fixture.workspaceId,
                    connectionId: fixture.connectionId
                )
            }
            #expect(try await fixture.queue.read { try String.fetchOne($0, sql: "SELECT syncPullCursor FROM workspaces") } == "before")
            fail.withLock { $0 = false }
            await #expect(throws: TextContentError.changed) {
                try await SyncWorker(dbQueue: fixture.queue, apiClient: client).synchronizeForTransfer(
                    workspaceId: fixture.workspaceId,
                    connectionId: fixture.connectionId
                )
            }
            #expect(try await fixture.queue
                .read { try Int.fetchOne($0, sql: "SELECT confirmedRevision FROM sync_entity_state WHERE entity = 'file'") } == 2)
            #expect(try await fixture.queue.read { try String.fetchOne($0, sql: "SELECT syncPullCursor FROM workspaces") } == "before")
        }

        private func wireChange(_ change: SyncChangePage.Change, workspaceId: UUID) throws -> [String: Any] {
            var row = try #require(JSONSerialization.jsonObject(with: SyncJSON.encoder.encode(change)) as? [String: Any])
            row["workspaceId"] = workspaceId.uuidString
            row["transactionId"] = "019f0d36-0520-7000-8000-000000000001"
            row["record"] = NSNull()
            if let payload = change.record {
                var record = try #require(JSONSerialization.jsonObject(with: SyncJSON.encoder.encode(payload)) as? [String: Any])
                record["workspaceId"] = workspaceId.uuidString
                record["revision"] = change.revision ?? 0
                switch change.entity {
                case .workspace:
                    record["workspaceId"] = change.entityId.uuidString
                    record["organizationId"] = change.entityId.uuidString
                    record["role"] = "admin"
                case .project: record["projectId"] = change.entityId.uuidString
                case .meeting: record["meetingId"] = change.entityId.uuidString
                case .summary, .transcript: record["meetingId"] = change.entityId.uuidString
                default: record["id"] = change.entityId.uuidString
                }
                if [.meeting, .project].contains(change.entity), record["description"] == nil { record["description"] = "" }
                if [.workspace, .meeting, .file].contains(change.entity), record["updatedAt"] == nil { record["updatedAt"] = record["createdAt"] }
                row["record"] = record
            }
            return row
        }

        private func page(workspaceId: UUID, _ changes: [SyncChangePage.Change], cursor: String, more: Bool = false) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "items": changes.map { try wireChange($0, workspaceId: workspaceId) },
                "cursor": cursor, "highWaterCursor": "after", "hasMore": more,
            ])
        }

        private actor Gate {
            private var started = false
            private var open = false
            private var startedWaiter: CheckedContinuation<Void, Never>?
            private var waiter: CheckedContinuation<Void, Never>?
            func wait() async {
                guard !open else { return }
                started = true
                startedWaiter?.resume()
                startedWaiter = nil
                await withCheckedContinuation { waiter = $0 }
            }

            func waitUntilStarted() async {
                if !started { await withCheckedContinuation { startedWaiter = $0 } }
            }

            func release() {
                open = true
                waiter?.resume()
                waiter = nil
            }
        }

        private struct Fixture: Sendable {
            let queue: DatabaseQueue
            let workspaceId = UUID.v7()
            let connectionId = UUID.v7()
            let meetingId = UUID.v7()
            let fileId = UUID.v7()
            let origin = "https://incremental-\(UUID().uuidString.lowercased()).invalid"
            let checksum = "SHA-256:" + String(repeating: "a", count: 64)

            init() throws {
                queue = try AppDatabaseManager(path: ":memory:").dbQueue
                try queue.write { db in
                    try DahliaAccountConnectionRecord(id: connectionId, origin: origin, clientID: "test", createdAt: .now).insert(db)
                    var workspace = WorkspaceRecord(id: workspaceId, path: nil, name: "Server", createdAt: .now, lastOpenedAt: .now)
                    workspace.accountConnectionId = connectionId
                    if workspace.syncRole == nil { workspace.syncRole = "admin" }
                    if workspace.organizationId == nil { workspace.organizationId = .v7() }
                    workspace.syncConfirmedConnectionId = connectionId
                    workspace.syncPullCursor = "before"
                    try workspace.insert(db)
                    try MeetingRecord(id: meetingId, workspaceId: workspaceId, projectId: nil, name: "Recording", createdAt: .now, updatedAt: .now)
                        .insert(db)
                    try FileRecord(
                        id: fileId,
                        workspaceId: workspaceId,
                        uri: "/Volumes/test/app/file",
                        size: 1,
                        contentType: "image/png",
                        checksum: checksum,
                        name: "Image",
                        metadata: .init(source: .screenshot),
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                    try FileTextBodyRecord(fileId: fileId, ocrText: "local OCR", caption: "local caption").insert(db)
                    try MeetingAttachmentRecord(id: fileId, meetingId: meetingId, fileId: fileId, capturedAt: .now, createdAt: .now).insert(db)
                    try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'file', ?, 1)", arguments: [workspaceId, fileId])
                    try TextContentStore.registerLocal(entity: .file, id: fileId, workspaceId: workspaceId, in: db)
                }
            }

            func client(_ handler: @escaping ImageURLProtocol.Handler) -> SyncAPIClient {
                ImageURLProtocol.register(origin: origin, handler: handler)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [ImageURLProtocol.self]
                return SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" })
            }

            func context() async throws -> RemoteChangePolicy.Context {
                try await queue.read { db in
                    try .init(
                        workspaceId: workspaceId,
                        connectionId: connectionId,
                        generation: #require(try Int64.fetchOne(db, sql: "SELECT syncMutationGeneration FROM workspaces"))
                    )
                }
            }

            func queueFile() async throws {
                _ = try await queue.write { db in
                    try SyncTransactionRecorder.record(
                        workspaceId: workspaceId,
                        operations: [.init(
                            entity: .file,
                            action: .upsert,
                            entityId: fileId,
                            payloadJSON: SyncJSON.encoder.encode(FileOperationPayload(
                                name: "Image",
                                checksum: checksum,
                                metadata: .init(source: .screenshot)
                            ))
                        )],
                        in: db
                    )
                }
            }

            func queueTranscript(recording: Bool) async throws {
                try await queue.write { db in
                    if recording {
                        try RecordingSessionRecord(
                            id: .v7(),
                            meetingId: meetingId,
                            startedAt: .now,
                            endedAt: nil,
                            duration: nil,
                            offsetSeconds: 0,
                            createdAt: .now,
                            updatedAt: .now
                        ).insert(db)
                    }
                    let segment = TranscriptContent(id: .v7(), meetingId: meetingId, startTime: .now, text: "local recording", isConfirmed: true)
                    try segment.insert(db)
                    try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'transcript', ?, 1)", arguments: [workspaceId, meetingId])
                    let patch = SyncOperationDraft(entity: .transcript, action: .patch, entityId: meetingId)
                    try SyncTransactionRecorder.record(
                        workspaceId: workspaceId,
                        operations: [patch],
                        transcriptSegments: [patch.id: [.init(segment)]],
                        in: db
                    )
                }
            }

            func change(_ entity: SyncEntity, id: UUID, revision: Int?, fields: [String: Any]) throws -> SyncChangePage.Change {
                try .init(
                    sequence: revision ?? 1,
                    entity: entity,
                    entityId: id,
                    action: "upsert",
                    revision: revision,
                    record: SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: JSONSerialization.data(withJSONObject: fields))
                )
            }

            func fileChange(revision: Int?, action: String = "upsert", checksum: String? = nil) throws -> SyncChangePage.Change {
                if action == "delete" { return .init(sequence: 2, entity: .file, entityId: fileId, action: action, revision: revision, record: nil) }
                return try change(.file, id: fileId, revision: revision, fields: [
                    "contentOmitted": true, "contentPresent": true, "contentCount": 2,
                    "uri": "/Volumes/test/app/file", "offset": 0, "size": 1, "contentType": "image/png", "checksum": checksum ?? self.checksum,
                    "name": "Image", "metadata": ["source": "screenshot"], "createdAt": "2026-09-07T00:00:00Z", "updatedAt": "2026-09-07T00:00:01Z",
                ])
            }
        }
    }
#endif
