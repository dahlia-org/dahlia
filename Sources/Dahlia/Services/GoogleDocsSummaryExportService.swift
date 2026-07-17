import Foundation

enum GoogleDocsSummaryExportService {
    @MainActor
    static func exportSummary(
        document: SummaryDocument,
        context: SummaryRenderContext,
        fileName: String,
        driveStore: GoogleDriveStore = .shared,
        apiClient: any GoogleDriveAPIClientProviding = GoogleDriveAPIClient(),
        settings: any GoogleDriveExportFolderSettingsProviding = AppSettings.shared
    ) async throws -> String {
        let actionItemsHeading = L10n.actionItems
        let imageUnavailableText = L10n.summaryImageUnavailable
        let rendered = await Task.detached(priority: .userInitiated) {
            GoogleDocsSummaryRenderer.render(
                document: document,
                context: context,
                actionItemsHeading: actionItemsHeading,
                imageUnavailableText: imageUnavailableText
            )
        }.value
        let properties = [
            "dahliaKind": "summary",
            "dahliaMeetingId": context.meetingId.uuidString,
        ]
        guard let accountID = driveStore.account?.id,
              let exportFolderID = settings.googleDriveExportFolderID(forAccountID: accountID) else {
            throw GoogleDriveAPIError.exportFolderNotConfigured
        }

        do {
            return try await driveStore.performAuthorizedOperation { session in
                guard session.account.id == accountID else {
                    throw GoogleDriveAPIError.exportFolderNotConfigured
                }
                return try await apiClient.upsertGoogleDocument(
                    accessToken: session.accessToken,
                    fileName: fileName,
                    data: rendered.data,
                    dataMimeType: rendered.mimeType,
                    appProperties: properties,
                    parentFolderID: exportFolderID
                )
            }
        } catch {
            if case let .httpError(statusCode, _) = error as? GoogleDriveAPIError,
               [403, 404].contains(statusCode) {
                settings.clearGoogleDriveExportFolderID(forAccountID: accountID)
                throw GoogleDriveAPIError.exportFolderNotConfigured
            }
            throw error
        }
    }
}
