#if canImport(Testing)
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
        func protectedTranscriptDoesNotBlockLaterPagesAndRestartReplaysTheGap() async throws {
            let fixture = try Fixture()
            try await fixture.queueTranscript(recording: true)
            let transcript = try fixture.change(.transcript, id: fixture.meetingId, revision: 2, fields: [
                "contentOmitted": true, "contentPresent": true, "contentCount": 1,
            ])
            let first = try page([transcript], cursor: "middle", more: true)
            let second = try page([fixture.fileChange(revision: 2)], cursor: "after")
            let cursors = Mutex<[String]>([])
            let client = fixture.client { request in
                if request.url!.path.hasSuffix("capabilities") { return (200, [:], Data("{\"syncVersion\":1,\"meetingEventsVersion\":1}".utf8)) }
                let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "cursor" }!.value!
                cursors.withLock { $0.append(cursor) }
                return (200, [:], cursor == "before" ? first : second)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            for _ in 0 ..< 2 {
                // A fresh worker models restart: only the durable cursor and entity state survive.
                let worker = SyncWorker(dbQueue: fixture.queue, apiClient: client)
                await #expect(throws: TextContentError.changed) {
                    try await worker.synchronizeForTransfer(vaultId: fixture.vaultId, connectionId: fixture.connectionId)
                }
                try await fixture.queue.read { db throws in
                    #expect(try String.fetchOne(db, sql: "SELECT syncPullCursor FROM vaults") == "before")
                    #expect(try Int.fetchOne(db, sql: "SELECT confirmedRevision FROM sync_entity_state WHERE entity = 'file'") == 2)
                    #expect(try Int.fetchOne(db, sql: "SELECT confirmedRevision FROM sync_entity_state WHERE entity = 'transcript'") == 1)
                    #expect(try String.fetchOne(db, sql: "SELECT text FROM transcript_segment_bodies") == "local recording")
                    #expect(try SyncTransactionQueue.hasPending(vaultId: fixture.vaultId, in: db))
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
                vaultId: fixture.vaultId,
                connectionId: fixture.connectionId
            )
            #expect(try await fixture.queue.read { try String.fetchOne($0, sql: "SELECT syncPullCursor FROM vaults") } == "after")
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
            let changes = try page([
                fixture.fileChange(revision: 2),
                fixture.change(.meeting, id: other, revision: 1, fields: [
                    "name": "Other meeting", "status": "READY", "createdAt": "2026-09-07T00:00:00Z", "updatedAt": "2026-09-07T00:00:00Z",
                ]),
            ], cursor: "after")
            let client = fixture.client { request in
                (200, [:], request.url!.path.hasSuffix("capabilities") ? Data("{\"syncVersion\":1,\"meetingEventsVersion\":1}".utf8) : changes)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            await #expect(throws: TextContentError.changed) {
                try await SyncWorker(dbQueue: fixture.queue, apiClient: client).synchronizeForTransfer(
                    vaultId: fixture.vaultId,
                    connectionId: fixture.connectionId
                )
            }
            try await fixture.queue.read { db throws in
                #expect(try String.fetchOne(db, sql: "SELECT syncPullCursor FROM vaults") == "before")
                #expect(try Int.fetchOne(db, sql: "SELECT confirmedRevision FROM sync_entity_state WHERE entity = 'file'") == 1)
                #expect(try MeetingRecord.fetchOne(db, key: other)?.name == "Other meeting")
            }
        }

        @Test(arguments: ["ack", "reconnect", "recovery", "cancel"])
        func inFlightReadsCannotOutliveTheirProtectionOrOverlapAnotherWorker(boundary: String) async throws {
            let fixture = try Fixture()
            if boundary == "ack" { try await fixture.queueFile() }
            let gate = Gate()
            let changes = try page([fixture.fileChange(revision: 2, action: "delete")], cursor: "after")
            var client = fixture.client { request in
                (200, [:], request.url!.path.hasSuffix("capabilities") ? Data("{\"syncVersion\":1,\"meetingEventsVersion\":1}".utf8) : changes)
            }
            client.tokenProvider = { _, _ in await gate.wait()
                return "test"
            }
            let worker = SyncWorker(dbQueue: fixture.queue, apiClient: client)
            let task = Task { try await worker.synchronizeForTransfer(vaultId: fixture.vaultId, connectionId: fixture.connectionId) }
            await gate.waitUntilStarted()
            await #expect(throws: TextContentError.changed) {
                try await SyncWorker(dbQueue: fixture.queue, apiClient: client).synchronizeForTransfer(
                    vaultId: fixture.vaultId,
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
                    try db.execute(sql: "UPDATE vaults SET syncConfirmedConnectionId = NULL")
                    try db.execute(sql: "UPDATE vaults SET syncConfirmedConnectionId = ?", arguments: [fixture.connectionId])
                }
            } else if boundary == "recovery" {
                try await fixture.queue.write { db in try db.execute(sql: "UPDATE vaults SET syncRecoveryState = 'pending'") }
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
                #expect(try String.fetchOne(db, sql: "SELECT syncPullCursor FROM vaults") == "before")
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
                try MeetingRecord(id: other, vaultId: fixture.vaultId, projectId: nil, name: "Other", createdAt: .now, updatedAt: .now).insert(db)
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
                try SyncTransactionQueue.discard(vaultId: fixture.vaultId, in: db)
                try db.execute(sql: "DELETE FROM meeting_files WHERE fileId = ?", arguments: [fixture.fileId])
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
            let lower = try page([file], cursor: "after")
            let empty = try page([], cursor: "after")
            let meeting = try fixture.change(.meeting, id: fixture.meetingId, revision: 1, fields: [
                "name": "Restored", "status": "READY", "createdAt": "2026-09-07T00:00:00Z", "updatedAt": "2026-09-07T00:00:00Z",
                "contentOmitted": true, "hasSummary": false, "contentCount": 0,
            ])
            let link = try fixture.change(.meetingFile, id: fixture.fileId, revision: 1, fields: [
                "meetingId": fixture.meetingId.uuidString, "fileId": fixture.fileId.uuidString, "createdAt": "2026-09-07T00:00:00Z",
            ])
            let records = try #require(JSONSerialization.jsonObject(with: SyncJSON.encoder.encode([meeting, file, link])) as? [[String: Any]])
            let snapshot = try JSONSerialization.data(withJSONObject: [
                "items": records.map { row in var value = row
                    value["id"] = value.removeValue(forKey: "entityId")
                    return value
                },
                "startCursor": "after", "nextCursor": NSNull(), "contentMode": "metadata-v1",
            ])
            let snapshots = Mutex(0)
            let client = fixture.client { request in
                if request.url!.path.hasSuffix("capabilities") { return (200, [:], Data("{\"syncVersion\":1,\"meetingEventsVersion\":1}".utf8)) }
                if request.url!.path.hasSuffix("snapshot") {
                    snapshots.withLock { $0 += 1 }
                    return (200, [:], snapshot)
                }
                return (200, [:], request.url!.query!.contains("cursor=before") ? lower : empty)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            await #expect(throws: TextContentError.changed) {
                try await SyncWorker(dbQueue: fixture.queue, apiClient: client).synchronizeForTransfer(
                    vaultId: fixture.vaultId,
                    connectionId: fixture.connectionId
                )
            }
            #expect(snapshots.withLock { $0 } == (recording ? 0 : 1))
            try await fixture.queue.read { db throws in
                #expect(try Int.fetchOne(db, sql: "SELECT confirmedRevision FROM sync_entity_state WHERE entity = 'file'") == (recording ? 3 : 1))
                #expect(try String.fetchOne(db, sql: "SELECT syncRecoveryState FROM vaults") == (recording ? "pending" : nil))
                if recording { #expect(try String.fetchOne(db, sql: "SELECT text FROM transcript_segment_bodies") == "local recording") }
            }
        }

        @Test
        func equalProjectRevisionStillReconcilesRecreatedProject() async throws {
            let fixture = try Fixture()
            let projectId = UUID.v7()
            try await fixture.queue.write { db in
                try ProjectRecord(
                    id: projectId, vaultId: fixture.vaultId, parentProjectId: nil,
                    name: "Old", createdAt: .now, projectType: .undefined
                ).insert(db)
                try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'project', ?, 1)", arguments: [fixture.vaultId, projectId])
            }
            let fields: [String: Any] = [
                "projectId": projectId.uuidString, "name": "Recreated", "description": "",
                "projectType": "undefined", "revision": 1, "createdAt": "2026-09-07T00:00:00Z",
            ]
            let changes = try page([fixture.change(.project, id: projectId, revision: 1, fields: fields)], cursor: "after")
            let projects = try JSONSerialization.data(withJSONObject: ["items": [fields]])
            let snapshots = Mutex(0)
            let client = fixture.client { request in
                if request.url!.path.hasSuffix("capabilities") { return (200, [:], Data("{\"syncVersion\":1,\"meetingEventsVersion\":1}".utf8)) }
                if request.url!.path.hasSuffix("projects") {
                    snapshots.withLock { $0 += 1 }
                    return (200, [:], projects)
                }
                #expect(request.url!.path.hasSuffix("changes"))
                return (200, [:], changes)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            try await SyncWorker(dbQueue: fixture.queue, apiClient: client).synchronizeForTransfer(
                vaultId: fixture.vaultId, connectionId: fixture.connectionId
            )
            #expect(snapshots.withLock { $0 } == 1)
            try await fixture.queue.read { db throws in
                #expect(try ProjectRecord.fetchOne(db, key: projectId)?.name == "Recreated")
                #expect(try String.fetchOne(db, sql: "SELECT syncPullCursor FROM vaults") == "after")
            }
        }

        @Test
        func summaryDependencyFetchUsesMeetingMetadataWithoutAContentQuery() async throws {
            let fixture = try Fixture()
            let meetingId = UUID.v7()
            let timestamp = "2026-09-07T00:00:00Z"
            let changes = try page([fixture.change(.summary, id: meetingId, revision: 1, fields: [
                "title": "Summary", "createdAt": timestamp, "contentOmitted": true, "contentPresent": true,
            ])], cursor: "after")
            let parent = try JSONSerialization.data(withJSONObject: [
                "meetingId": meetingId.uuidString.lowercased(), "vaultId": fixture.vaultId.uuidString.lowercased(),
                "name": "Parent", "status": "READY", "createdAt": timestamp, "updatedAt": timestamp,
                "revision": 1, "summaryRevision": 1, "transcriptRevision": 0, "contentOmitted": true, "hasSummary": true,
            ])
            let client = fixture.client { request in
                if request.url!.path.hasSuffix("capabilities") { return (200, [:], Data("{\"syncVersion\":1,\"meetingEventsVersion\":1}".utf8)) }
                if request.url!.path.hasSuffix("changes") { return (200, [:], changes) }
                #expect(request.url!.path == "/api/v1/vaults/\(fixture.vaultId.uuidString.lowercased())/meetings/\(meetingId.uuidString.lowercased())")
                #expect(request.url!.query == nil)
                return (200, [:], parent)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            try await SyncWorker(dbQueue: fixture.queue, apiClient: client).synchronizeForTransfer(
                vaultId: fixture.vaultId, connectionId: fixture.connectionId
            )
            try await fixture.queue.read { db throws in
                #expect(try MeetingRecord.fetchOne(db, key: meetingId)?.name == "Parent")
                #expect(try Int.fetchOne(db, sql: "SELECT confirmedRevision FROM sync_entity_state WHERE entity = 'summary' AND entityId = ?", arguments: [meetingId]) == 1)
                #expect(try Bool.fetchOne(db, sql: "SELECT present FROM sync_content_state WHERE entity = 'summary' AND entityId = ?", arguments: [meetingId]) == true)
                #expect(try Bool.fetchOne(db, sql: "SELECT complete FROM sync_content_state WHERE entity = 'summary' AND entityId = ?", arguments: [meetingId]) == false)
            }
        }

        @Test
        func pendingParentDeletionDoesNotResurrectThroughDependencyFetch() async throws {
            let fixture = try Fixture()
            try await fixture.queue.write { db in
                try SyncTransactionRecorder.record(
                    vaultId: fixture.vaultId,
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
            let changes = try page([summary, fixture.fileChange(revision: 2)], cursor: "after")
            let client = fixture.client { request in
                if request.url!.path.hasSuffix("capabilities") { return (200, [:], Data("{\"syncVersion\":1,\"meetingEventsVersion\":1}".utf8)) }
                #expect(request.url!.path.hasSuffix("changes"))
                return (200, [:], changes)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            await #expect(throws: TextContentError.changed) {
                try await SyncWorker(dbQueue: fixture.queue, apiClient: client).synchronizeForTransfer(
                    vaultId: fixture.vaultId,
                    connectionId: fixture.connectionId
                )
            }
            try await fixture.queue.read { db throws in
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meetingId) == nil)
                #expect(try Int.fetchOne(db, sql: "SELECT confirmedRevision FROM sync_entity_state WHERE entity = 'file'") == 2)
                #expect(try String.fetchOne(db, sql: "SELECT syncPullCursor FROM vaults") == "before")
            }
        }

        @Test
        func pendingMeetingEventProtectsItsMeetingWithoutBlockingImageAnalysis() async throws {
            let fixture = try Fixture()
            try await fixture.queue.write { db in
                try db.execute(sql: "UPDATE vaults SET syncMeetingEventsVersion = 1")
                try MeetingEventRecorder.record(.tagAdded, meetingId: fixture.meetingId, relatedId: "42", in: db)
                #expect(try SyncTransactionQueue.hasPending(vaultId: fixture.vaultId, in: db))
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
            let first = try page([transcript], cursor: "middle", more: true)
            let second = try page([fixture.fileChange(revision: 2)], cursor: "after")
            let fail = Mutex(true)
            let client = fixture.client { request in
                if request.url!.path.hasSuffix("capabilities") { return (200, [:], Data("{\"syncVersion\":1,\"meetingEventsVersion\":1}".utf8)) }
                if request.url!.query!.contains("cursor=before") { return (200, [:], first) }
                return fail.withLock { $0 } ? (503, [:], Data()) : (200, [:], second)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            await #expect(throws: SyncHTTPError.self) {
                try await SyncWorker(dbQueue: fixture.queue, apiClient: client).synchronizeForTransfer(
                    vaultId: fixture.vaultId,
                    connectionId: fixture.connectionId
                )
            }
            #expect(try await fixture.queue.read { try String.fetchOne($0, sql: "SELECT syncPullCursor FROM vaults") } == "before")
            fail.withLock { $0 = false }
            await #expect(throws: TextContentError.changed) {
                try await SyncWorker(dbQueue: fixture.queue, apiClient: client).synchronizeForTransfer(
                    vaultId: fixture.vaultId,
                    connectionId: fixture.connectionId
                )
            }
            #expect(try await fixture.queue
                .read { try Int.fetchOne($0, sql: "SELECT confirmedRevision FROM sync_entity_state WHERE entity = 'file'") } == 2)
            #expect(try await fixture.queue.read { try String.fetchOne($0, sql: "SELECT syncPullCursor FROM vaults") } == "before")
        }

        private func page(_ changes: [SyncChangePage.Change], cursor: String, more: Bool = false) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "items": JSONSerialization.jsonObject(with: SyncJSON.encoder.encode(changes)),
                "cursor": cursor, "highWaterCursor": "after", "hasMore": more, "contentMode": "metadata-v1",
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
            let vaultId = UUID.v7()
            let connectionId = UUID.v7()
            let meetingId = UUID.v7()
            let fileId = UUID.v7()
            let origin = "https://incremental-\(UUID().uuidString.lowercased()).invalid"
            let checksum = "SHA-256:" + String(repeating: "a", count: 64)

            init() throws {
                queue = try AppDatabaseManager(path: ":memory:").dbQueue
                try queue.write { db in
                    try DahliaAccountConnectionRecord(id: connectionId, origin: origin, clientID: "test", createdAt: .now).insert(db)
                    var vault = VaultRecord(id: vaultId, path: nil, name: "Server", createdAt: .now, lastOpenedAt: .now)
                    vault.accountConnectionId = connectionId
                    vault.syncConfirmedConnectionId = connectionId
                    vault.syncPullCursor = "before"
                    try vault.insert(db)
                    try MeetingRecord(id: meetingId, vaultId: vaultId, projectId: nil, name: "Recording", createdAt: .now, updatedAt: .now).insert(db)
                    try FileRecord(
                        id: fileId,
                        vaultId: vaultId,
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
                    try MeetingFileRecord(id: fileId, meetingId: meetingId, fileId: fileId, capturedAt: .now, createdAt: .now).insert(db)
                    try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'file', ?, 1)", arguments: [vaultId, fileId])
                    try TextContentStore.registerLocal(entity: .file, id: fileId, vaultId: vaultId, in: db)
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
                        vaultId: vaultId,
                        connectionId: connectionId,
                        generation: #require(try Int64.fetchOne(db, sql: "SELECT syncMutationGeneration FROM vaults"))
                    )
                }
            }

            func queueFile() async throws {
                _ = try await queue.write { db in
                    try SyncTransactionRecorder.record(
                        vaultId: vaultId,
                        operations: [.init(entity: .file, action: .upsert, entityId: fileId)],
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
                    try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'transcript', ?, 1)", arguments: [vaultId, meetingId])
                    let patch = SyncOperationDraft(entity: .transcript, action: .patch, entityId: meetingId)
                    try SyncTransactionRecorder.record(
                        vaultId: vaultId,
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
                    "uri": "/Volumes/test/app/file", "offset": 0, "size": 1, "content_type": "image/png", "checksum": checksum ?? self.checksum,
                    "name": "Image", "metadata": ["source": "screenshot"], "createdAt": "2026-09-07T00:00:00Z", "updatedAt": "2026-09-07T00:00:01Z",
                ])
            }
        }
    }
#endif
