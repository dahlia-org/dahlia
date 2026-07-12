@MainActor
protocol GoogleDriveExportFolderConfiguring: AnyObject {
    func configure(
        folderName: String,
        session: GoogleSession
    ) async throws

    func configureIfNeeded(session: GoogleSession) async throws
}
