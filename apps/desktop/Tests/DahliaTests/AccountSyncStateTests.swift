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
                try db.execute(sql: "UPDATE sync_transactions SET blockedReason = 'authorization'")
                #expect(try progress().phase == .attention)
                #expect(try progress().state == .blocked(.authorization))
                #expect(try progress().errorCode == nil)
                try db.execute(
                    sql: "UPDATE sync_transactions SET blockedReason = 'validation', serverResponseJSON = ?",
                    arguments: [#"{"code":"invalid_sync_operation"}"#]
                )
                #expect(try progress().errorCode == "invalid_sync_operation")
                try db.execute(
                    sql: "UPDATE sync_transactions SET serverResponseJSON = ?",
                    arguments: [#"{"code":400}"#]
                )
                #expect(try progress().errorCode == nil)
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

        @Test(.timeLimit(.minutes(1)))
        func progressObservationCoalescesBurstsAndDropsThePreviousDatabase() async throws {
            let (database, workspace) = try await syncedDatabase()
            let connection = try #require(workspace.accountConnectionId)
            let controller = DahliaCloudAccountController(configuration: nil, serviceFactory: { _, configuration in
                DahliaCloudService(configuration: configuration, storage: .init(load: { nil }, save: { _ in }, delete: {}))
            })
            await controller.configure(appDatabase: database)
            try await waitForProgress { controller.syncProgress[connection] != nil }
            _ = try await database.dbQueue.write { db in
                try SyncTransactionRecorder.record(workspaceId: workspace.id, operations: [
                    .init(entity: .file, action: .delete, entityId: .v7()),
                ], in: db)
            }
            try await waitForProgress { controller.syncProgress[connection]?.remaining == 1 }
            let firstUpdate = ContinuousClock.now
            for _ in 0 ..< 10 {
                _ = try await database.dbQueue.write { db in
                    try SyncTransactionRecorder.record(workspaceId: workspace.id, operations: [
                        .init(entity: .file, action: .delete, entityId: .v7()),
                    ], in: db)
                }
            }
            if firstUpdate.duration(to: .now) < .milliseconds(500) {
                #expect(controller.syncProgress[connection]?.remaining == 1)
            }
            try await waitForProgress { controller.syncProgress[connection]?.remaining == 11 }
            #expect(firstUpdate.duration(to: .now) >= .milliseconds(900))
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
