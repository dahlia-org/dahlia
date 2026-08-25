#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct VaultManagementModelTests {
        @Test
        func defaultVaultUsesTheDahliaFolderInDocuments() {
            #expect(VaultManagementModel.defaultVaultURL == URL.documentsDirectory
                .appending(path: "Dahlia", directoryHint: .isDirectory))
        }

        @Test
        func setupCreatesAndRegistersTheSelectedVault() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = VaultManagementModel()
            await model.configure(appDatabase: database)
            let rootURL = temporaryDirectoryURL()
            let selectedURL = rootURL.appending(path: "Selected", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }

            let vault = try #require(await model.createVault(at: selectedURL))

            #expect(vault.url == selectedURL)
            #expect(vault.name == "Selected")
            #expect(vault.lastOpenedAt == .distantPast)
            #expect(FileManager.default.fileExists(atPath: selectedURL.path))
            #expect(try MeetingRepository(dbQueue: database.dbQueue).fetchAllVaults().map(\.id) == [vault.id])
        }

        @Test
        func setupUsesDahliaAsTheDefaultVaultName() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = VaultManagementModel()
            await model.configure(appDatabase: database)
            let rootURL = temporaryDirectoryURL()
            let selectedURL = rootURL.appending(path: "Dahlia", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }

            let vault = try #require(await model.createVault(at: selectedURL))

            #expect(vault.name == "Dahlia")
        }

        @Test
        func setupPreservesFilesInAnExistingSelectedFolder() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = VaultManagementModel()
            await model.configure(appDatabase: database)
            let selectedURL = temporaryDirectoryURL()
            let existingFileURL = selectedURL.appending(path: "keep.txt")
            defer { try? FileManager.default.removeItem(at: selectedURL) }
            try FileManager.default.createDirectory(at: selectedURL, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: existingFileURL)

            _ = try #require(await model.createVault(at: selectedURL))

            #expect(try String(contentsOf: existingFileURL, encoding: .utf8) == "keep")
        }

        @Test
        func preservesAnExistingLastOpenedVaultAtStartup() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let existingVault = makeVault(name: "Existing", lastOpenedAt: .now)
            try repository.insertVault(existingVault)
            let model = VaultManagementModel()
            let defaultVaultURL = temporaryDirectoryURL().appending(path: "Dahlia", directoryHint: .isDirectory)

            let startupVault = await model.resolveExistingStartupVault(appDatabase: database)

            #expect(startupVault?.id == existingVault.id)
            #expect(try repository.fetchAllVaults().map(\.id) == [existingVault.id])
            #expect(!FileManager.default.fileExists(atPath: defaultVaultURL.path))
        }

        @Test
        func doesNotCreateDefaultVaultWhenExistingVaultHasNeverBeenOpened() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let existingVault = makeVault(name: "Unopened", lastOpenedAt: .distantPast)
            try repository.insertVault(existingVault)
            let model = VaultManagementModel()
            let defaultVaultURL = temporaryDirectoryURL().appending(path: "Dahlia", directoryHint: .isDirectory)

            let startupVault = await model.resolveExistingStartupVault(appDatabase: database)

            #expect(startupVault == nil)
            #expect(try repository.fetchAllVaults() == [existingVault])
            #expect(!FileManager.default.fileExists(atPath: defaultVaultURL.path))
        }

        @Test
        func presentsAnErrorWithoutRegisteringVaultWhenDefaultDirectoryCannotBeCreated() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = VaultManagementModel()
            let rootURL = temporaryDirectoryURL()
            let blockingFileURL = rootURL.appending(path: "file")
            let defaultVaultURL = blockingFileURL.appending(path: "Dahlia", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try Data().write(to: blockingFileURL)

            await model.configure(appDatabase: database)
            let startupVault = await model.createVault(at: defaultVaultURL)

            #expect(startupVault == nil)
            #expect(model.isShowingError)
            #expect(model.errorMessage == L10n.vaultAddFailed)
            #expect(try MeetingRepository(dbQueue: database.dbQueue).fetchAllVaults().isEmpty)
        }

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
        func registeringVaultFromManagementDoesNotMarkItAsOpened() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let currentVault = makeVault(name: "Current", lastOpenedAt: Date(timeIntervalSince1970: 1))
            try repository.insertVault(currentVault)
            let model = VaultManagementModel()
            await model.configure(appDatabase: database)

            let registeredVault = try #require(await model.registerVault(
                at: URL(
                    filePath: "/tmp/Dahlia-VaultManagementModelTests-Unopened",
                    directoryHint: .isDirectory
                ),
                markAsOpened: false
            ))

            #expect(registeredVault.lastOpenedAt == .distantPast)
            #expect(try repository.fetchLastOpenedVault()?.id == currentVault.id)
        }

        @Test
        func registeringFirstVaultFromManagementDoesNotMakeItLastOpened() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let model = VaultManagementModel()
            await model.configure(appDatabase: database)

            _ = try #require(await model.registerVault(
                at: URL(
                    filePath: "/tmp/Dahlia-VaultManagementModelTests-First-Unopened",
                    directoryHint: .isDirectory
                ),
                markAsOpened: false
            ))

            #expect(try repository.fetchLastOpenedVault() == nil)
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
        func renamesAVaultAndPersistsTheTrimmedName() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = VaultManagementModel()
            await model.configure(appDatabase: database)
            let vault = try #require(await model.registerVault(at: URL(
                filePath: "/tmp/Dahlia-VaultManagementModelTests-Rename",
                directoryHint: .isDirectory
            )))

            let renamedVault = try #require(await model.renameVault(vault, to: "  Customer Interviews  "))

            #expect(renamedVault.name == "Customer Interviews")
            #expect(model.vaults.first?.name == "Customer Interviews")
            #expect(try MeetingRepository(dbQueue: database.dbQueue).fetchAllVaults().first?.name == "Customer Interviews")
        }

        @Test
        func doesNotRenameAVaultToABlankName() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = VaultManagementModel()
            await model.configure(appDatabase: database)
            let vault = makeVault(name: "Original", lastOpenedAt: .now)
            try MeetingRepository(dbQueue: database.dbQueue).insertVault(vault)
            await model.loadVaults()

            let renamedVault = await model.renameVault(vault, to: "  \n  ")

            #expect(renamedVault == nil)
            #expect(model.vaults.first?.name == "Original")
            #expect(try MeetingRepository(dbQueue: database.dbQueue).fetchAllVaults().first?.name == "Original")
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

        private func temporaryDirectoryURL() -> URL {
            URL.temporaryDirectory
                .appending(path: "Dahlia-VaultManagementModelTests-\(UUID())", directoryHint: .isDirectory)
        }
    }
#endif
