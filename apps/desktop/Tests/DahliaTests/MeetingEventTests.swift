#if canImport(Testing)
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    @MainActor
    struct MeetingEventTests {
        @Test
        func migrationPreservesPendingTranscriptPayloadsAndIdentifiers() throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v46_textContent")
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://events.invalid", clientID: "test", createdAt: .now)
            let transactionId = UUID.v7()
            let operationId = UUID.v7()
            let vaultId = UUID.v7()
            try queue.write { db in
                try connection.insert(db)
                try db.execute(
                    sql: "INSERT INTO vaults(id, name, createdAt, lastOpenedAt) VALUES (?, 'Existing', ?, ?)",
                    arguments: [vaultId, Date.now, Date.now]
                )
                try db.execute(
                    sql: "INSERT INTO sync_transactions(id, vaultId, connectionId, createdAt, availableAt) VALUES (?, ?, ?, ?, ?)",
                    arguments: [transactionId, vaultId, connection.id, Date(), Date()]
                )
                try db.execute(
                    sql: "INSERT INTO sync_operations(transactionId, position, id, entity, action, entityId, payloadJSON) VALUES (?, 0, ?, 'transcript', 'patch', ?, ?)",
                    arguments: [transactionId, operationId, UUID.v7(), "immutable payload"]
                )
                try db.execute(sql: """
                INSERT INTO sync_transcript_patch_items(operationId, position, action, segmentId, startTime, text, isConfirmed)
                VALUES (?, 0, 'upsert', ?, ?, 'pending original transcript', 1)
                """, arguments: [operationId, UUID.v7(), Date()])
            }
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.write { db in
                #expect(try String
                    .fetchOne(db, sql: "SELECT text FROM sync_transcript_patch_items WHERE operationId = ?", arguments: [operationId]) ==
                    "pending original transcript")
                #expect(try String
                    .fetchOne(db, sql: "SELECT payloadJSON FROM sync_operations WHERE id = ?", arguments: [operationId]) == "immutable payload")
                #expect(try UUID.fetchOne(db, sql: "SELECT id FROM sync_transactions") == transactionId)
                #expect(try Int.fetchOne(db, sql: "SELECT syncMeetingEventsVersion FROM vaults WHERE id = ?", arguments: [vaultId]) == 0)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
                try MeetingEventMigration.migrate(in: db)
                try db.execute(
                    sql: "INSERT INTO sync_operations(transactionId, position, id, entity, action, entityId) VALUES (?, 1, ?, 'meeting_event', 'create', ?)",
                    arguments: [transactionId, UUID.v7(), UUID.v7()]
                )
            }
        }

        @Test
        func recordsOnlyActualTagChangesOnSupportedServerVaults() throws {
            let fixture = try BatchAudioTestFixture(name: "MeetingEventsTags")
            defer { fixture.removeFiles() }
            let repository = MeetingRepository(dbQueue: fixture.database.dbQueue)
            try repository.addTag(name: "Local tag", toMeetingId: fixture.meeting.id, colorHex: "#000000")
            #expect(try events(fixture).isEmpty)
            try enableEvents(fixture, version: 0)
            try repository.addTag(name: "Old server tag", toMeetingId: fixture.meeting.id, colorHex: "#000000")
            #expect(try events(fixture).isEmpty)
            try fixture.database.dbQueue.write { db in
                try db.execute(sql: "UPDATE vaults SET syncMeetingEventsVersion = 1 WHERE id = ?", arguments: [fixture.meeting.vaultId])
            }
            try repository.addTag(name: "Private tag name", toMeetingId: fixture.meeting.id, colorHex: "#000000")
            try repository.addTag(name: "Private tag name", toMeetingId: fixture.meeting.id, colorHex: "#000000")
            try repository.removeTag(name: "Private tag name", fromMeetingId: fixture.meeting.id)
            try repository.removeTag(name: "Private tag name", fromMeetingId: fixture.meeting.id)
            let payloads = try events(fixture)
            #expect(payloads.count == 2)
            #expect(payloads[0].contains("tag_added"))
            #expect(payloads[1].contains("tag_removed"))
            #expect(!payloads.joined().contains("Private tag name"))
        }

        @Test
        func completionQueuesSessionEndAndReceiptNeverCreatesRemoteRuntimeState() async throws {
            let fixture = try BatchAudioTestFixture(name: "MeetingEventsSession")
            defer { fixture.removeFiles() }
            try enableEvents(fixture)
            await MeetingEventRecorder.recordStarted(sessionId: fixture.session.id, dbQueue: fixture.database.dbQueue)
            let transaction = try #require(await SyncTransactionQueue.claim(dbQueue: fixture.database.dbQueue))
            let operation = try #require(transaction.operations.first)
            let response = SyncTransactionResponse(id: transaction.id, status: "committed", cursor: "1", records: [
                .init(entity: .meetingEvent, id: operation.entityId, revision: nil, record: nil),
            ])
            try await SyncTransactionQueue.complete(transaction, response: response, dbQueue: fixture.database.dbQueue)
            try await fixture.database.dbQueue.write { db in
                #expect(try RecordingSessionRecord.fetchCount(db) == 1)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_entity_state WHERE entity = 'meeting_event'") == 0)
                _ = try RecordingSessionCompletionWriter.finish(
                    .init(
                        recordingSessionId: fixture.session.id,
                        meetingId: fixture.meeting.id,
                        endedAt: fixture.now.addingTimeInterval(60),
                        duration: 60,
                        updatedAt: fixture.now.addingTimeInterval(60),
                        meetingStatus: nil
                    ),
                    in: db
                )
            }
            let payloads = try events(fixture)
            #expect(payloads.count == 1)
            #expect(payloads[0].contains("recording_ended"))
            #expect(payloads[0].contains(fixture.session.id.uuidString.lowercased()))
        }

        @Test(.timeLimit(.minutes(1)), arguments: [false, true])
        func unavailableEventsKeepContentMoving(meetingDeleted: Bool) async throws {
            let fixture = try BatchAudioTestFixture(name: "MeetingEventsDowngrade")
            defer { fixture.removeFiles() }
            try enableEvents(fixture)
            let origin = "https://events-\(fixture.meeting.id.uuidString.lowercased()).invalid"
            let queued = try await fixture.database.dbQueue.write { db -> (UUID, UUID, UUID) in
                try MeetingEventRecorder.record(.tagAdded, meetingId: fixture.meeting.id, relatedId: "1", in: db)
                let eventTransactionId = try #require(try UUID.fetchOne(
                    db,
                    sql: "SELECT transactionId FROM sync_operations WHERE entity = 'meeting_event'"
                ))
                let operation = try SyncInitialSnapshotBuilder.meetingOperation(fixture.meeting, action: .update)
                let transactionId = try #require(try SyncTransactionRecorder.record(
                    vaultId: fixture.meeting.vaultId,
                    operations: [operation],
                    in: db
                ))
                return (transactionId, operation.entityId, eventTransactionId)
            }
            let paths = Mutex([String]())
            ImageURLProtocol.register(origin: origin) { request in
                let path = request.url!.path
                paths.withLock { $0.append(path) }
                if path == "/api/v1/capabilities" {
                    return (
                        200,
                        [:],
                        Data((meetingDeleted ? "{\"sync\":{\"version\":4},\"meetingEvents\":{\"version\":1}}" : "{\"sync\":{\"version\":4}}").utf8)
                    )
                }
                if path == "/api/v1/transactions/resolve" {
                    let isFirstResolve = paths.withLock { $0.filter { $0 == path }.count } == 1
                    let id = meetingDeleted && isFirstResolve ? queued.2 : queued.0
                    return (200, [:], Data("{\"id\":\"\(id)\",\"status\":\"unknown\"}".utf8))
                }
                if path == "/api/v1/transactions" {
                    if meetingDeleted, paths.withLock({ $0.filter { $0 == path }.count }) == 1 {
                        return (410, [:], Data("{\"code\":\"meeting_event_parent_unavailable\",\"conflicts\":[]}".utf8))
                    }
                    return (
                        200,
                        [:],
                        Data(
                            "{\"id\":\"\(queued.0)\",\"status\":\"committed\",\"cursor\":\"1\",\"records\":[{\"entity\":\"meeting\",\"id\":\"\(queued.1)\",\"revision\":1,\"record\":null}]}"
                                .utf8
                        )
                    )
                }
                return (503, [:], Data())
            }
            defer { ImageURLProtocol.remove(origin: origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let worker = SyncWorker(
                dbQueue: fixture.database.dbQueue,
                session: session,
                apiClient: SyncAPIClient(session: session, tokenProvider: { _, _ in "test-token" })
            )
            let counts = ValueObservation.tracking { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions") ?? 0 }
                .values(in: fixture.database.dbQueue)
            await worker.drain()
            for try await count in counts where count == 0 {
                break
            }
            await worker.stop()
            #expect(paths.withLock { $0.filter { $0 == "/api/v1/transactions" }.count } == (meetingDeleted ? 2 : 1))
            #expect(try await fixture.database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT syncMeetingEventsVersion FROM vaults WHERE id = ?", arguments: [fixture.meeting.vaultId])
            } == (meetingDeleted ? 1 : 0))
        }

        @Test
        func rotationEnqueueDoesNotWaitForBusyDatabaseWriter() async throws {
            let fixture = try BatchAudioTestFixture(name: "MeetingEventsBusyWriter")
            defer { fixture.removeFiles() }
            try enableEvents(fixture)
            let store = try RecordingAudioStore(dbQueue: fixture.database.dbQueue, managedRootURL: fixture.managedRootURL)
            try await store.acquireSessionLease(meetingId: fixture.meeting.id, sessionId: fixture.session.id)
            let segment = try await store.createSegment(
                meetingId: fixture.meeting.id, sessionId: fixture.session.id, source: .microphone,
                segmentIndex: 1, sessionStartOffsetSeconds: 60, localeIdentifier: "en-US",
                sampleRate: 16000, channelCount: 1, isRequiredSource: true
            )
            let writerEntered = Mutex(false)
            let enqueueReturned = Mutex(false)
            let releaseWriter = DispatchSemaphore(value: 0)
            let blocker = Task.detached {
                try fixture.database.dbQueue.write { _ in
                    writerEntered.withLock { $0 = true }
                    releaseWriter.wait()
                }
            }
            #expect(await pollUntil { writerEntered.withLock { $0 } })
            let enqueue = Task.detached {
                store.recordRotation(segmentId: segment.record.id)
                enqueueReturned.withLock { $0 = true }
            }
            let returnedWhileBlocked = await pollUntil(timeout: .seconds(1)) { enqueueReturned.withLock { $0 } }
            releaseWriter.signal()
            try await blocker.value
            await enqueue.value
            #expect(returnedWhileBlocked)
            #expect(try events(fixture).count == 1)
            await store.releaseSessionLease(sessionId: fixture.session.id)
        }

        @Test
        func resumingAudioSourceRecordsPhysicalSegmentSwitch() async throws {
            let fixture = try BatchAudioTestFixture(name: "MeetingEventsResume")
            defer { fixture.removeFiles() }
            try enableEvents(fixture)
            let recording = try BatchAudioRecordingSession(
                dbQueue: fixture.database.dbQueue, managedRootURL: fixture.managedRootURL,
                meetingId: fixture.meeting.id, recordingSessionId: fixture.session.id,
                recordingStartTime: fixture.now, sampleRate: 16000
            )
            _ = try await recording.beginRange(source: .microphone, locale: Locale(identifier: "en-US"), at: fixture.now)
            #expect(try events(fixture).isEmpty)
            try await recording.endRangeForReconfiguration(source: .microphone)
            _ = try await recording.beginRange(source: .microphone, locale: Locale(identifier: "en-US"), at: fixture.now.addingTimeInterval(10))
            let payloads = try events(fixture)
            #expect(payloads.count == 1)
            #expect(payloads.first?.contains("\"segmentIndex\":1") == true)
            try await recording.finish()
        }

        @Test
        func rotationRecordsEachSourceAndExcludesInitialCreation() async throws {
            let fixture = try BatchAudioTestFixture(name: "MeetingEventsRotation")
            defer { fixture.removeFiles() }
            try enableEvents(fixture)
            let store = try RecordingAudioStore(dbQueue: fixture.database.dbQueue, managedRootURL: fixture.managedRootURL)
            try await store.acquireSessionLease(meetingId: fixture.meeting.id, sessionId: fixture.session.id)
            for source in [RecordingAudioSource.microphone, .system] {
                for index in 0 ... 1 {
                    let segment = try await store.createSegment(
                        meetingId: fixture.meeting.id,
                        sessionId: fixture.session.id,
                        source: source,
                        segmentIndex: index,
                        sessionStartOffsetSeconds: Double(index * 60),
                        localeIdentifier: "en-US",
                        sampleRate: 16000,
                        channelCount: 1,
                        isRequiredSource: true,
                        at: fixture.now
                    )
                    store.recordRotation(segmentId: segment.record.id, at: fixture.now)
                }
            }
            let payloads = try events(fixture)
            #expect(payloads.count == 2)
            #expect(payloads.allSatisfy { $0.contains("segment_rotated") && $0.contains("\"segmentIndex\":1") })
            #expect(payloads[0].contains("\"audioSource\":\"mic\""))
            #expect(payloads[1].contains("\"audioSource\":\"system\""))
            #expect(!payloads.joined().contains(".caf"))
            await store.releaseSessionLease(sessionId: fixture.session.id)
        }

        private func enableEvents(_ fixture: BatchAudioTestFixture, version: Int = 1) throws {
            try fixture.database.dbQueue.write { db in
                let connection = DahliaAccountConnectionRecord(
                    id: .v7(),
                    origin: "https://events-\(fixture.meeting.id.uuidString.lowercased()).invalid",
                    clientID: "test",
                    createdAt: .now
                )
                try connection.insert(db)
                try db.execute(
                    sql: "UPDATE vaults SET accountConnectionId = ?, syncConfirmedConnectionId = ? WHERE id = ?",
                    arguments: [connection.id, connection.id, fixture.meeting.vaultId]
                )
                try db.execute(sql: "UPDATE vaults SET syncMeetingEventsVersion = ? WHERE id = ?", arguments: [version, fixture.meeting.vaultId])
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision) VALUES (?, 'vault', ?, 1), (?, 'meeting', ?, 1)",
                    arguments: [fixture.meeting.vaultId, fixture.meeting.vaultId, fixture.meeting.vaultId, fixture.meeting.id]
                )
            }
        }

        private func events(_ fixture: BatchAudioTestFixture) throws -> [String] {
            try fixture.database.dbQueue.read { db in
                try String.fetchAll(db, sql: """
                SELECT o.payloadJSON FROM sync_operations o JOIN sync_transactions t ON t.id = o.transactionId
                WHERE o.entity = 'meeting_event' ORDER BY t.sequence, o.position
                """)
            }
        }
    }
#endif
