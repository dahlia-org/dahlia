#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct DahliaAccountConnectionTests {

        @Test
        func migrationAddsLocalAISettingsAndSetsDeletedConnectionToLocal() async throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v39_dahliaAccountConnections")
            let workspace = makeWorkspace(name: "Existing")
            let connection = makeConnection(origin: "https://server.example.com")
            try await queue.write { db in
                try db.execute(
                    sql: "INSERT INTO dahlia_account_connections(id, origin, clientID, createdAt) VALUES (?, ?, ?, ?)",
                    arguments: [connection.id, connection.origin, connection.clientID, connection.createdAt]
                )
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
            let migrated = try #require(try await queue.read { db in try WorkspaceRecord.fetchOne(db, key: workspace.id) })
            let accountConnectionID = {
                try await queue.read { db in
                    try UUID.fetchOne(db, sql: "SELECT accountConnectionId FROM workspaces WHERE id = ?", arguments: [workspace.id])
                }
            }
            #expect(try await accountConnectionID() == nil)
            #expect(migrated.localProvider == .chatGPTSubscription)
            #expect(migrated.summaryModelID == "gpt-5.6-luna")
            #expect(!migrated.aiSettingsBackfilled)

            try await repository.deleteDahliaAccountConnection(id: connection.id)

            #expect(try await accountConnectionID() == nil)
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
                chatModelID: "chat-model",
                chatReasoningEffort: "low"
            ))

            let workspaces = try await repository.fetchAllWorkspacesAsync()
            #expect(workspaces.count == 2)
            #expect(workspaces.allSatisfy { $0.localProvider == .chatGPTSubscription })
            let profilesAreEmpty = workspaces.allSatisfy(\.databricksProfile.isEmpty)
            #expect(profilesAreEmpty)
            #expect(workspaces.allSatisfy { $0.generationSettings == WorkspaceGenerationSettings() })
            #expect(workspaces.allSatisfy { $0.chatModelID == "chat-model" })
            let allAISettingsBackfilled = workspaces.allSatisfy(\.aiSettingsBackfilled)
            #expect(allAISettingsBackfilled)

            try await repository.backfillWorkspaceAISettings(WorkspaceAISettingsLegacyValues(
                chatModelID: "ignored",
                chatReasoningEffort: "high"
            ))
            let unchanged = try await repository.fetchAllWorkspacesAsync()
            #expect(unchanged.allSatisfy { $0.localProvider == .chatGPTSubscription })
            #expect(unchanged.allSatisfy { $0.generationSettings == WorkspaceGenerationSettings() })
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
            settings.generationSettings.outputLanguage = .fr

            _ = try await repository.updateWorkspaceAISettings(settings)
            try await repository.backfillWorkspaceAISettings(WorkspaceAISettingsLegacyValues(
                chatModelID: "legacy-chat",
                chatReasoningEffort: "low"
            ))

            let stored = try #require(
                try await manager.dbQueue.read { db in try WorkspaceRecord.fetchOne(db, key: pending.id) }
            )
            #expect(stored.aiSettingsBackfilled)
            #expect(stored.generationSettings.outputLanguage == .fr)
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
