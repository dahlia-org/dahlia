@MainActor
protocol GoogleDriveExportFolderSettingsProviding: AnyObject {
    var resolvedGoogleDriveExportFolderName: String { get }

    func googleDriveExportFolderID(forAccountID accountID: String) -> String?

    func setGoogleDriveExportFolder(
        name: String,
        id: String,
        accountID: String
    )

    func clearGoogleDriveExportFolderID(forAccountID accountID: String)
}
