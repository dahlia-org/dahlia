#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct DahliaAccountConnectionTests {
        @Test
        func migrationPreservesVaultsWithoutAddingVaultAssignmentState() throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v38_screenshotOCRSearch")
            let vault = makeVault(name: "Existing")
            try queue.write { db in try vault.insert(db) }

            try AppDatabaseManager.migrator.migrate(queue)

            let result = try queue.read { db in
                try (
                    VaultRecord.fetchOne(db, key: vault.id),
                    DahliaAccountConnectionRecord.fetchCount(db),
                    db.tableExists("vault_account_connections")
                )
            }
            #expect(result.0?.id == vault.id)
            #expect(result.0?.path == vault.path)
            #expect(result.0?.name == vault.name)
            #expect(result.1 == 0)
            #expect(result.2 == false)
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
