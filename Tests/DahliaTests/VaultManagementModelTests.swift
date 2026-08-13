#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct VaultManagementModelTests {
        @Test
        func configureLoadsVaultsByLastOpenedDate() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let older = makeVault(name: "Older", lastOpenedAt: Date(timeIntervalSince1970: 1))
            let newer = makeVault(name: "Newer", lastOpenedAt: Date(timeIntervalSince1970: 2))
            try repository.insertVault(older)
            try repository.insertVault(newer)

            let model = VaultManagementModel()
            await model.configure(appDatabase: database)

            #expect(model.vaults.map(\.id) == [newer.id, older.id])
        }

        @Test
        func registeringTheSameFolderReturnsTheExistingVault() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = VaultManagementModel()
            await model.configure(appDatabase: database)
            let url = URL(filePath: "/tmp/Dahlia-VaultManagementModelTests-Duplicate", directoryHint: .isDirectory)

            let first = try #require(await model.registerVault(at: url))
            let second = try #require(await model.registerVault(
                at: url.appending(path: "..").appending(path: url.lastPathComponent)
            ))

            #expect(second.id == first.id)
            #expect(model.vaults.count == 1)
        }

        @Test
        func removesANoncurrentVault() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = VaultManagementModel()
            await model.configure(appDatabase: database)
            let vault = try #require(await model.registerVault(at: URL(
                filePath: "/tmp/Dahlia-VaultManagementModelTests-Remove",
                directoryHint: .isDirectory
            )))

            let didRemove = await model.removeVault(vault, currentVaultId: nil)

            #expect(didRemove)
            #expect(model.vaults.isEmpty)
            #expect(try MeetingRepository(dbQueue: database.dbQueue).fetchAllVaults().isEmpty)
        }

        @Test
        func doesNotRemoveTheCurrentVault() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = VaultManagementModel()
            await model.configure(appDatabase: database)
            let vault = try #require(await model.registerVault(at: URL(
                filePath: "/tmp/Dahlia-VaultManagementModelTests-Current",
                directoryHint: .isDirectory
            )))

            let didRemove = await model.removeVault(vault, currentVaultId: vault.id)

            #expect(!didRemove)
            #expect(model.vaults.map(\.id) == [vault.id])
            #expect(try MeetingRepository(dbQueue: database.dbQueue).fetchAllVaults().map(\.id) == [vault.id])
        }

        @Test
        func registrationWithoutADatabasePresentsAnError() async {
            let model = VaultManagementModel()

            let vault = await model.registerVault(at: URL(filePath: "/tmp/Unavailable", directoryHint: .isDirectory))

            #expect(vault == nil)
            #expect(model.isShowingError)
            #expect(model.errorMessage == L10n.vaultAddFailed)
        }

        @Test
        func configuringAfterDatabaseBecomesAvailableLoadsVaults() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let vault = makeVault(name: "Available", lastOpenedAt: .now)
            try repository.insertVault(vault)
            let model = VaultManagementModel()

            await model.configure(appDatabase: nil)
            await model.configure(appDatabase: database)

            #expect(model.vaults.map(\.id) == [vault.id])
        }

        private func makeVault(name: String, lastOpenedAt: Date) -> VaultRecord {
            VaultRecord(
                id: .v7(),
                path: "/tmp/\(name)",
                name: name,
                createdAt: lastOpenedAt,
                lastOpenedAt: lastOpenedAt
            )
        }
    }
#endif
