#if canImport(Testing)
    import Foundation
    import GRDB
    @testable import Dahlia

    func providerSettingsRepository(accounts: [ProviderAccount]) async throws -> MeetingRepository {
        let database = try await Task.detached { try AppDatabaseManager(path: ":memory:") }.value
        let repository = MeetingRepository(dbQueue: database.dbQueue)
        try await database.dbQueue.write { db in
            for account in accounts {
                let kind = switch account {
                case .google: "google"
                case .databricks: "databricks"
                case .dahlia: "dahlia"
                }
                try DahliaAccountConnectionRecord(
                    id: account.connectionID, origin: "https://workspace.example/\(account.connectionID)",
                    clientID: "test", createdAt: .now, kind: kind
                ).insert(db)
            }
        }
        return repository
    }

    /// Exercise validation before the model's notification observer can invalidate the transfer.
    func setDatabricksLocationWithoutNotification(_ value: String, id: UUID, repository: MeetingRepository) async throws {
        let settings = ProviderAccountSettings(databricks: DatabricksCatalogSchema(value).map { .init(catalog: $0.catalog, schema: $0.schema) })
        let json = try String(decoding: JSONEncoder().encode(settings), as: UTF8.self)
        try await repository.dbQueue.write { db in
            try db.execute(sql: "UPDATE provider_accounts SET settingsJSON = ? WHERE id = ?", arguments: [json, id])
        }
    }

    func setGoogleDriveFolderWithoutNotification(_ value: String, id: UUID, repository: MeetingRepository) async throws {
        let settings = ProviderAccountSettings(cloudStorage: .init(googleDriveFolderName: value.nilIfBlank))
        let json = try String(decoding: JSONEncoder().encode(settings), as: UTF8.self)
        try await repository.dbQueue.write { db in
            try db.execute(sql: "UPDATE provider_accounts SET settingsJSON = ? WHERE id = ?", arguments: [json, id])
        }
    }
#endif
