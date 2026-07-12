import Foundation

@MainActor
final class GoogleDriveExportFolderConfigurationService: GoogleDriveExportFolderConfiguring {
    static let shared = GoogleDriveExportFolderConfigurationService()

    private let apiClient: any GoogleDriveAPIClientProviding
    private let settings: any GoogleDriveExportFolderSettingsProviding
    private var inFlightConfiguration: (id: UUID, key: String, task: Task<Void, Error>)?

    init(
        apiClient: any GoogleDriveAPIClientProviding = GoogleDriveAPIClient(),
        settings: any GoogleDriveExportFolderSettingsProviding = AppSettings.shared
    ) {
        self.apiClient = apiClient
        self.settings = settings
    }

    func configure(
        folderName: String,
        session: GoogleSession
    ) async throws {
        let resolvedFolderName = AppSettings.resolvedGoogleDriveExportFolderName(folderName)
        let apiClient = apiClient
        let settings = settings
        try await performSingleFlight(
            key: configurationKey(accountID: session.account.id, folderName: resolvedFolderName)
        ) {
            let folderID = try await apiClient.resolveExportFolderID(
                accessToken: session.accessToken,
                folderName: resolvedFolderName
            )
            settings.setGoogleDriveExportFolder(
                name: resolvedFolderName,
                id: folderID,
                accountID: session.account.id
            )
        }
    }

    func configureIfNeeded(session: GoogleSession) async throws {
        let folderName = settings.resolvedGoogleDriveExportFolderName
        let apiClient = apiClient
        let settings = settings
        try await performSingleFlight(
            key: configurationKey(accountID: session.account.id, folderName: folderName)
        ) {
            if let folderID = settings.googleDriveExportFolderID(forAccountID: session.account.id) {
                let isAvailable = try await apiClient.isExportFolderAvailable(
                    accessToken: session.accessToken,
                    folderID: folderID
                )
                if isAvailable {
                    return
                }
                settings.clearGoogleDriveExportFolderID(forAccountID: session.account.id)
            }

            let folderID = try await apiClient.resolveExportFolderID(
                accessToken: session.accessToken,
                folderName: folderName
            )
            settings.setGoogleDriveExportFolder(
                name: folderName,
                id: folderID,
                accountID: session.account.id
            )
        }
    }

    private func performSingleFlight(
        key: String,
        operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        while let current = inFlightConfiguration {
            if current.key == key {
                try await current.task.value
                return
            }
            _ = try? await current.task.value
        }

        let id = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.clearInFlightConfiguration(id: id) }
            try await operation()
        }
        inFlightConfiguration = (id: id, key: key, task: task)
        try await task.value
    }

    private func clearInFlightConfiguration(id: UUID) {
        guard inFlightConfiguration?.id == id else { return }
        inFlightConfiguration = nil
    }

    private func configurationKey(accountID: String, folderName: String) -> String {
        "\(accountID)\u{0}\(folderName)"
    }
}
