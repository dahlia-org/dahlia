#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct DahliaAccountConnectionTests {
        @Test
        func artifactExportAcceptsDedicatedAndDatabricksProxyScopes() {
            let record = makeConnection(origin: "https://server.example.com")
            let account = DahliaCloudAccount(id: "user", name: "User", email: nil)

            #expect(DahliaAccountConnection(
                record: record,
                account: account,
                isCloud: false,
                grantedScopes: [DahliaArtifactExportService.requiredScope]
            ).supportsArtifactExport)
            #expect(DahliaAccountConnection(
                record: record,
                account: account,
                isCloud: false,
                grantedScopes: ["iam.current-user:read"]
            ).supportsArtifactExport)
            #expect(!DahliaAccountConnection(
                record: record,
                account: account,
                isCloud: false,
                grantedScopes: ["openid"]
            ).supportsArtifactExport)
        }

        @Test
        func migrationAddsLocalAISettingsAndSetsDeletedConnectionToLocal() async throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v39_dahliaAccountConnections")
            let vault = makeVault(name: "Existing")
            let connection = makeConnection(origin: "https://server.example.com")
            try await queue.write { db in
                try connection.insert(db)
                try db.execute(
                    sql: """
                    INSERT INTO vaults (id, path, name, createdAt, lastOpenedAt)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [vault.id, vault.path, vault.name, vault.createdAt, vault.lastOpenedAt]
                )
            }

            try AppDatabaseManager.migrator.migrate(queue)

            let repository = MeetingRepository(dbQueue: queue)
            var migrated = try #require(try await queue.read { db in try VaultRecord.fetchOne(db, key: vault.id) })
            #expect(migrated.accountConnectionId == nil)
            #expect(migrated.localProvider == .chatGPTSubscription)
            #expect(migrated.summaryModelID == "gpt-5.6-luna")
            #expect(!migrated.aiSettingsBackfilled)

            _ = try await repository.updateVaultAccountConnection(id: migrated.id, connectionID: connection.id)
            try await repository.deleteDahliaAccountConnection(id: connection.id)

            migrated = try #require(try await queue.read { db in try VaultRecord.fetchOne(db, key: vault.id) })
            #expect(migrated.accountConnectionId == nil)
        }

        @Test
        func staleAISettingsDoNotOverwriteANewerAccountConnection() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: manager.dbQueue)
            let connection = makeConnection(origin: "https://server.example.com")
            let vault = makeVault(name: "Account")
            try await repository.insertDahliaAccountConnection(connection)
            try repository.insertVault(vault)
            var staleSettings = VaultAISettingsSnapshot(vault: vault)
            staleSettings.summaryModelID = "new-summary-model"

            _ = try await repository.updateVaultAccountConnection(id: vault.id, connectionID: connection.id)
            _ = try await repository.updateVaultAISettings(staleSettings)

            let stored = try #require(try await manager.dbQueue.read { db in
                try VaultRecord.fetchOne(db, key: vault.id)
            })
            #expect(stored.accountConnectionId == connection.id)
            #expect(stored.summaryModelID == "new-summary-model")
        }

        @Test
        func backfillMarkerMigrationPreservesV40VaultsAsPending() throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v40_vaultAIAccounts")
            let vault = makeVault(name: "V40")
            try queue.write { db in
                try insertLegacyVault(vault, in: db)
            }

            try AppDatabaseManager.migrator.migrate(queue)

            let migrated = try #require(try queue.read { db in try VaultRecord.fetchOne(db, key: vault.id) })
            #expect(!migrated.aiSettingsBackfilled)
            #expect(migrated.summaryModelID == "gpt-5.6-luna")
        }

        @Test
        func legacyAISettingsBackfillUpdatesEveryExistingVault() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: manager.dbQueue)
            let first = makeVault(name: "First")
            let second = makeVault(name: "Second")
            try await manager.dbQueue.write { db in
                try insertLegacyVault(first, in: db)
                try insertLegacyVault(second, in: db)
            }

            try await repository.backfillVaultAISettings(VaultAISettingsLegacyValues(
                localProvider: .databricks,
                databricksProfile: "work",
                summaryModelID: "summary-model",
                summaryReasoningEffort: "medium",
                chatModelID: "chat-model",
                chatReasoningEffort: "low"
            ))

            let vaults = try await repository.fetchAllVaultsAsync()
            #expect(vaults.count == 2)
            #expect(vaults.allSatisfy { $0.localProvider == .databricks })
            #expect(vaults.allSatisfy { $0.databricksProfile == "work" })
            #expect(vaults.allSatisfy { $0.summaryModelID == "summary-model" })
            #expect(vaults.allSatisfy { $0.chatModelID == "chat-model" })
            #expect(vaults.allSatisfy { $0.aiSettingsBackfilled })

            try await repository.backfillVaultAISettings(VaultAISettingsLegacyValues(
                localProvider: .chatGPTSubscription,
                databricksProfile: "ignored",
                summaryModelID: "ignored",
                summaryReasoningEffort: "low",
                chatModelID: "ignored",
                chatReasoningEffort: "high"
            ))
            let unchanged = try await repository.fetchAllVaultsAsync()
            #expect(unchanged.allSatisfy { $0.localProvider == .databricks })
            #expect(unchanged.allSatisfy { $0.summaryModelID == "summary-model" })
        }

        @Test
        func explicitVaultSettingsAreNotOverwrittenByLaterLegacyBackfill() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: manager.dbQueue)
            let pending = makeVault(name: "Pending")
            try await manager.dbQueue.write { db in
                try insertLegacyVault(pending, in: db)
            }
            var settings = VaultAISettingsSnapshot(vault: try #require(
                try await manager.dbQueue.read { db in try VaultRecord.fetchOne(db, key: pending.id) }
            ))
            settings.summaryModelID = "explicit-model"

            _ = try await repository.updateVaultAISettings(settings)
            try await repository.backfillVaultAISettings(VaultAISettingsLegacyValues(
                localProvider: .databricks,
                databricksProfile: "legacy",
                summaryModelID: "legacy-model",
                summaryReasoningEffort: "low",
                chatModelID: "legacy-chat",
                chatReasoningEffort: "low"
            ))

            let stored = try #require(
                try await manager.dbQueue.read { db in try VaultRecord.fetchOne(db, key: pending.id) }
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
            let vault = makeVault(name: "Local")
            let cloudCredential = makeCredential(origin: "https://cloud.example.com", accountID: "cloud-user", accessToken: "cloud-token")
            let serverCredential = makeCredential(origin: "https://server.example.com", accountID: "server-user", accessToken: "server-token")
            let cloud = makeConnection(origin: cloudCredential.resource)
            let server = makeConnection(origin: serverCredential.resource)
            try await repository.insertVaultAsync(vault)
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
            let remainingVaults = try await repository.fetchAllVaultsAsync()
            #expect(remainingVaults.map(\.id) == [vault.id])
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

        private func makeVault(name: String) -> VaultRecord {
            let id = UUID.v7()
            return VaultRecord(
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
                grantedScopes: ["openid"],
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
