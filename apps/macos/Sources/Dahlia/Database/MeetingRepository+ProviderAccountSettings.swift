import Foundation
import GRDB

extension MeetingRepository {
    nonisolated static func providerAccounts() throws -> MeetingRepository {
        guard let queue = AccountsDatabase.current() else { throw ProviderStorageError.authorizationRequired }
        return MeetingRepository(dbQueue: queue)
    }

    nonisolated func fetchProviderAccountSettings(id: UUID) async throws -> ProviderAccountSettings {
        try await dbQueue.read { db in
            guard let record = try DahliaAccountConnectionRecord.fetchOne(db, key: id) else { throw ProviderStorageError.authorizationRequired }
            return try JSONDecoder().decode(ProviderAccountSettings.self, from: Data(record.settingsJSON.utf8))
        }
    }

    nonisolated func saveDatabricksCatalogSchema(
        _ value: DatabricksCatalogSchema?,
        accountID: UUID,
        validate: @escaping @Sendable () throws -> Void = {}
    ) async throws {
        let changed = try await dbQueue.write { db in
            guard let record = try DahliaAccountConnectionRecord.fetchOne(db, key: accountID),
                  record.kind == DahliaAccountConnectionRecord.databricksKind else {
                throw ProviderStorageError.authorizationRequired
            }
            let current = try JSONDecoder().decode(ProviderAccountSettings.self, from: Data(record.settingsJSON.utf8)).catalogSchema
            try validate()
            guard current != value else { return false }
            let expression = value == nil
                ? "json_remove(settingsJSON, '$.databricks.catalog', '$.databricks.schema')"
                : "json_set(settingsJSON, '$.databricks.catalog', ?, '$.databricks.schema', ?)"
            var arguments: StatementArguments = value.map { [$0.catalog, $0.schema] } ?? []
            arguments += [accountID, DahliaAccountConnectionRecord.databricksKind]
            try db.execute(sql: "UPDATE provider_accounts SET settingsJSON = \(expression) WHERE id = ? AND kind = ?", arguments: arguments)
            return true
        }
        if changed {
            await MainActor.run { NotificationCenter.default.post(name: ProviderAccountSettings.didChange(accountID: accountID), object: nil) }
        }
    }

    nonisolated func saveGoogleDriveLocation(_ value: GoogleDriveStorageLocation, accountID: UUID) async throws {
        let changed = try await dbQueue.write { db in
            guard let record = try DahliaAccountConnectionRecord.fetchOne(db, key: accountID), record.kind == "google" else {
                throw ProviderStorageError.authorizationRequired
            }
            let current = try JSONDecoder().decode(ProviderAccountSettings.self, from: Data(record.settingsJSON.utf8)).googleDriveLocation
            guard current != value else { return false }
            let expression = value.folderName == GoogleDriveStorageLocation.defaultFolderName
                ? "json_remove(settingsJSON, '$.cloudStorage.googleDriveFolderName')"
                : "json_set(settingsJSON, '$.cloudStorage.googleDriveFolderName', ?)"
            var arguments: StatementArguments = value.folderName == GoogleDriveStorageLocation.defaultFolderName ? [] : [value.folderName]
            arguments += [accountID]
            try db.execute(sql: "UPDATE provider_accounts SET settingsJSON = \(expression) WHERE id = ? AND kind = 'google'", arguments: arguments)
            return true
        }
        if changed {
            await MainActor.run { NotificationCenter.default.post(name: ProviderAccountSettings.didChange(accountID: accountID), object: nil) }
        }
    }
}
