#if canImport(Testing)
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    @MainActor
    struct ProviderAccountSettingsTests {
        @Test
        func schemaUpgradePreservesProvidersAndTheirWorkspaceReferences() async throws {
            try await Task.detached {
                let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
                try AppDatabaseManager.migrator.migrate(queue, upTo: "v66_skillCurator")
                let id = UUID.v7()
                let workspaceID = UUID.v7()
                try queue.write { db in
                    try db.execute(sql: """
                    INSERT INTO accounts (id, origin, clientID, createdAt, kind, email)
                    VALUES (?, 'https://workspace.example', 'test', ?, 'databricks', 'kept@example.com')
                    """, arguments: [id, Date.now])
                    try db.execute(sql: """
                    INSERT INTO workspaces (id, name, createdAt, lastOpenedAt, databricksConnectionId) VALUES (?, 'Kept', ?, ?, ?)
                    """, arguments: [workspaceID, Date.now, Date.now, id])
                }
                try AppDatabaseManager.migrator.migrate(queue)
                try queue.write { db in
                    try ProviderAccountsMigration.migrate(in: db)
                    let record = try #require(try DahliaAccountConnectionRecord.fetchOne(db, key: id))
                    #expect(record.name == nil && record.email == "kept@example.com" && record.settingsJSON == "{}")
                    #expect(try UUID.fetchOne(db, sql: "SELECT databricksConnectionId FROM workspaces WHERE id = ?", arguments: [workspaceID]) == id)
                    #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
                    #expect(try AppDatabaseManager.hasExpectedCurrentSchema(db))
                    for invalid in ["[]", "null", "invalid"] {
                        #expect(throws: DatabaseError.self) {
                            try db.execute(sql: "UPDATE provider_accounts SET settingsJSON = ? WHERE id = ?", arguments: [invalid, id])
                        }
                    }
                }
            }.value
        }

        @Test
        func savingAndClearingOnlyChangeTheirOwnJSONFields() async throws {
            let databricks = UUID.v7(), google = UUID.v7()
            let repository = try await providerSettingsRepository(accounts: [.databricks(connectionID: databricks), .google(connectionID: google)])
            try await repository.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE provider_accounts SET settingsJSON = ?",
                    arguments: [#"{"databricks":{"future":true},"cloudStorage":{"future":"kept"},"tracing":{"enabled":true}}"#]
                )
            }
            try await DatabricksCatalogSchema.save(DatabricksCatalogSchema("main.shared"), connectionID: databricks, repository: repository)
            try await GoogleDriveStorageLocation.save(#require(GoogleDriveStorageLocation("Team")), accountID: google, repository: repository)
            #expect(try await DatabricksCatalogSchema.load(connectionID: databricks, repository: repository)?.description == "main.shared")
            try await DatabricksCatalogSchema.save(nil, connectionID: databricks, repository: repository)
            try await GoogleDriveStorageLocation.save(#require(GoogleDriveStorageLocation("Dahlia")), accountID: google, repository: repository)
            #expect(try await DatabricksCatalogSchema.load(connectionID: databricks, repository: repository) == nil)
            #expect(try await GoogleDriveStorageLocation.load(accountID: google, repository: repository).folderName == "Dahlia")
            try await repository.dbQueue.read { db throws in
                for id in [databricks, google] {
                    #expect(try Bool.fetchOne(
                        db,
                        sql: "SELECT json_extract(settingsJSON, '$.databricks.future') FROM provider_accounts WHERE id = ?",
                        arguments: [id]
                    ) == true)
                    #expect(try Bool.fetchOne(
                        db,
                        sql: "SELECT json_extract(settingsJSON, '$.tracing.enabled') FROM provider_accounts WHERE id = ?",
                        arguments: [id]
                    ) == true)
                    #expect(try String.fetchOne(
                        db,
                        sql: "SELECT json_extract(settingsJSON, '$.cloudStorage.future') FROM provider_accounts WHERE id = ?",
                        arguments: [id]
                    ) == "kept")
                }
            }
        }

        @Test
        func registrationAndRenameKeepSettingsAndRemovalDeletesThem() async throws {
            let databricks = UUID.v7(), google = UUID.v7()
            let repository = try await providerSettingsRepository(accounts: [.databricks(connectionID: databricks), .google(connectionID: google)])
            try await DatabricksCatalogSchema.save(DatabricksCatalogSchema("main.shared"), connectionID: databricks, repository: repository)
            try await GoogleDriveStorageLocation.save(#require(GoogleDriveStorageLocation("Team")), accountID: google, repository: repository)
            try await Task.detached {
                let storage = DatabricksOAuthStorage.local(database: { repository.dbQueue })
                try storage.saveConnections([DatabricksConnection(id: databricks, host: "https://workspace.example", email: "new@example.com")])
                try storage.renameConnection(databricks, "Renamed")
                let googleStorage = GoogleProviderAccountStorage.local(database: { repository.dbQueue })
                try googleStorage.save(.init(
                    id: google,
                    account: .init(id: "google", displayName: "Renamed", email: "new@example.com"),
                    name: "Renamed"
                ))
            }.value
            #expect(try await DatabricksCatalogSchema.load(connectionID: databricks, repository: repository)?.description == "main.shared")
            #expect(try await GoogleDriveStorageLocation.load(accountID: google, repository: repository).folderName == "Team")
            try await Task.detached {
                try DatabricksOAuthStorage.local(database: { repository.dbQueue }).saveConnections([])
                try GoogleProviderAccountStorage.local(database: { repository.dbQueue }).remove(google)
            }.value
            #expect(try await repository.dbQueue.read { try DahliaAccountConnectionRecord.fetchCount($0) } == 0)
            await #expect(throws: ProviderStorageError.authorizationRequired) {
                try await DatabricksCatalogSchema.load(connectionID: databricks, repository: repository)
            }
        }

        @Test
        func rejectedSaveDoesNotChangeSettingsOrPublishSuccess() async throws {
            let id = UUID.v7()
            let repository = try await providerSettingsRepository(accounts: [.databricks(connectionID: id)])
            let notifications = Mutex(0)
            let token = NotificationCenter.default
                .addObserver(forName: ProviderAccountSettings.didChange(accountID: id), object: nil, queue: nil) { _ in
                    notifications.withLock { $0 += 1 }
                }
            defer { NotificationCenter.default.removeObserver(token) }
            let value = try #require(DatabricksCatalogSchema("main.shared"))
            await #expect(throws: CancellationError.self) {
                try await DatabricksCatalogSchema.save(value, connectionID: id, repository: repository) { throw CancellationError() }
            }
            #expect(try await DatabricksCatalogSchema.load(connectionID: id, repository: repository) == nil)
            #expect(notifications.withLock { $0 } == 0)
            try await DatabricksCatalogSchema.save(value, connectionID: id, repository: repository)
            #expect(notifications.withLock { $0 } == 1)
            try await DatabricksCatalogSchema.save(value, connectionID: id, repository: repository)
            #expect(notifications.withLock { $0 } == 1)
        }
    }
#endif
