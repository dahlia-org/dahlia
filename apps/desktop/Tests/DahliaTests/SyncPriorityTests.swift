#if canImport(Testing)
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    struct SyncPriorityTests {
        private func seed(path: String = ":memory:") throws -> (DatabaseQueue, UUID) {
            let queue = try AppDatabaseManager(path: path).dbQueue
            let workspace = UUID.v7()
            try queue.write { db in
                let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://example.invalid", clientID: "test", createdAt: .now)
                try connection.insert(db)
                var row = WorkspaceRecord(id: workspace, name: "Priority", createdAt: .now, lastOpenedAt: .now)
                row.accountConnectionId = connection.id
                row.syncConfirmedConnectionId = connection.id
                row.syncRole = "admin"
                row.organizationId = .v7()
                try row.insert(db)
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(workspace_id, entity, entityId, confirmedRevision) VALUES (?, 'workspace', ?, 1)",
                    arguments: [workspace, workspace]
                )
            }
            return (queue, workspace)
        }

        @Test func summaryPreparationIgnoresIndependentBacklogAndConcurrentAcknowledgements() async throws {
            let (queue, workspace) = try seed()
            let meeting = UUID.v7()
            let connection = try await queue.write { db -> UUID in
                try db.execute(sql: "UPDATE workspaces SET syncPullCursor = 'before' WHERE id = ?", arguments: [workspace])
                try MeetingRecord(id: meeting, workspaceId: workspace, projectId: nil, name: "Meeting", createdAt: .now, updatedAt: .now).insert(db)
                try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'meeting', ?, 1)", arguments: [workspace, meeting])
                try SyncTransactionRecorder.record(
                    workspaceId: workspace,
                    background: true,
                    operations: [.init(entity: .project, action: .create, entityId: .v7())],
                    in: db
                )
                let connection = try #require(try WorkspaceRecord.fetchOne(db, key: workspace)?.accountConnectionId)
                try db.execute(
                    sql: "UPDATE dahlia_account_connections SET origin = ? WHERE id = ?",
                    arguments: ["https://summary-priority-\(workspace.uuidString).invalid", connection]
                )
                return connection
            }
            let origin = "https://summary-priority-\(workspace.uuidString).invalid"
            ImageURLProtocol.register(origin: origin) { request in
                if request.url!.path.hasSuffix("capabilities") {
                    return (200, [:], Data(#"{"sync":{"version":7}}"#.utf8))
                }
                #expect(request.url!.path.hasSuffix("changes"))
                // The same counter changes on ACK. The lifecycle epoch must remain valid.
                do {
                    try queue.write { db in
                        try db.execute(
                            sql: "UPDATE workspaces SET syncMutationGeneration = syncMutationGeneration + 1 WHERE id = ?",
                            arguments: [workspace]
                        )
                    }
                } catch { Issue.record(error) }
                return (200, [:], Data(#"{"items":[],"cursor":"after","highWaterCursor":"after","hasMore":false}"#.utf8))
            }
            defer { ImageURLProtocol.remove(origin: origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let api = SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" })
            let worker = SyncWorker(dbQueue: queue, apiClient: api)
            try await worker.synchronizeForMeeting(meetingId: meeting, workspaceId: workspace, connectionId: connection)
            try await queue.read { db throws in
                #expect(try SyncTransactionQueue.hasPending(workspaceId: workspace, in: db))
                #expect(try String.fetchOne(db, sql: "SELECT syncPullCursor FROM workspaces WHERE id = ?", arguments: [workspace]) == "after")
            }
        }

        @Test func foregroundBypassesEightThousandIndependentImportsWithoutStarvingThem() async throws {
            let (queue, workspace) = try seed()
            let normal = (0 ..< 5).map { _ in UUID.v7() }
            let oldest = try await queue.write { db in
                var first: UUID?
                for _ in 0 ..< 8000 {
                    let id = try SyncTransactionRecorder.record(workspaceId: workspace, background: true, operations: [
                        .init(entity: .project, action: .create, entityId: .v7()),
                    ], in: db)
                    if first == nil { first = id }
                }
                for id in normal {
                    try SyncTransactionRecorder.record(
                        workspaceId: workspace,
                        operations: [.init(entity: .project, action: .create, entityId: id)],
                        in: db
                    )
                }
                return try #require(first)
            }
            // Same fixture, former FIFO query: every current edit sits behind all 8,000 imports.
            let baseline = try await queue.read { try UUID.fetchOne($0, sql: "SELECT id FROM sync_transactions ORDER BY sequence LIMIT 1") }
            #expect(baseline == oldest)
            let clock = ContinuousClock()
            var waits: [Double] = []
            for index in 0 ..< 6 {
                let started = clock.now
                let claim = try #require(try await SyncTransactionQueue.claim(dbQueue: queue))
                let duration = started.duration(to: clock.now).components
                waits.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
                if index == 4 {
                    #expect(claim.id == oldest)
                } else { #expect(claim.operations.first?.entityId == normal[index < 4 ? index : 4]) }
                try await queue.write { try $0.execute(sql: "DELETE FROM sync_transactions WHERE id = ?", arguments: [claim.id]) }
            }
            print("priority_fixture backlog=8000 fifo_foreground_position=8001 priority_foreground_position=1 claim_ms=\(waits.sorted())")
        }

        @Test func foregroundPromotesParentAndBlockedResolutionLeavesIndependentLease() async throws {
            let (queue, workspace) = try seed()
            let parent = UUID.v7(), meeting = UUID.v7(), independent = UUID.v7()
            let ids = try await queue.write { db -> [UUID] in
                try ProjectRecord(id: parent, workspaceId: workspace, parentProjectId: nil, name: "Parent", createdAt: .now, projectType: .undefined)
                    .insert(db)
                try MeetingRecord(id: meeting, workspaceId: workspace, projectId: parent, name: "Meeting", createdAt: .now, updatedAt: .now)
                    .insert(db)
                let parentId = try #require(try SyncTransactionRecorder.record(
                    workspaceId: workspace,
                    background: true,
                    operations: [SyncInitialSnapshotBuilder.projectOperation(
                        ProjectRecord.fetchOne(db, key: parent)!,
                        action: .create
                    )],
                    in: db
                ))
                let childId = try #require(try SyncTransactionRecorder.record(
                    workspaceId: workspace,
                    operations: [SyncInitialSnapshotBuilder.meetingOperation(
                        MeetingRecord.fetchOne(db, key: meeting)!,
                        action: .create,
                        in: db
                    )],
                    in: db
                ))
                let other = try #require(try SyncTransactionRecorder.record(
                    workspaceId: workspace,
                    operations: [.init(
                        entity: .project,
                        action: .create,
                        entityId: independent
                    )],
                    in: db
                ))
                return [parentId, childId, other]
            }
            let claimed = try #require(try await SyncTransactionQueue.claim(dbQueue: queue))
            #expect(claimed.id == ids[0])
            try await SyncTransactionQueue.block(claimed, reason: .validation, response: Data("{}".utf8), dbQueue: queue)
            let other = try #require(try await SyncTransactionQueue.claim(dbQueue: queue))
            #expect(other.id == ids[2])
            try await SyncTransactionQueue.discardInvalidTransaction(workspaceId: workspace, dbQueue: queue)
            try await queue.read { db in
                let remaining = try UUID.fetchAll(db, sql: "SELECT id FROM sync_transactions")
                #expect(remaining == [other.id])
                #expect(try Date.fetchOne(db, sql: "SELECT leaseExpiresAt FROM sync_transactions WHERE id = ?", arguments: [other.id]) != nil)
            }
        }

        @Test(arguments: [false, true], [false, true])
        func acceptingOneConflictKeepsIndependentReception(deleted: Bool, invalidated: Bool) async throws {
            let (queue, workspace) = try seed()
            let accepted = UUID.v7(), other = UUID.v7()
            let connection = try await queue.write { db -> UUID in
                try db.execute(sql: "UPDATE workspaces SET syncPullCursor = 'before' WHERE id = ?", arguments: [workspace])
                for id in [accepted, other] {
                    let meeting = MeetingRecord(id: id, workspaceId: workspace, name: "Local", createdAt: .now, updatedAt: .now)
                    try meeting.insert(db)
                    try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'meeting', ?, 1)", arguments: [workspace, id])
                    try db.execute(
                        sql: "INSERT INTO sync_confirmed_relations(workspaceId, entity, entityId) VALUES (?, 'meeting', ?)",
                        arguments: [workspace, id]
                    )
                    try SyncTransactionRecorder.record(
                        workspaceId: workspace,
                        operations: [SyncInitialSnapshotBuilder.meetingOperation(meeting, action: .update, in: db)],
                        in: db
                    )
                }
                try db.execute(sql: "UPDATE sync_transactions SET blockedReason = 'conflict'")
                return try #require(try WorkspaceRecord.fetchOne(db, key: workspace)?.accountConnectionId)
            }
            try await SyncTransactionQueue.acceptServerVersion(workspaceId: workspace, dbQueue: queue)
            #expect(try await queue
                .read { try String.fetchOne($0, sql: "SELECT syncPullCursor FROM workspaces WHERE id = ?", arguments: [workspace]) } == "before")
            let origin = "https://scoped-resolution-\(workspace.uuidString).invalid"
            try await queue.write { try $0.execute(sql: "UPDATE dahlia_account_connections SET origin = ?", arguments: [origin]) }
            let items: [[String: Any]] = deleted ? [] : [[
                "entity": "meeting",
                "id": accepted.uuidString,
                "revision": 1,
                "record": [
                    "meetingId": accepted.uuidString,
                    "workspaceId": workspace.uuidString,
                    "name": "Server",
                    "projectId": NSNull(),
                    "status": "READY",
                    "description": "",
                    "duration": NSNull(),
                    "recordingStartedAt": NSNull(),
                    "icalUid": NSNull(),
                    "recurrenceId": NSNull(),
                    "calendarEvent": NSNull(),
                    "revision": 1,
                    "createdAt": "2026-01-01T00:00:00.000Z",
                    "updatedAt": "2026-01-01T00:00:00.000Z",
                ],
            ]]
            let snapshot = try JSONSerialization.data(withJSONObject: ["items": items, "startCursor": "snapshot", "nextCursor": NSNull()])
            let invalidateOnce = Mutex(invalidated)
            ImageURLProtocol.register(origin: origin) { request in
                if request.url!.path.hasSuffix("capabilities") { return (200, [:], Data(#"{"sync":{"version":7}}"#.utf8)) }
                if request.url!.path.hasSuffix("snapshot") {
                    if invalidateOnce.withLock({ value in let previous = value
                        value = false
                        return previous }) {
                        do {
                            try queue.write { db in
                                try db.execute(
                                    sql: "UPDATE workspaces SET syncMutationGeneration = syncMutationGeneration + 1 WHERE id = ?",
                                    arguments: [workspace]
                                )
                            }
                        } catch { Issue.record(error) }
                    }
                    return (200, [:], snapshot)
                }
                #expect(request.url!.path.hasSuffix("changes"))
                return (200, [:], Data(#"{"items":[],"cursor":"after","highWaterCursor":"after","hasMore":false}"#.utf8))
            }
            defer { ImageURLProtocol.remove(origin: origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let worker = SyncWorker(
                dbQueue: queue,
                apiClient: SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" })
            )
            try await worker.retryPull(workspaceId: workspace, connectionId: connection)
            if invalidated {
                #expect(try await queue.read { try MeetingRecord.fetchOne($0, key: accepted)?.name } == "Local")
                #expect(try await queue.read { try SyncReconciliation.keys(workspaceId: workspace, in: $0).count } == 1)
                try await worker.retryPull(workspaceId: workspace, connectionId: connection)
            }
            try await queue.read { db throws in
                #expect(try MeetingRecord.fetchOne(db, key: accepted)?.name == (deleted ? nil : "Server"))
                #expect(try MeetingRecord.fetchOne(db, key: other)?.name == "Local")
                #expect(try SyncReconciliation.keys(workspaceId: workspace, in: db).isEmpty)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions WHERE blockedReason = 'conflict'") == 1)
                #expect(try String.fetchOne(db, sql: "SELECT syncPullCursor FROM workspaces WHERE id = ?", arguments: [workspace]) == "after")
            }
        }

        @Test(arguments: ["edit", "disconnect", "discard", "move"])
        func reconciliationHonorsLaterLocalLifecycle(action: String) async throws {
            let (queue, workspace) = try seed()
            let meeting = UUID.v7()
            try await queue.write { db throws in
                try db.execute(sql: "UPDATE workspaces SET syncPullCursor = 'before' WHERE id = ?", arguments: [workspace])
                let connection = try #require(try WorkspaceRecord.fetchOne(db, key: workspace)?.accountConnectionId)
                let row = MeetingRecord(id: meeting, workspaceId: workspace, name: "Local", createdAt: .now, updatedAt: .now)
                try row.insert(db)
                for entity in [SyncEntity.meeting, .summary] {
                    try db.execute(
                        sql: "INSERT INTO sync_reconciliations(workspaceId, connectionId, entity, entityId) VALUES (?, ?, ?, ?)",
                        arguments: [workspace, connection, entity, meeting]
                    )
                }
                try db.execute(
                    sql: "UPDATE sync_reconciliations SET includeDescendants = 1 WHERE entity = 'meeting'"
                )
                try SyncReconciliation.finish(.meeting, id: meeting, workspaceId: workspace, includingDescendants: false, in: db)
                #expect(try SyncReconciliation.subtreeRoots(workspaceId: workspace, in: db) == [.init(entity: .meeting, id: meeting)])
                #expect(try MeetingRepository.fetchWorkspaceSyncState(WorkspaceRecord.fetchOne(db, key: workspace)!, in: db) == .pending)
                switch action {
                case "edit":
                    try SyncTransactionRecorder.record(
                        workspaceId: workspace,
                        operations: [SyncInitialSnapshotBuilder.meetingOperation(row, action: .update, in: db)],
                        in: db
                    )
                    #expect(try !RemoteChangePolicy.permits(.meeting, id: meeting, action: "delete", workspaceId: workspace, in: db))
                    #expect(try SyncReconciliation.keys(workspaceId: workspace, in: db).count == 2)
                case "disconnect":
                    try db.execute(
                        sql: "UPDATE workspaces SET accountConnectionId = NULL, organizationId = NULL WHERE id = ?",
                        arguments: [workspace]
                    )
                    #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_reconciliations") == 0)
                case "discard":
                    let generation = try Int64.fetchOne(
                        db,
                        sql: "SELECT syncMutationGeneration FROM workspaces WHERE id = ?",
                        arguments: [workspace]
                    )!
                    try SyncTransactionQueue.discard(workspaceId: workspace, in: db)
                    #expect(try Int64
                        .fetchOne(db, sql: "SELECT syncMutationGeneration FROM workspaces WHERE id = ?", arguments: [workspace])! > generation)
                    #expect(try SyncReconciliation.keys(workspaceId: workspace, in: db).isEmpty)
                default:
                    var destination = try #require(try WorkspaceRecord.fetchOne(db, key: workspace))
                    destination.id = .v7()
                    destination.name = "Destination"
                    try destination.insert(db)
                    try WorkspaceRelocation.move([(.init(entity: .meeting, id: meeting, workspaceId: destination.id), workspace)], in: db)
                    #expect(try SyncReconciliation.keys(workspaceId: workspace, in: db).isEmpty)
                    #expect(try MeetingRecord.fetchOne(db, key: meeting)?.workspaceId == destination.id)
                }
            }
        }

        @Test func restoredParentSelectsItsChildrenAndFilesWithoutUnrelatedLinks() async throws {
            let store = try SyncSnapshotStore()
            let root = UUID.v7(), child = UUID.v7(), meeting = UUID.v7(), file = UUID.v7(), link = UUID.v7(), other = UUID.v7()
            func change(_ entity: SyncEntity, _ id: UUID, _ fields: [String: String]) throws -> SyncChangePage.Change {
                try .init(
                    sequence: 0,
                    entity: entity,
                    entityId: id,
                    action: "upsert",
                    revision: 1,
                    record: SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: JSONSerialization.data(withJSONObject: fields))
                )
            }
            try await store.merge([
                change(.project, root, [:]), change(.project, child, ["parentProjectId": root.uuidString]),
                change(.meeting, meeting, ["projectId": child.uuidString]), change(.summary, meeting, [:]),
                change(.file, file, [:]), change(.meetingAttachment, link, ["meetingId": meeting.uuidString, "fileId": file.uuidString]),
                change(.meetingAttachment, other, ["meetingId": UUID.v7().uuidString, "fileId": file.uuidString]),
            ])
            #expect(try store.reconciliationSubtree([.init(entity: .project, id: root)]) == Set([
                .init(entity: .project, id: root), .init(entity: .project, id: child), .init(entity: .meeting, id: meeting),
                .init(entity: .summary, id: meeting), .init(entity: .file, id: file), .init(entity: .meetingAttachment, id: link),
            ]))
        }

        @Test func initialConstructionFoldsEditsAndOrdersUnbuiltParents() async throws {
            let (queue, workspace) = try seed()
            let root = UUID.v7(), child = UUID.v7(), meeting = UUID.v7(), untouched = UUID.v7()
            let first = try await queue.write { db -> [UUID] in
                for (id, parent) in [(root, UUID?.none), (child, Optional(root)), (untouched, UUID?.none)] {
                    try ProjectRecord(
                        id: id,
                        workspaceId: workspace,
                        parentProjectId: parent,
                        name: "Project",
                        createdAt: .now,
                        projectType: parent == nil ? .undefined : nil
                    ).insert(db)
                }
                var row = MeetingRecord(id: meeting, workspaceId: workspace, projectId: child, name: "Before", createdAt: .now, updatedAt: .now)
                try row.insert(db)
                let connection = try #require(try WorkspaceRecord.fetchOne(db, key: workspace)?.accountConnectionId)
                try SyncInitialProgress.start(workspaceId: workspace, connectionId: connection, restoring: false, replaceImages: false, in: db)
                row.name = "During construction"
                try row.update(db)
                try SyncTransactionRecorder.record(
                    workspaceId: workspace,
                    operations: [SyncInitialSnapshotBuilder.meetingOperation(row, action: .update, in: db)],
                    in: db
                )
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_initial_entities WHERE built = 0") == 1)
                #expect(try String.fetchOne(db, sql: "SELECT action FROM sync_operations WHERE entity = 'meeting'") == "create")
                return try UUID.fetchAll(db, sql: "SELECT id FROM sync_transactions ORDER BY sequence")
            }
            // A second construction pass resumes at the remaining entity; it never replaces
            // already-durable request identities, even after another local edit.
            try await queue.write { db in
                var row = try #require(try MeetingRecord.fetchOne(db, key: meeting))
                row.name = "Later"
                try row.update(db)
                try SyncTransactionRecorder.record(
                    workspaceId: workspace,
                    operations: [SyncInitialSnapshotBuilder.meetingOperation(row, action: .update, in: db)],
                    in: db
                )
                while try SyncInitialProgress.constructNext(workspaceId: workspace, in: db) {}
                #expect(try Set(first).isSubset(of: Set(UUID.fetchAll(db, sql: "SELECT id FROM sync_transactions"))))
                #expect(try String.fetchAll(db, sql: "SELECT action FROM sync_operations WHERE entity = 'meeting' ORDER BY rowid") == [
                    "create",
                    "update",
                ])
            }
            for expected in [root, child, meeting, meeting] {
                let claim = try #require(try await SyncTransactionQueue.claim(dbQueue: queue))
                #expect(claim.operations.first?.entityId == expected)
                try await queue.write { try $0.execute(sql: "DELETE FROM sync_transactions WHERE id = ?", arguments: [claim.id]) }
            }
            let remaining = try #require(try await SyncTransactionQueue.claim(dbQueue: queue))
            #expect(remaining.operations.first?.entityId == untouched)
        }

        @Test func initialConstructionSurvivesReopeningItsDatabase() async throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: "sync-priority-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appending(path: "state.sqlite").path
            let (queue, workspace) = try seed(path: path)
            let identities = try await queue.write { db -> [UUID] in
                for _ in 0 ..< 3 {
                    try ProjectRecord(
                        id: .v7(),
                        workspaceId: workspace,
                        parentProjectId: nil,
                        name: "Project",
                        createdAt: .now,
                        projectType: .undefined
                    ).insert(db)
                }
                let connection = try #require(try WorkspaceRecord.fetchOne(db, key: workspace)?.accountConnectionId)
                try SyncInitialProgress.start(workspaceId: workspace, connectionId: connection, restoring: false, replaceImages: false, in: db)
                #expect(try SyncInitialProgress.constructNext(workspaceId: workspace, in: db))
                return try UUID.fetchAll(db, sql: "SELECT id FROM sync_transactions ORDER BY sequence")
            }
            try queue.close()
            let reopened = try AppDatabaseManager(path: path).dbQueue
            defer { try? reopened.close() }
            try await reopened.write { db in
                #expect(try SyncInitialProgress.active(workspaceId: workspace, in: db))
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_initial_entities WHERE built = 0") == 2)
                while try SyncInitialProgress.constructNext(workspaceId: workspace, in: db) {}
                #expect(try Set(identities).isSubset(of: Set(UUID.fetchAll(db, sql: "SELECT id FROM sync_transactions"))))
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations WHERE entity = 'project'") == 3)
                #expect(try !SyncInitialProgress.active(workspaceId: workspace, in: db))
            }
        }

        @Test func transcriptTransfersUseTheBoundedLaneWithoutBlockingMetadata() async throws {
            let (queue, workspace) = try seed()
            let meeting = UUID.v7(), project = UUID.v7()
            try await queue.write { db in
                try MeetingRecord(id: meeting, workspaceId: workspace, projectId: nil, name: "Meeting", createdAt: .now, updatedAt: .now).insert(db)
                try SyncTransactionRecorder.record(
                    workspaceId: workspace,
                    background: true,
                    operations: [.init(
                        entity: .transcript,
                        action: .patch,
                        entityId: meeting,
                        payloadJSON: Data("{}".utf8)
                    )],
                    in: db
                )
                try SyncTransactionRecorder.record(
                    workspaceId: workspace,
                    background: true,
                    operations: [.init(entity: .project, action: .create, entityId: project)],
                    in: db
                )
            }
            let metadata = try #require(try await SyncTransactionQueue.claim(dbQueue: queue, allowBackgroundTransfers: false))
            #expect(metadata.operations.first?.entityId == project)
            #expect(!metadata.requiresTransfer)
            let transcript = try #require(try await SyncTransactionQueue.claim(dbQueue: queue))
            #expect(transcript.operations.first?.entityId == meeting)
            #expect(transcript.requiresTransfer)
        }

        @Test func parentRenameDoesNotSerializeChildButMoveProtectsBothParents() async throws {
            let (queue, workspace) = try seed()
            let old = UUID.v7(), new = UUID.v7(), meeting = UUID.v7()
            try await queue.write { db in
                for id in [old, new] {
                    try ProjectRecord(
                        id: id,
                        workspaceId: workspace,
                        parentProjectId: nil,
                        name: "Project",
                        createdAt: .now,
                        projectType: .undefined
                    ).insert(db)
                }
                var project = try #require(try ProjectRecord.fetchOne(db, key: old))
                project.name = "Renamed"
                try project.update(db)
                try SyncTransactionRecorder.record(
                    workspaceId: workspace,
                    operations: [SyncInitialSnapshotBuilder.projectOperation(project, action: .update)],
                    in: db
                )
                var row = MeetingRecord(id: meeting, workspaceId: workspace, projectId: old, name: "Meeting", createdAt: .now, updatedAt: .now)
                try row.insert(db)
                row.name = "Changed"
                try row.update(db)
                let edit = try #require(try SyncTransactionRecorder.record(
                    workspaceId: workspace,
                    operations: [SyncInitialSnapshotBuilder.meetingOperation(row, action: .update, in: db)],
                    in: db
                ))
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_dependencies WHERE transactionId = ?", arguments: [edit]) == 0)
                row.projectId = new
                try row.update(db)
                let move = try #require(try SyncTransactionRecorder.record(
                    workspaceId: workspace,
                    operations: [SyncInitialSnapshotBuilder.meetingOperation(row, action: .update, in: db)],
                    in: db
                ))
                for parent in [old, new] {
                    #expect(try Bool.fetchOne(
                        db,
                        sql: "SELECT EXISTS(SELECT 1 FROM sync_dependency_keys WHERE transactionId = ? AND resource = ?)",
                        arguments: [move, "exists:\(SyncDependencies.key(.project, parent))"]
                    ) == true)
                }
            }
        }

        @Test func indexingLegacyRequestsRemovesOnlyProvisionalBarriers() async throws {
            let (queue, workspace) = try seed()
            let foreground = UUID.v7()
            try await queue.write { db in
                for _ in 0 ..< 64 {
                    try SyncTransactionRecorder.record(
                        workspaceId: workspace,
                        background: true,
                        operations: [.init(entity: .project, action: .create, entityId: .v7())],
                        in: db
                    )
                }
                try db
                    .execute(
                        sql: "DELETE FROM sync_dependency_keys; DELETE FROM sync_dependencies; UPDATE sync_transactions SET dependenciesReady = 0"
                    )
                try SyncTransactionRecorder.record(
                    workspaceId: workspace,
                    operations: [.init(entity: .project, action: .create, entityId: foreground)],
                    in: db
                )
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_dependencies WHERE provisional = 1") == 64)
                while try SyncDependencies.backfill(in: db, limit: 8) > 0 {}
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_dependencies") == 0)
            }
            let claim = try #require(try await SyncTransactionQueue.claim(dbQueue: queue))
            #expect(claim.operations.first?.entityId == foreground)
            #expect(try await queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sync_transactions") } == 65)
        }

        @Test func v49UpgradePreservesPendingIdentityAndDefaultsToBackgroundBarrier() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v49_workspaceImportDestinations")
            let connection = UUID.v7(), workspace = UUID.v7(), transaction = UUID.v7()
            try queue.write { db in
                try DahliaAccountConnectionRecord(id: connection, origin: "https://example.invalid", clientID: "test", createdAt: .now).insert(db)
                try WorkspaceRecord(id: workspace, name: "Preserved", createdAt: .now, lastOpenedAt: .now).insert(db)
                try db.execute(
                    sql: "INSERT INTO sync_transactions(id, workspace_id, connectionId, createdAt, availableAt, attempts) VALUES (?, ?, ?, ?, ?, 1)",
                    arguments: [transaction, workspace, connection, Date(), Date()]
                )
            }
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.read { db in
                let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM sync_transactions WHERE id = ?", arguments: [transaction]))
                #expect(row["attempts"] as Int == 1)
                #expect(row["syncPriority"] as Int == 0)
                #expect(row["dependenciesReady"] as Int == 0)
                #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
            }
        }
    }
#endif
