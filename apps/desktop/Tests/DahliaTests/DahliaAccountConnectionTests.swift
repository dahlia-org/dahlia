#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct DahliaAccountConnectionTests {
        @Test
        func allApisScopeEnablesWorkspaceSync() {
            let record = makeConnection(origin: "https://dahlia.example.com")

            #expect(DahliaAccountConnection(
                record: record,
                account: nil,
                isCloud: false,
                grantedScopes: ["all-apis"]
            ).supportsWorkspaceSync)
            #expect(!DahliaAccountConnection(
                record: record,
                account: nil,
                isCloud: false,
                grantedScopes: ["ai-gateway"]
            ).supportsWorkspaceSync)
        }

        @Test
        func migrationAddsLocalAISettingsAndSetsDeletedConnectionToLocal() async throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v39_dahliaAccountConnections")
            let workspace = makeWorkspace(name: "Existing")
            let connection = makeConnection(origin: "https://server.example.com")
            try await queue.write { db in
                try connection.insert(db)
                try db.execute(
                    sql: """
                    INSERT INTO vaults (id, path, name, createdAt, lastOpenedAt)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [workspace.id, workspace.path, workspace.name, workspace.createdAt, workspace.lastOpenedAt]
                )
            }

            try AppDatabaseManager.migrator.migrate(queue)

            let repository = MeetingRepository(dbQueue: queue)
            var migrated = try #require(try await queue.read { db in try WorkspaceRecord.fetchOne(db, key: workspace.id) })
            #expect(migrated.accountConnectionId == nil)
            #expect(migrated.localProvider == .chatGPTSubscription)
            #expect(migrated.summaryModelID == "gpt-5.6-luna")
            #expect(!migrated.aiSettingsBackfilled)

            try await repository.deleteDahliaAccountConnection(id: connection.id)

            migrated = try #require(try await queue.read { db in try WorkspaceRecord.fetchOne(db, key: workspace.id) })
            #expect(migrated.accountConnectionId == nil)
        }

        @Test
        func staleAISettingsDoNotOverwriteANewerAccountConnection() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: manager.dbQueue)
            let connection = makeConnection(origin: "https://server.example.com")
            let workspace = makeWorkspace(name: "Account")
            try await repository.insertDahliaAccountConnection(connection)
            try repository.insertWorkspace(workspace)
            var staleSettings = WorkspaceAISettingsSnapshot(
                workspace: workspace,
                localAccountSettings: .init(provider: .chatGPTSubscription, databricksProfile: "")
            )
            staleSettings.summaryModelID = "new-summary-model"

            _ = try await repository.adoptWorkspaceForServerSync(
                id: workspace.id,
                connectionID: connection.id,
                serverWorkspace: .init(
                    workspaceId: workspace.id,
                    connectionId: connection.id,
                    organizationId: .v7(),
                    name: workspace.name,
                    createdAt: .now,
                    revision: 1,
                    role: "admin"
                ),
                expectedChanges: manager.dbQueue.read { $0.totalChangesCount }
            )
            _ = try await repository.updateWorkspaceAISettings(staleSettings)

            let stored = try #require(try await manager.dbQueue.read { db in
                try WorkspaceRecord.fetchOne(db, key: workspace.id)
            })
            #expect(stored.accountConnectionId == connection.id)
            #expect(stored.summaryModelID == "new-summary-model")
        }

        @Test
        func backfillMarkerMigrationPreservesV40WorkspacesAsPending() throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v40_vaultAIAccounts")
            let workspace = makeWorkspace(name: "V40")
            try queue.write { db in
                try insertLegacyWorkspace(workspace, in: db)
            }

            try AppDatabaseManager.migrator.migrate(queue)

            let migrated = try #require(try queue.read { db in try WorkspaceRecord.fetchOne(db, key: workspace.id) })
            #expect(!migrated.aiSettingsBackfilled)
            #expect(migrated.summaryModelID == "gpt-5.6-luna")
        }

        @Test
        func legacyAISettingsBackfillUpdatesEveryExistingWorkspace() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: manager.dbQueue)
            let first = makeWorkspace(name: "First")
            let second = makeWorkspace(name: "Second")
            try await manager.dbQueue.write { db in
                try insertLegacyWorkspace(first, in: db)
                try insertLegacyWorkspace(second, in: db)
            }

            try await repository.backfillWorkspaceAISettings(WorkspaceAISettingsLegacyValues(
                localProvider: .databricks,
                databricksProfile: "work",
                summaryModelID: "summary-model",
                summaryReasoningEffort: "medium",
                chatModelID: "chat-model",
                chatReasoningEffort: "low"
            ))

            let workspaces = try await repository.fetchAllWorkspacesAsync()
            #expect(workspaces.count == 2)
            #expect(workspaces.allSatisfy { $0.localProvider == .databricks })
            #expect(workspaces.allSatisfy { $0.databricksProfile == "work" })
            #expect(workspaces.allSatisfy { $0.summaryModelID == "summary-model" })
            #expect(workspaces.allSatisfy { $0.chatModelID == "chat-model" })
            let allAISettingsBackfilled = workspaces.allSatisfy(\.aiSettingsBackfilled)
            #expect(allAISettingsBackfilled)

            try await repository.backfillWorkspaceAISettings(WorkspaceAISettingsLegacyValues(
                localProvider: .chatGPTSubscription,
                databricksProfile: "ignored",
                summaryModelID: "ignored",
                summaryReasoningEffort: "low",
                chatModelID: "ignored",
                chatReasoningEffort: "high"
            ))
            let unchanged = try await repository.fetchAllWorkspacesAsync()
            #expect(unchanged.allSatisfy { $0.localProvider == .databricks })
            #expect(unchanged.allSatisfy { $0.summaryModelID == "summary-model" })
        }

        @Test
        func explicitWorkspaceSettingsAreNotOverwrittenByLaterLegacyBackfill() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: manager.dbQueue)
            let pending = makeWorkspace(name: "Pending")
            try await manager.dbQueue.write { db in
                try insertLegacyWorkspace(pending, in: db)
            }
            var settings = try WorkspaceAISettingsSnapshot(
                workspace: #require(try await manager.dbQueue.read { db in
                    try WorkspaceRecord.fetchOne(db, key: pending.id)
                }),
                localAccountSettings: .init(provider: .chatGPTSubscription, databricksProfile: "")
            )
            settings.summaryModelID = "explicit-model"

            _ = try await repository.updateWorkspaceAISettings(settings)
            try await repository.backfillWorkspaceAISettings(WorkspaceAISettingsLegacyValues(
                localProvider: .databricks,
                databricksProfile: "legacy",
                summaryModelID: "legacy-model",
                summaryReasoningEffort: "low",
                chatModelID: "legacy-chat",
                chatReasoningEffort: "low"
            ))

            let stored = try #require(
                try await manager.dbQueue.read { db in try WorkspaceRecord.fetchOne(db, key: pending.id) }
            )
            #expect(stored.aiSettingsBackfilled)
            #expect(stored.summaryModelID == "explicit-model")
        }

        @Test
        func databaseEnforcesOneConnectionPerNormalizedOrigin() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: manager.dbQueue)
            let first = makeConnection(origin: "https://server.example.com")
            let duplicate = makeConnection(origin: first.origin)

            try await repository.insertDahliaAccountConnection(first)
            await #expect(throws: (any Error).self) {
                try await repository.insertDahliaAccountConnection(duplicate)
            }
        }

        @Test
        func tokensAndSignOutAreScopedToOneConnection() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: manager.dbQueue)
            let workspace = makeWorkspace(name: "Local")
            let cloudCredential = makeCredential(origin: "https://cloud.example.com", accountID: "cloud-user", accessToken: "cloud-token")
            let serverCredential = makeCredential(origin: "https://server.example.com", accountID: "server-user", accessToken: "server-token")
            let cloud = makeConnection(origin: cloudCredential.resource)
            let server = makeConnection(origin: serverCredential.resource)
            try await repository.insertWorkspaceAsync(workspace)
            try await repository.insertDahliaAccountConnection(cloud)
            try await repository.insertDahliaAccountConnection(server)

            let store = CredentialStoreFake(values: [cloud.id: cloudCredential, server.id: serverCredential])
            let controller = makeController(store: store)
            await controller.configure(appDatabase: manager)

            #expect(controller.cloudConnection?.id == cloud.id)
            #expect(controller.serverConnections.map(\.id) == [server.id])
            #expect(try await controller.validAccessToken(for: cloud.id) == "cloud-token")
            #expect(try await controller.validAccessToken(for: server.id) == "server-token")

            let signOut = try #require(controller.startSignOut(connectionID: cloud.id))
            await signOut.value
            #expect(controller.cloudConnection?.isSignedIn == false)
            #expect(controller.serverConnections.first?.isSignedIn == true)

            let remove = try #require(controller.startRemove(connectionID: cloud.id))
            await remove.value
            #expect(controller.connections.map(\.id) == [server.id])
            let remainingWorkspaces = try await repository.fetchAllWorkspacesAsync()
            #expect(remainingWorkspaces.map(\.id) == [workspace.id])
        }

        @Test
        func signOutPreservesPendingServerEditsAndCredentials() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: manager.dbQueue)
            let connection = makeConnection(origin: "https://server.example.com")
            let credential = makeCredential(
                origin: connection.origin,
                accountID: "server-user",
                accessToken: "server-token"
            )
            var workspace = makeWorkspace(name: "Server")
            workspace.accountConnectionId = connection.id
            if workspace.syncRole == nil { workspace.syncRole = "admin" }
            if workspace.organizationId == nil { workspace.organizationId = .v7() }
            workspace.syncConfirmedConnectionId = connection.id
            workspace.syncRole = "admin"
            try await repository.insertDahliaAccountConnection(connection)
            try repository.insertWorkspace(workspace)
            let queuedWorkspace = workspace
            try await manager.dbQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(workspace_id, entity, entityId, confirmedRevision) VALUES (?, 'workspace', ?, 1)",
                    arguments: [queuedWorkspace.id, queuedWorkspace.id]
                )
                try SyncTransactionRecorder.record(
                    workspaceId: queuedWorkspace.id,
                    operations: [SyncInitialSnapshotBuilder.workspaceOperation(queuedWorkspace, action: .update)],
                    in: db
                )
            }
            let store = CredentialStoreFake(values: [connection.id: credential])
            let controller = makeController(store: store)
            await controller.configure(appDatabase: manager)

            controller.requestSignOut(connectionID: connection.id)
            #expect(controller.pendingSignOutConnection?.id == connection.id)
            #expect(store.credential(for: connection.id) != nil)
            let signOut = try #require(controller.confirmSignOut(disposition: .moveToLocalAccount))
            await signOut.value

            let local = try #require(try repository.fetchAllWorkspaces().first)
            #expect(local.accountConnectionId == connection.id)
            #expect(local.syncConfirmedConnectionId == connection.id)
            #expect(local.syncRole == "admin")
            #expect(store.credential(for: connection.id) != nil)
            #expect(controller.errorMessage != nil)
            #expect(try await manager.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions")
            } == 1)
            #expect(try await manager.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_entity_state")
            } == 1)
        }

        @Test
        func signOutCanDeleteOnlyTheLocalWorkspaceCopies() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: manager.dbQueue)
            let connection = makeConnection(origin: "https://server.example.com")
            let credential = makeCredential(
                origin: connection.origin,
                accountID: "server-user",
                accessToken: "server-token"
            )
            var workspace = makeWorkspace(name: "Server")
            workspace.accountConnectionId = connection.id
            if workspace.syncRole == nil { workspace.syncRole = "admin" }
            if workspace.organizationId == nil { workspace.organizationId = .v7() }
            workspace.syncConfirmedConnectionId = connection.id
            workspace.syncRole = "viewer"
            try await repository.insertDahliaAccountConnection(connection)
            try repository.insertWorkspace(workspace)
            let store = CredentialStoreFake(values: [connection.id: credential])
            let controller = makeController(store: store)
            await controller.configure(appDatabase: manager)

            controller.requestSignOut(connectionID: connection.id)
            let signOut = try #require(controller.confirmSignOut(disposition: .deleteLocalCopies))
            await signOut.value

            #expect(try repository.fetchAllWorkspaces().isEmpty)
            #expect(store.credential(for: connection.id) == nil)
        }

        @Test
        func signOutDoesNotDeleteAWorkspaceWithAnActiveRecording() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: manager.dbQueue)
            let connection = makeConnection(origin: "https://server.example.com")
            let credential = makeCredential(
                origin: connection.origin,
                accountID: "server-user",
                accessToken: "server-token"
            )
            var workspace = makeWorkspace(name: "Server")
            workspace.accountConnectionId = connection.id
            if workspace.syncRole == nil { workspace.syncRole = "admin" }
            if workspace.organizationId == nil { workspace.organizationId = .v7() }
            workspace.syncConfirmedConnectionId = connection.id
            workspace.syncRole = "admin"
            let meeting = MeetingRecord(
                id: .v7(), workspaceId: workspace.id, projectId: nil, name: "Recording",
                createdAt: .now, updatedAt: .now
            )
            let session = RecordingSessionRecord(
                id: .v7(), meetingId: meeting.id, startedAt: .now, endedAt: nil,
                duration: nil, offsetSeconds: 0, createdAt: .now, updatedAt: .now
            )
            try await repository.insertDahliaAccountConnection(connection)
            try repository.insertWorkspace(workspace)
            try await manager.dbQueue.write { db in
                try meeting.insert(db)
                try session.insert(db)
            }
            let store = CredentialStoreFake(values: [connection.id: credential])
            let controller = makeController(store: store)
            await controller.configure(appDatabase: manager)

            controller.requestSignOut(connectionID: connection.id)
            let signOut = try #require(controller.confirmSignOut(disposition: .deleteLocalCopies))
            await signOut.value

            #expect(try repository.fetchAllWorkspaces().map(\.id) == [workspace.id])
            #expect(store.credential(for: connection.id) != nil)
            #expect(controller.errorMessage != nil)
        }

        @Test
        func removingRejectedCredentialDeletesKeychainItemBeforeConnection() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: manager.dbQueue)
            let connection = makeConnection(origin: "https://server.example.com")
            let mismatchedCredential = makeCredential(
                origin: "https://different.example.com",
                accountID: "user",
                accessToken: "token"
            )
            try await repository.insertDahliaAccountConnection(connection)
            let store = CredentialStoreFake(values: [connection.id: mismatchedCredential])
            let controller = makeController(store: store)
            await controller.configure(appDatabase: manager)

            #expect(controller.connections.first?.isSignedIn == false)
            let remove = try #require(controller.startRemove(connectionID: connection.id))
            await remove.value

            #expect(store.credential(for: connection.id) == nil)
            #expect(try await repository.fetchDahliaAccountConnections().isEmpty)
        }

        @Test
        func failedCredentialDeletionKeepsConnectionRecord() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: manager.dbQueue)
            let connection = makeConnection(origin: "https://server.example.com")
            try await repository.insertDahliaAccountConnection(connection)
            let store = CredentialStoreFake(values: [:], failingDeletes: [connection.id])
            let controller = makeController(store: store)
            await controller.configure(appDatabase: manager)

            let remove = try #require(controller.startRemove(connectionID: connection.id))
            await remove.value

            #expect(try await repository.fetchDahliaAccountConnections().map(\.id) == [connection.id])
            #expect(controller.errorMessage != nil)
        }

        private func makeController(store: CredentialStoreFake) -> DahliaCloudAccountController {
            DahliaCloudAccountController(
                configuration: DahliaCloudConfiguration.make(
                    urlString: "https://cloud.example.com",
                    clientID: "desktop-client"
                ),
                serviceFactory: { id, configuration in
                    DahliaCloudService(configuration: configuration, storage: store.storage(for: id))
                }
            )
        }

        private func makeWorkspace(name: String) -> WorkspaceRecord {
            let id = UUID.v7()
            return WorkspaceRecord(
                id: id,
                path: "/tmp/\(name)-\(id.uuidString)",
                name: name,
                createdAt: .now,
                lastOpenedAt: .distantPast
            )
        }

        private func makeConnection(origin: String) -> DahliaAccountConnectionRecord {
            DahliaAccountConnectionRecord(
                id: .v7(),
                origin: origin,
                clientID: "desktop-client",
                createdAt: .now
            )
        }

        private func makeCredential(
            origin: String,
            accountID: String,
            accessToken: String
        ) -> DahliaCloudCredential {
            DahliaCloudCredential(
                accessToken: accessToken,
                refreshToken: "refresh",
                expirationDate: .distantFuture,
                resource: origin,
                issuer: "https://accounts.example.com",
                clientID: "desktop-client",
                grantedScopes: ["all-apis"],
                tokenEndpoint: URL(string: "https://accounts.example.com/token")!,
                revocationEndpoint: nil,
                account: DahliaCloudAccount(id: accountID, name: accountID, email: nil)
            )
        }
    }

    private final class CredentialStoreFake: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UUID: DahliaCloudCredential]
        private let failingDeletes: Set<UUID>

        init(values: [UUID: DahliaCloudCredential], failingDeletes: Set<UUID> = []) {
            self.values = values
            self.failingDeletes = failingDeletes
        }

        func storage(for id: UUID) -> DahliaCloudCredentialStorage {
            DahliaCloudCredentialStorage(
                load: { self.lock.withLock { self.values[id] } },
                save: { credential in self.lock.withLock { self.values[id] = credential } },
                delete: {
                    if self.failingDeletes.contains(id) { throw DahliaCloudError.credentialStorageFailed }
                    self.lock.withLock { _ = self.values.removeValue(forKey: id) }
                }
            )
        }

        func credential(for id: UUID) -> DahliaCloudCredential? {
            lock.withLock { values[id] }
        }
    }
#endif
