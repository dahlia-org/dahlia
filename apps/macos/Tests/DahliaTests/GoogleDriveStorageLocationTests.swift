#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    struct GoogleDriveStorageLocationTests {
        @Test(arguments: ["", "  ", ".", "..", "a/b", "a\\b", "a\nb"])
        func invalidFolderNamesAreRejected(_ name: String) {
            #expect(GoogleDriveStorageLocation(name) == nil)
        }

        @Test
        func foldersArePerAccountAndCanReturnToTheDefault() async throws {
            let first = UUID.v7()
            let second = UUID.v7()
            let repository = try await providerSettingsRepository(accounts: [.google(connectionID: first), .google(connectionID: second)])
            #expect(try await GoogleDriveStorageLocation.load(accountID: first, repository: repository).folderName == "Dahlia")
            let custom = try #require(GoogleDriveStorageLocation("  Team's backups  "))
            try await GoogleDriveStorageLocation.save(custom, accountID: first, repository: repository)
            #expect(try await GoogleDriveStorageLocation.load(accountID: first, repository: repository).folderName == "Team's backups")
            #expect(try await GoogleDriveStorageLocation.load(accountID: second, repository: repository).folderName == "Dahlia")
            try await GoogleDriveStorageLocation.save(#require(GoogleDriveStorageLocation("Dahlia")), accountID: first, repository: repository)
            #expect(try await GoogleDriveStorageLocation.load(accountID: first, repository: repository).folderName == "Dahlia")
        }
    }
#endif
