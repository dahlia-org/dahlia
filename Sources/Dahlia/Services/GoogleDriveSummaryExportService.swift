import Foundation

enum GoogleDriveSummaryExportService {
    @MainActor
    static func exportSummary(
        folderId: String,
        meetingId: UUID,
        projectId: UUID?,
        fileName: String,
        markdown: String
    ) async throws -> String {
        let signInProvider = GoogleSignInAdapter(sessionKind: .drive)
        let apiClient = GoogleDriveAPIClient()
        guard let session = try await signInProvider.refreshCurrentSession(),
              session.hasScopes(GoogleOAuthScope.drive) else {
            throw GoogleSignInError.noPreviousSignIn
        }

        var properties: [String: String] = [
            "dahliaKind": "summary",
            "dahliaMeetingId": meetingId.uuidString,
        ]
        if let projectId {
            properties["dahliaProjectId"] = projectId.uuidString
        }

        return try await apiClient.upsertGoogleDocument(
            accessToken: session.accessToken,
            parentFolderId: folderId,
            fileName: fileName,
            content: markdown,
            appProperties: properties
        )
    }
}
