import DahliaRuntimeSupport
import Foundation

enum GoogleDocsSummaryExportService {
    @MainActor
    static func exportSummary(
        document: SummaryDocument,
        context: SummaryRenderContext,
        fileName: String,
        driveStore: GoogleDriveStore? = nil,
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
        let operationStore = driveStore ?? GoogleDriveStore(scope: context.accountScope)
        await operationStore.restoreSessionIfNeeded()
        guard let accountID = operationStore.account?.id,
              let exportFolderID = settings.googleDriveExportFolderID(
                  forAccountID: accountID,
                  scope: context.accountScope
              ) else {
            throw GoogleDriveAPIError.exportFolderNotConfigured
        }

        do {
            return try await operationStore.performAuthorizedOperation { session in
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
                settings.clearGoogleDriveExportFolderID(forAccountID: accountID, scope: context.accountScope)
                throw GoogleDriveAPIError.exportFolderNotConfigured
            }
            throw error
        }
    }
}
