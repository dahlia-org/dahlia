#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct AccountSyncStateTests {
        @Test
        func accountSyncStateAggregatesWorkspacesAndRecoversWithoutCrossingAccounts() async throws {
            let (database, workspace) = try await syncedDatabase()
            try await database.dbQueue.write { db in
                let connectionID = try #require(workspace.accountConnectionId)
                #expect(try MeetingRepository.fetchAccountSyncStates(in: db)[connectionID] == .pending)
                try db.execute(sql: "UPDATE workspaces SET syncPullCursor = 'cursor' WHERE id = ?", arguments: [workspace.id])
                #expect(try MeetingRepository.fetchAccountSyncStates(in: db)[connectionID] == .synced)

                let recordedTransactionID = try SyncTransactionRecorder.record(
                    workspaceId: workspace.id,
                    operations: [SyncOperationDraft(entity: .workspace, action: .update, entityId: workspace.id)],
                    in: db
                )
                let transactionID = try #require(recordedTransactionID)
                #expect(try MeetingRepository.fetchAccountSyncStates(in: db)[connectionID] == .pending)
                for reason in ["validation", "conflict", "authorization"] {
                    try db.execute(sql: "UPDATE sync_transactions SET blockedReason = ? WHERE id = ?", arguments: [reason, transactionID])
                    #expect(try MeetingRepository
                        .fetchAccountSyncStates(in: db)[connectionID] == .blocked(#require(SyncBlockedReason(rawValue: reason))))
                }
                try db.execute(sql: "DELETE FROM sync_transactions WHERE id = ?", arguments: [transactionID])
                #expect(try MeetingRepository.fetchAccountSyncStates(in: db)[connectionID] == .synced)

                var sibling = workspace
                sibling.id = .v7()
                sibling.path = nil
                sibling.syncRecoveryState = "recovering"
                try sibling.insert(db)
                #expect(try MeetingRepository.fetchAccountSyncStates(in: db)[connectionID] == .recovering)
                try db.execute(sql: "UPDATE workspaces SET syncRecoveryState = 'updateRequired' WHERE id = ?", arguments: [sibling.id])
                #expect(try MeetingRepository.fetchAccountSyncStates(in: db)[connectionID] == .updateRequired)

                let other = DahliaAccountConnectionRecord(
                    id: .v7(), origin: "https://other.example.com", clientID: "desktop-client", createdAt: .now
                )
                try other.insert(db)
                sibling.accountConnectionId = other.id
                if sibling.syncRole == nil { sibling.syncRole = "admin" }
                if sibling.organizationId == nil { sibling.organizationId = .v7() }
                sibling.syncConfirmedConnectionId = other.id
                sibling.syncPullCursor = "cursor"
                try sibling.update(db)
                try db.execute(sql: "UPDATE workspaces SET syncRecoveryState = 'recovering' WHERE id = ?", arguments: [sibling.id])
                let states = try MeetingRepository.fetchAccountSyncStates(in: db)
                #expect(states[connectionID] == .synced)
                #expect(states[other.id] == .recovering)
                try sibling.delete(db)
                #expect(try MeetingRepository.fetchAccountSyncStates(in: db)[other.id] == nil)
            }
        }

        @Test
        func progressDeduplicatesEntitiesAndOnlyReceiptsReduceRemainingCounts() async throws {
            let (database, workspace) = try await syncedDatabase()
            let connection = try #require(workspace.accountConnectionId)
            let meeting = UUID.v7(), file = UUID.v7(), attachment = UUID.v7()
            try await database.dbQueue.write { db in
                try db.execute(sql: "UPDATE workspaces SET syncPullCursor = 'before'")
                for _ in 0 ..< 2 {
                    try SyncTransactionRecorder.record(workspaceId: workspace.id, operations: [
                        .init(entity: .meeting, action: .delete, entityId: meeting),
                        .init(entity: .summary, action: .delete, entityId: meeting),
                        .init(entity: .transcript, action: .delete, entityId: meeting),
                        .init(entity: .file, action: .delete, entityId: file),
                        .init(entity: .meetingAttachment, action: .delete, entityId: attachment),
                    ], in: db)
                }
            }
            let before = try await database.dbQueue.read { try MeetingRepository.fetchSyncProgress(in: $0)[connection] }
            let progress = try #require(before?.workspaces.first)
            #expect(progress.meetings == 1 && progress.files == 1 && progress.attachments == 1)
            #expect(progress.remaining == 3 && progress.phase == .text)
            let claimed = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            #expect(try await database.dbQueue.read { try MeetingRepository.fetchSyncProgress(in: $0)[connection] } == before)
            try await SyncTransactionQueue.complete(claimed, response: .init(
                id: claimed.id, status: "committed", cursor: "after",
                records: claimed.operations.map { .init(entity: $0.entity, id: $0.entityId, revision: nil, record: nil) }
            ), dbQueue: database.dbQueue)
            #expect(try await database.dbQueue.read { try MeetingRepository.fetchSyncProgress(in: $0)[connection]?.remaining } == 3)
            let second = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            try await SyncTransactionQueue.complete(second, response: .init(
                id: second.id, status: "committed", cursor: "after",
                records: second.operations.map { .init(entity: $0.entity, id: $0.entityId, revision: nil, record: nil) }
            ), dbQueue: database.dbQueue)
            #expect(try await database.dbQueue.read { try MeetingRepository.fetchSyncProgress(in: $0)[connection]?.state } == .synced)
        }

        @Test
        func failedRecordingArchiveKeepsAccountOutOfSyncedState() async throws {
            let (database, workspace) = try await syncedDatabase()
            let connection = try #require(workspace.accountConnectionId)
            let meetingID = UUID.v7()
            let sessionID = UUID.v7()
            try await database.dbQueue.write { db in
                try db.execute(sql: "UPDATE workspaces SET syncPullCursor = 'cursor' WHERE id = ?", arguments: [workspace.id])
                try MeetingRecord(
                    id: meetingID,
                    workspaceId: workspace.id,
                    projectId: nil,
                    name: "Failed archive",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                try RecordingSessionRecord(
                    id: sessionID,
                    meetingId: meetingID,
                    startedAt: .now,
                    endedAt: .now,
                    duration: 1,
                    offsetSeconds: 0,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                try RecordingArchiveRecord(
                    sessionId: sessionID,
                    meetingId: meetingID,
                    workspaceId: workspace.id,
                    connectionId: connection,
                    state: "failed",
                    failureCode: "local_file_unavailable"
                ).insert(db)
            }

            let progress = try #require(try await database.dbQueue.read {
                try MeetingRepository.fetchSyncProgress(in: $0)[connection]
            })
            #expect(progress.state == .pending)
            #expect(progress.hasAttention)
            #expect(progress.summary == L10n.syncAttention)
        }

        @Test
        func progressDistinguishesPreparationRetryAttentionAndFetchWithoutPersistingNewState() async throws {
            let (database, workspace) = try await syncedDatabase()
            let connection = try #require(workspace.accountConnectionId)
            try await database.dbQueue.write { db in
                func progress() throws -> WorkspaceSyncProgress {
                    try #require(MeetingRepository.fetchSyncProgress(in: db)[connection]?.workspaces.first)
                }
                #expect(try progress().phase == .fetching)
                try db.execute(sql: "UPDATE workspaces SET syncConfirmedConnectionId = NULL")
                #expect(try progress().phase == .preparing)
                try db.execute(sql: "UPDATE workspaces SET syncConfirmedConnectionId = accountConnectionId")
                try SyncTransactionRecorder.record(workspaceId: workspace.id, operations: [
                    .init(entity: .file, action: .delete, entityId: .v7()),
                ], in: db)
                #expect(try progress().phase == .attachments)
                try db.execute(sql: "UPDATE sync_transactions SET attempts = 1, serverResponseJSON = 'http_503'")
                #expect(try progress().phase == .retrying)
                #expect(try progress().retryErrorCode == nil)
                try db.execute(sql: "UPDATE sync_transactions SET serverResponseJSON = '{\"code\":\"http_503\"}'")
                #expect(try progress().retryErrorCode == "http_503")
                try db.execute(sql: "UPDATE sync_transactions SET blockedReason = 'authorization'")
                #expect(try progress().phase == .attention)
                #expect(try progress().state == .blocked(.authorization))
                #expect(try progress().errorCode == "authorization")
                try db.execute(
                    sql: "UPDATE sync_transactions SET blockedReason = 'validation', serverResponseJSON = ?",
                    arguments: [#"{"code":"invalid_sync_operation"}"#]
                )
                #expect(try progress().errorCode == "invalid_sync_operation")
                try db.execute(
                    sql: "UPDATE sync_transactions SET serverResponseJSON = ?",
                    arguments: [#"{"code":400}"#]
                )
                #expect(try progress().errorCode == "validation")
                try db.execute(sql: "DELETE FROM sync_transactions")
                try db.execute(sql: "UPDATE workspaces SET syncPullCursor = 'after'")
                #expect(try progress().phase == .synced)
            }
        }

        @Test
        func finishingMeetingContentsDoesNotHidePendingAttachments() async throws {
            let (database, workspace) = try await syncedDatabase()
            let connection = try #require(workspace.accountConnectionId)
            try await database.dbQueue.write { db in
                try SyncTransactionRecorder.record(workspaceId: workspace.id, operations: [
                    .init(entity: .meeting, action: .delete, entityId: .v7()),
                ], in: db)
                try SyncTransactionRecorder.record(workspaceId: workspace.id, operations: [
                    .init(entity: .file, action: .delete, entityId: .v7()),
                ], in: db)
            }
            let first = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            try await SyncTransactionQueue.complete(first, response: .init(
                id: first.id, status: "committed", cursor: "after",
                records: first.operations.map { .init(entity: $0.entity, id: $0.entityId, revision: nil, record: nil) }
            ), dbQueue: database.dbQueue)
            let progress = try #require(try await database.dbQueue
                .read { try MeetingRepository.fetchSyncProgress(in: $0)[connection]?.workspaces.first })
            #expect(progress.meetings == 0 && progress.files == 1)
            #expect(progress.phase == .attachments && progress.state == .pending)
        }

        @Test
        func progressResolvesOperationThenConflictThenWorkspaceAndSeparates401From403() async throws {
            let (database, workspace) = try await syncedDatabase()
            let connection = try #require(workspace.accountConnectionId)
            let operationID = UUID.v7(), projectID = UUID.v7(), meetingID = UUID.v7()
            _ = try await database.dbQueue.write { db in
                try SyncTransactionRecorder.record(
                    workspaceId: workspace.id,
                    operations: [.init(
                        id: operationID,
                        entity: .project,
                        action: .update,
                        entityId: projectID
                    )],
                    in: db
                )
            }
            let transaction = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            try await SyncTransactionQueue.block(
                transaction,
                reason: .conflict,
                response: Data("""
                {"status":409,"code":"revision_conflict","operationId":"\(operationID)",
                "conflicts":[{"entity":"meeting","id":"\(meetingID)"}]}
                """.utf8),
                dbQueue: database.dbQueue
            )
            func issue() async throws -> SyncProgressIssue {
                try await database.dbQueue.read { db in
                    try #require(MeetingRepository.fetchSyncProgress(in: db)[connection]?.workspaces.first?.issues.first)
                }
            }

            #expect(try await issue().target == .init(entity: .project, id: projectID))
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE sync_transactions SET serverResponseJSON = ? WHERE id = ?",
                    arguments: [
                        #"{"status":409,"code":"revision_conflict","conflicts":[{"entity":"meeting","id":"\#(meetingID)"}]}"#,
                        transaction.id,
                    ]
                )
            }
            #expect(try await issue().target == .init(entity: .meeting, id: meetingID))
            for status in [401, 403] {
                try await database.dbQueue.write { db in
                    try db.execute(
                        sql: "UPDATE sync_transactions SET blockedReason = 'authorization', serverResponseJSON = ? WHERE id = ?",
                        arguments: ["{\"status\":\(status),\"code\":\"authorization\"}", transaction.id]
                    )
                }
                #expect(try await issue().status == status)
                #expect(try await issue().target == .init(entity: .workspace, id: workspace.id))
            }
        }

        @Test
        func progressReportsSuffixDiscardAndLocalBodyImpactWithPermissions() async throws {
            let (database, workspace) = try await syncedDatabase()
            let connection = try #require(workspace.accountConnectionId)
            let meetingID = UUID.v7()
            let absentFileID = UUID.v7()
            try await database.dbQueue.write { db in
                for entity in [SyncEntity.workspace, .summary, .transcript] {
                    try db.execute(
                        sql: "INSERT INTO sync_entity_state(workspace_id, entity, entityId, confirmedRevision) VALUES (?, ?, ?, 1)",
                        arguments: [workspace.id, entity.rawValue, entity == .workspace ? workspace.id : meetingID]
                    )
                }
                try TextContentStore.registerLocal(entity: .summary, id: meetingID, workspaceId: workspace.id, in: db)
                try TextContentStore.registerLocal(entity: .transcript, id: meetingID, workspaceId: workspace.id, in: db)
                // Partial and Server-absent content still belongs to the exact releaseBody target set.
                try db.execute(
                    sql: "UPDATE sync_content_state SET complete = 0 WHERE workspace_id = ? AND entity = 'transcript' AND entityId = ?",
                    arguments: [workspace.id, meetingID]
                )
                try db.execute(
                    sql: "INSERT INTO sync_content_state(workspace_id, entity, entityId, complete, present) VALUES (?, 'file', ?, 1, 0)",
                    arguments: [workspace.id, absentFileID]
                )
                try SyncTransactionRecorder.record(workspaceId: workspace.id, operations: [
                    .init(entity: .summary, action: .update, entityId: meetingID),
                    .init(entity: .transcript, action: .delete, entityId: meetingID),
                    .init(entity: .file, action: .update, entityId: absentFileID),
                ], in: db)
                try SyncTransactionRecorder.record(workspaceId: workspace.id, operations: [
                    .init(entity: .workspace, action: .update, entityId: workspace.id),
                ], in: db)
            }
            let transaction = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            try await SyncTransactionQueue.block(
                transaction,
                reason: .validation,
                response: SyncTransactionQueue.problemData(code: "invalid_sync_payload", status: 422),
                dbQueue: database.dbQueue
            )

            var progress = try #require(try await database.dbQueue.read {
                try MeetingRepository.fetchSyncProgress(in: $0)[connection]?.workspaces.first
            })
            let lastTransactionId = try #require(try await database.dbQueue.read {
                try UUID.fetchOne($0, sql: "SELECT id FROM sync_transactions ORDER BY sequence DESC LIMIT 1")
            })
            #expect(progress.discardImpact == .init(
                transactions: 2,
                operations: 4,
                records: 4,
                localBodies: 3,
                meetings: 1,
                lastTransactionId: lastTransactionId
            ))
            #expect(progress.allowsCanonicalEdits)

            try await database.dbQueue.write {
                try $0.execute(sql: "UPDATE workspaces SET syncRole = 'viewer' WHERE id = ?", arguments: [workspace.id])
            }
            progress = try #require(try await database.dbQueue.read {
                try MeetingRepository.fetchSyncProgress(in: $0)[connection]?.workspaces.first
            })
            #expect(!progress.allowsCanonicalEdits)
        }

        @Test(.timeLimit(.minutes(1)))
        func progressObservationCoalescesBurstsAndDropsThePreviousDatabase() async throws {
            let (database, workspace) = try await syncedDatabase()
            let connection = try #require(workspace.accountConnectionId)
            let controller = DahliaCloudAccountController(configuration: nil, serviceFactory: { _, configuration in
                DahliaCloudService(configuration: configuration, storage: .init(load: { nil }, save: { _ in }, delete: {}))
            })
            // Measure both throttle windows from registration, before any publication or polling delay.
            let observationStarted = ContinuousClock.now
            await controller.configure(appDatabase: database)
            try await waitForProgress { controller.syncProgress[connection] != nil }
            _ = try await database.dbQueue.write { db in
                try SyncTransactionRecorder.record(workspaceId: workspace.id, operations: [
                    .init(entity: .file, action: .delete, entityId: .v7()),
                ], in: db)
            }
            try await waitForProgress { controller.syncProgress[connection]?.remaining == 1 }
            for _ in 0 ..< 10 {
                _ = try await database.dbQueue.write { db in
                    try SyncTransactionRecorder.record(workspaceId: workspace.id, operations: [
                        .init(entity: .file, action: .delete, entityId: .v7()),
                    ], in: db)
                }
            }
            try await waitForProgress { controller.syncProgress[connection]?.remaining == 11 }
            #expect(observationStarted.duration(to: .now) >= .milliseconds(1500))
            let (replacement, otherWorkspace) = try await syncedDatabase()
            let otherConnection = try #require(otherWorkspace.accountConnectionId)
            await controller.configure(appDatabase: replacement)
            try await database.dbQueue.write { try $0.execute(sql: "DELETE FROM sync_transactions") }
            try await waitForProgress { controller.syncProgress[otherConnection] != nil }
            #expect(controller.syncProgress[connection] == nil)
            #expect(controller.syncProgress[otherConnection]?.remaining == 0)
            await controller.configure(appDatabase: nil)
            await DahliaCloudTokenServiceRegistry.shared.remove(connectionID: connection)
            await DahliaCloudTokenServiceRegistry.shared.remove(connectionID: otherConnection)
            #expect(controller.syncProgress.isEmpty)
        }

        private func waitForProgress(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(condition())
        }

        private func syncedDatabase() async throws -> (AppDatabaseManager, WorkspaceRecord) {
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://server.example.com", clientID: "desktop-client", createdAt: .now
            )
            var workspace = WorkspaceRecord(id: .v7(), path: "/tmp/sync", name: "Sync", createdAt: .now, lastOpenedAt: .now)
            workspace.accountConnectionId = connection.id
            if workspace.syncRole == nil { workspace.syncRole = "admin" }
            if workspace.organizationId == nil { workspace.organizationId = .v7() }
            workspace.syncConfirmedConnectionId = connection.id
            let savedWorkspace = workspace
            try await database.dbQueue.write { db in
                try connection.insert(db)
                try savedWorkspace.insert(db)
            }
            return (database, savedWorkspace)
        }
    }
#endif
