import Foundation

/// Non-secret, provider-owned defaults. Credentials remain in Keychain.
struct ProviderAccountSettings: Codable, Equatable, Sendable {
    struct DatabricksDefaults: Codable, Equatable, Sendable {
        var catalog: String?
        var schema: String?
    }

    struct CloudStorage: Codable, Equatable, Sendable {
        var googleDriveFolderName: String?
    }

    var databricks: DatabricksDefaults?
    var cloudStorage: CloudStorage?

    var catalogSchema: DatabricksCatalogSchema? {
        get throws {
            guard databricks?.catalog != nil || databricks?.schema != nil else { return nil }
            guard let catalog = databricks?.catalog, let schema = databricks?.schema,
                  let location = DatabricksCatalogSchema("\(catalog).\(schema)") else { throw CocoaError(.fileReadCorruptFile) }
            return location
        }
    }

    var googleDriveLocation: GoogleDriveStorageLocation {
        get throws {
            guard let name = cloudStorage?.googleDriveFolderName
            else { return GoogleDriveStorageLocation(GoogleDriveStorageLocation.defaultFolderName)! }
            guard let location = GoogleDriveStorageLocation(name) else { throw CocoaError(.fileReadCorruptFile) }
            return location
        }
    }

    static func didChange(accountID: UUID) -> Notification.Name {
        Notification.Name("ProviderAccountSettings.\(accountID.uuidString)")
    }
}
