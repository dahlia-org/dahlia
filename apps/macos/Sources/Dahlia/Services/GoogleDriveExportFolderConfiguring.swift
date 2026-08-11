@MainActor
protocol GoogleDriveExportFolderConfiguring: AnyObject {
    func configureIfNeeded(session: GoogleSession) async throws
}
