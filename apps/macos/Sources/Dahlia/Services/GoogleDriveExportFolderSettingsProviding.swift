@MainActor
protocol GoogleDriveExportFolderSettingsProviding: AnyObject {
    func googleDriveExportFolderID(forAccountID accountID: String, scope: AppAccountScope) -> String?

    func setGoogleDriveExportFolder(
        id: String,
        accountID: String,
        scope: AppAccountScope
    )

    func clearGoogleDriveExportFolderID(forAccountID accountID: String, scope: AppAccountScope)

    func clearGoogleDriveExportFolder(scope: AppAccountScope)
}

extension GoogleDriveExportFolderSettingsProviding {
    func googleDriveExportFolderID(forAccountID accountID: String) -> String? {
        googleDriveExportFolderID(forAccountID: accountID, scope: .local)
    }

    func setGoogleDriveExportFolder(id: String, accountID: String) {
        setGoogleDriveExportFolder(id: id, accountID: accountID, scope: .local)
    }

    func clearGoogleDriveExportFolderID(forAccountID accountID: String) {
        clearGoogleDriveExportFolderID(forAccountID: accountID, scope: .local)
    }

    func clearGoogleDriveExportFolder() {
        clearGoogleDriveExportFolder(scope: .local)
    }
}
