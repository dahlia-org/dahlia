#if canImport(Testing)
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    @MainActor
    struct CloudVaultAvailabilityTests {
        @Test
        func automaticallyDiscoversOwnedAndSharedVaultsAndLaterAdditions() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = makeConnection()
            try await database.dbQueue.write { try connection.insert($0) }
            let owner = makeVault(connection: connection, role: "owner")
            let member = makeVault(connection: connection, role: "member")
            let shared = Mutex(false)
            let ownedPage = try page([owner])
            let sharedPage = try page([owner, member])
            let worker = SyncWorker(dbQueue: database.dbQueue, apiClient: client(connection: connection) { request in
                #expect(request.url?.query == "scope=accessible")
                return (200, [:], shared.withLock { $0 } ? sharedPage : ownedPage)
            })
            defer { ImageURLProtocol.remove(origin: connection.origin) }
            try await worker.discoverCloudVaults()
            #expect(try await database.dbQueue.read { try VaultRecord.fetchCount($0) } == 1)
            shared.withLock { $0 = true }
            try await worker.discoverCloudVaults()
            try await worker.discoverCloudVaults()
            try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: database.dbQueue)
            try await database.dbQueue.read { db throws in
                let owned = try #require(try VaultRecord.fetchOne(db, key: owner.vaultId))
                let received = try #require(try VaultRecord.fetchOne(db, key: member.vaultId))
                #expect(owned.allowsCanonicalEdits)
                #expect(!received.allowsCanonicalEdits)
                #expect(owned.isAwaitingInitialSync && received.isAwaitingInitialSync)
                #expect(received.path == nil && received.lastOpenedAt == .distantPast)
                #expect(received.icon == member.icon && received.color == member.color)
                #expect(received.accountConnectionId == connection.id)
                #expect(received.syncConfirmedConnectionId == connection.id)
                #expect(try Int
                    .fetchOne(db, sql: "SELECT confirmedRevision FROM sync_entity_state WHERE entityId = ?", arguments: [member.vaultId]) == 7)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_transactions") == 0)
                #expect(try VaultRecord.fetchCount(db) == 2)
            }
        }

        @Test
        func foregroundSyncDiscoversAndLoadsMeetingsWithoutOpeningSettings() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = makeConnection()
            let remote = makeVault(connection: connection)
            let meetingID = UUID.v7()
            try await database.dbQueue.write { try connection.insert($0) }
            let listing = try page([remote])
            let snapshot = try JSONSerialization.data(withJSONObject: [
                "items": [
                    ["entity": "vault", "id": remote.vaultId.uuidString, "revision": 7, "record": [
                        "vaultId": remote.vaultId.uuidString, "name": remote.name, "revision": 7,
                        "createdAt": "2023-11-14T22:13:20Z", "updatedAt": "2023-11-14T22:13:20Z",
                    ]],
                    ["entity": "meeting", "id": meetingID.uuidString, "revision": 1, "record": [
                        "meetingId": meetingID.uuidString, "vaultId": remote.vaultId.uuidString,
                        "projectId": NSNull(), "name": "Server meeting", "description": "", "revision": 1,
                        "status": "TRANSCRIPT_NOT_FOUND", "duration": NSNull(), "recordingStartedAt": NSNull(),
                        "createdAt": "2023-11-14T22:13:20Z", "updatedAt": "2023-11-14T22:13:20Z",
                    ]],
                ],
                "startCursor": "start",
                "nextCursor": NSNull(),
            ])
            let worker = SyncWorker(dbQueue: database.dbQueue, apiClient: client(connection: connection) { request in
                let path = request.url!.path
                if path == "/api/v1/vaults" { return (200, [:], listing) }
                if path == "/api/v1/organizations" { return (200, [:], Data(#"{"items":[],"nextCursor":null}"#.utf8)) }
                if path.hasSuffix("/capabilities") { return (200, [:], Data(#"{"sync":{"version":4}}"#.utf8)) }
                if path.hasSuffix("/snapshot") { return (200, [:], snapshot) }
                if path.hasSuffix("/changes") { return (
                    200,
                    [:],
                    Data(#"{"items":[],"cursor":"caught-up","highWaterCursor":"caught-up","hasMore":false}"#.utf8)
                ) }
                return (503, [:], Data())
            })
            defer { ImageURLProtocol.remove(origin: connection.origin) }
            await worker.applicationBecameActive()
            await worker.stop()
            try await database.dbQueue.read { db throws in
                let vault = try #require(try VaultRecord.fetchOne(db, key: remote.vaultId))
                #expect(vault.syncPullCursor == "caught-up")
                #expect(!vault.isAwaitingInitialSync)
                #expect(try MeetingRecord.fetchOne(db, key: meetingID)?.name == "Server meeting")
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_transactions") == 0)
            }
        }

        @Test
        func discoveryFailureDoesNotRemoveCopiesOrBlockOtherAccounts() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let failing = makeConnection()
            let healthy = makeConnection()
            try await database.dbQueue.write { db in
                try failing.insert(db)
                try healthy.insert(db)
            }
            let existing = makeVault(connection: failing)
            _ = try await MeetingRepository.registerDiscoveredCloudVaults([existing], connection: failing, dbQueue: database.dbQueue)
            let received = makeVault(connection: healthy)
            let receivedPage = try page([received])
            _ = client(connection: failing) { _ in (503, [:], Data()) }
            let worker = SyncWorker(dbQueue: database.dbQueue, apiClient: client(connection: healthy) { request in
                (200, [:], request.url?.path == "/api/v1/organizations" ? Data(#"{"items":[],"nextCursor":null}"#.utf8) : receivedPage)
            })
            defer {
                ImageURLProtocol.remove(origin: failing.origin)
                ImageURLProtocol.remove(origin: healthy.origin)
            }
            try await worker.discoverCloudVaults()
            #expect(try await database.dbQueue.read { try VaultRecord.fetchCount($0) } == 2)
        }

        @Test
        func registrationPreservesLocalAndOtherAccountVaultsAndPendingChanges() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = makeConnection()
            let other = makeConnection()
            var local = VaultRecord(
                id: .v7(),
                path: "/tmp/export",
                name: "Local",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            local.summaryModelID = "custom-model"
            var foreign = local
            foreign.id = .v7()
            foreign.path = nil
            foreign.accountConnectionId = other.id
            foreign.syncConfirmedConnectionId = other.id
            let originalLocal = local
            let originalForeign = foreign
            try await database.dbQueue.write { db in
                try connection.insert(db)
                try other.insert(db)
                try originalLocal.insert(db)
                try originalForeign.insert(db)
            }
            let remote = makeVault(connection: connection, role: "owner")
            _ = try await MeetingRepository.registerDiscoveredCloudVaults([remote], connection: connection, dbQueue: database.dbQueue)
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            _ = try await repository.updateVaultName(id: remote.vaultId, name: "Unsent name")
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE vaults SET syncPullCursor = 'saved', lastOpenedAt = ? WHERE id = ?",
                    arguments: [originalLocal.lastOpenedAt, remote.vaultId]
                )
            }
            let before = try await database.dbQueue.read { try VaultRecord.fetchOne($0, key: remote.vaultId) }
            var localResponse = remote
            localResponse.vaultId = local.id
            var foreignResponse = remote
            foreignResponse.vaultId = foreign.id
            async let first = MeetingRepository.registerDiscoveredCloudVaults(
                [remote, localResponse, foreignResponse],
                connection: connection,
                dbQueue: database.dbQueue
            )
            async let second = MeetingRepository.registerDiscoveredCloudVaults([remote], connection: connection, dbQueue: database.dbQueue)
            _ = try await (first, second)
            try await database.dbQueue.read { db throws in
                #expect(try VaultRecord.fetchOne(db, key: originalLocal.id) == originalLocal)
                #expect(try VaultRecord.fetchOne(db, key: originalForeign.id) == originalForeign)
                #expect(try VaultRecord.fetchOne(db, key: remote.vaultId) == before)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_transactions") == 1)
            }
        }

        @Test
        func lateDiscoveryCannotRecreateCopiesAfterSignOutOrConnectionRemoval() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = makeConnection()
            try await database.dbQueue.write { try connection.insert($0) }
            let remote = makeVault(connection: connection)
            let gate = DiscoveryGate()
            let remotePage = try page([remote])
            let api = client(connection: connection) { request in
                (200, [:], request.url?.path == "/api/v1/organizations" ? Data(#"{"items":[],"nextCursor":null}"#.utf8) : remotePage)
            }
            var gatedAPI = api
            gatedAPI.tokenProvider = { _, _ in
                await gate.enter()
                return "test"
            }
            let worker = SyncWorker(dbQueue: database.dbQueue, apiClient: gatedAPI)
            defer { ImageURLProtocol.remove(origin: connection.origin) }
            let discovery = Task { try await worker.discoverCloudVaults() }
            await gate.waitForEntry()
            // Suspension waits for the old request; release it after suspension has begun.
            let suspension = Task { await worker.suspendCloudVaultDiscovery(connectionID: connection.id) }
            await gate.release()
            await suspension.value
            try await discovery.value
            // Whatever completed before suspension is disposed before credentials are removed.
            try await database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM vaults")
            }
            try await worker.discoverCloudVaults()
            #expect(try await database.dbQueue.read { try VaultRecord.fetchCount($0) } == 0)
            try await database.dbQueue.write { db in _ = try DahliaAccountConnectionRecord.deleteOne(db, key: connection.id) }
            #expect(try await !MeetingRepository.registerDiscoveredCloudVaults([remote], connection: connection, dbQueue: database.dbQueue))
            await worker.resumeCloudVaultDiscovery(connectionID: connection.id)
        }

        @Test
        func initialSyncIndicatorClearsWithCursorAndDoesNotApplyToLocalVaults() {
            var vault = VaultRecord(id: .v7(), name: "Vault", createdAt: .now, lastOpenedAt: .distantPast)
            #expect(!vault.isAwaitingInitialSync)
            vault.accountConnectionId = .v7()
            vault.syncConfirmedConnectionId = vault.accountConnectionId
            #expect(vault.isAwaitingInitialSync)
            vault.syncPullCursor = "initial-snapshot-complete"
            #expect(!vault.isAwaitingInitialSync)
        }
    }

    private func makeConnection() -> DahliaAccountConnectionRecord {
        .init(id: .v7(), origin: "https://\(UUID().uuidString).example.com", clientID: "desktop", createdAt: .now)
    }

    private func makeVault(connection: DahliaAccountConnectionRecord, role: String = "member") -> CloudVaultRecord {
        .init(
            vaultId: .v7(),
            connectionId: connection.id,
            icon: "archivebox",
            color: "blue",
            name: "Server",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            revision: 7,
            role: role
        )
    }

    private func client(connection: DahliaAccountConnectionRecord, handler: @escaping ImageURLProtocol.Handler) -> SyncAPIClient {
        ImageURLProtocol.register(origin: connection.origin, handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageURLProtocol.self]
        return SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" })
    }

    private func page(_ vaults: [CloudVaultRecord]) throws -> Data {
        let items = vaults.map { vault in
            [
                "vaultId": vault.vaultId.uuidString,
                "name": vault.name,
                "icon": vault.icon ?? "",
                "color": vault.color ?? "",
                "revision": vault.revision,
                "role": vault.role,
                "createdAt": "2023-11-14T22:13:20Z",
                "updatedAt": "2023-11-14T22:13:20Z",
            ] as [String: Any]
        }
        return try JSONSerialization.data(withJSONObject: ["items": items, "nextCursor": NSNull()])
    }

    private actor DiscoveryGate {
        var entered = false
        var entryWaiter: CheckedContinuation<Void, Never>?
        var releaseWaiter: CheckedContinuation<Void, Never>?
        func enter() async {
            entered = true
            entryWaiter?.resume()
            entryWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func waitForEntry() async {
            if entered { return }
            await withCheckedContinuation { entryWaiter = $0 }
        }

        func release() {
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }
#endif
