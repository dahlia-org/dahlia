@MainActor
protocol GoogleDriveExportFolderSettingsProviding: AnyObject {
    func googleDriveExportFolderID(forAccountID accountID: String) -> String?

    func setGoogleDriveExportFolder(
        id: String,
        accountID: String
    )

    func clearGoogleDriveExportFolderID(forAccountID accountID: String)
}
