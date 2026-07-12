import AppKit
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct GoogleDriveExportFolderConfigurationServiceTests {
        @Test
        func configuringBlankNameStoresDefaultFolderIDForConnectedAccount() async throws {
            let apiClient = FolderConfigurationAPIClient(folderID: "folder-1")
            let settings = FolderConfigurationSettings()
            let service = GoogleDriveExportFolderConfigurationService(apiClient: apiClient, settings: settings)

            try await service.configure(folderName: "  ", session: defaultDriveSession)

            #expect(await apiClient.resolvedFolderNames == ["Meeting Notes"])
            #expect(settings.resolvedGoogleDriveExportFolderName == "Meeting Notes")
            #expect(settings.googleDriveExportFolderID(forAccountID: "user-1") == "folder-1")
        }

        @Test
        func exportFolderURLUsesGoogleDriveFolderID() {
            let url = AppSettings.googleDriveExportFolderURL(folderID: "folder-1_abc")

            #expect(url?.absoluteString == "https://drive.google.com/drive/folders/folder-1_abc")
            #expect(AppSettings.googleDriveExportFolderURL(folderID: "") == nil)
        }

        @Test
        func existingAvailableFolderIDSkipsFolderLookup() async throws {
            let apiClient = FolderConfigurationAPIClient(folderID: "unused-folder")
            let settings = FolderConfigurationSettings()
            settings.setGoogleDriveExportFolder(name: "Team Notes", id: "folder-1", accountID: "user-1")
            let service = GoogleDriveExportFolderConfigurationService(apiClient: apiClient, settings: settings)

            try await service.configureIfNeeded(session: defaultDriveSession)

            #expect(await apiClient.validatedFolderIDs == ["folder-1"])
            #expect(await apiClient.resolvedFolderNames.isEmpty)
            #expect(settings.googleDriveExportFolderID(forAccountID: "user-1") == "folder-1")
        }

        @Test
        func concurrentConfigurationUsesSingleFolderResolution() async throws {
            let apiClient = FolderConfigurationAPIClient(folderID: "folder-1", resolveDelay: .milliseconds(50))
            let settings = FolderConfigurationSettings()
            let service = GoogleDriveExportFolderConfigurationService(apiClient: apiClient, settings: settings)

            async let first: Void = service.configureIfNeeded(session: defaultDriveSession)
            async let second: Void = service.configureIfNeeded(session: defaultDriveSession)
            _ = try await (first, second)

            #expect(await apiClient.resolvedFolderNames == ["Meeting Notes"])
            #expect(settings.googleDriveExportFolderID(forAccountID: "user-1") == "folder-1")
        }

        @Test
        func unavailableStoredFolderIsResolvedAndReplaced() async throws {
            let apiClient = FolderConfigurationAPIClient(folderID: "replacement-folder", isFolderAvailable: false)
            let settings = FolderConfigurationSettings()
            settings.setGoogleDriveExportFolder(name: "Team Notes", id: "stale-folder", accountID: "user-1")
            let service = GoogleDriveExportFolderConfigurationService(apiClient: apiClient, settings: settings)

            try await service.configureIfNeeded(session: defaultDriveSession)

            #expect(await apiClient.validatedFolderIDs == ["stale-folder"])
            #expect(await apiClient.resolvedFolderNames == ["Team Notes"])
            #expect(settings.googleDriveExportFolderID(forAccountID: "user-1") == "replacement-folder")
        }

        @Test
        func folderIDFromAnotherAccountIsNotReused() async throws {
            let apiClient = FolderConfigurationAPIClient(folderID: "account-2-folder")
            let settings = FolderConfigurationSettings()
            settings.setGoogleDriveExportFolder(name: "Team Notes", id: "account-1-folder", accountID: "user-1")
            let service = GoogleDriveExportFolderConfigurationService(apiClient: apiClient, settings: settings)

            try await service.configureIfNeeded(session: makeDriveSession(accountID: "user-2"))

            #expect(await apiClient.validatedFolderIDs.isEmpty)
            #expect(await apiClient.resolvedFolderNames == ["Team Notes"])
            #expect(settings.googleDriveExportFolderID(forAccountID: "user-2") == "account-2-folder")
        }

        @Test
        func summaryExportUsesStoredFolderIDWithoutFolderLookup() async throws {
            let driveStore = makeAuthorizedDriveStore()
            let apiClient = FolderConfigurationAPIClient(folderID: "unused-folder")
            let settings = FolderConfigurationSettings()
            settings.setGoogleDriveExportFolder(name: "Team Notes", id: "folder-1", accountID: "user-1")
            await driveStore.restoreSessionIfNeeded()

            let fileID = try await exportSummary(
                driveStore: driveStore,
                apiClient: apiClient,
                settings: settings
            )

            #expect(fileID == "document-1")
            #expect(await apiClient.validatedFolderIDs.isEmpty)
            #expect(await apiClient.resolvedFolderNames.isEmpty)
            #expect(await apiClient.uploadedParentFolderIDs == ["folder-1"])
        }

        @Test
        func summaryExportRejectsFolderIDFromAnotherAccount() async {
            let driveStore = makeAuthorizedDriveStore()
            let apiClient = FolderConfigurationAPIClient(folderID: "unused-folder")
            let settings = FolderConfigurationSettings()
            settings.setGoogleDriveExportFolder(name: "Team Notes", id: "folder-2", accountID: "user-2")
            await driveStore.restoreSessionIfNeeded()

            do {
                _ = try await exportSummary(
                    driveStore: driveStore,
                    apiClient: apiClient,
                    settings: settings
                )
                Issue.record("Expected export to reject a folder from another account")
            } catch {
                #expect(error as? GoogleDriveAPIError == .exportFolderNotConfigured)
            }
            #expect(await apiClient.uploadedParentFolderIDs.isEmpty)
        }

        @Test
        func unavailableFolderResponseClearsStoredID() async {
            let driveStore = makeAuthorizedDriveStore()
            let apiClient = FolderConfigurationAPIClient(folderID: "unused-folder", uploadStatusCode: 404)
            let settings = FolderConfigurationSettings()
            settings.setGoogleDriveExportFolder(name: "Team Notes", id: "stale-folder", accountID: "user-1")
            await driveStore.restoreSessionIfNeeded()

            do {
                _ = try await exportSummary(
                    driveStore: driveStore,
                    apiClient: apiClient,
                    settings: settings
                )
                Issue.record("Expected export to reject an unavailable folder")
            } catch {
                #expect(error as? GoogleDriveAPIError == .exportFolderNotConfigured)
            }
            #expect(settings.googleDriveExportFolderID(forAccountID: "user-1") == nil)
        }

        private func makeAuthorizedDriveStore() -> GoogleDriveStore {
            GoogleDriveStore(
                signInProvider: FolderConfigurationSignInProvider(hasPreviousSignIn: true),
                exportFolderConfiguration: NoOpFolderConfiguration()
            )
        }

        private func exportSummary(
            driveStore: GoogleDriveStore,
            apiClient: FolderConfigurationAPIClient,
            settings: FolderConfigurationSettings
        ) async throws -> String {
            try await GoogleDocsSummaryExportService.exportSummary(
                document: SummaryDocument(title: "Weekly Sync", sections: []),
                context: SummaryRenderContext(meetingId: .v7(), createdAt: .now),
                fileName: "Weekly Sync.rtf",
                driveStore: driveStore,
                apiClient: apiClient,
                settings: settings
            )
        }
    }

    @MainActor
    private final class FolderConfigurationSettings: GoogleDriveExportFolderSettingsProviding {
        private var folderName = AppSettings.defaultGoogleDriveExportFolderName
        private var folderID: String?
        private var accountID: String?

        var resolvedGoogleDriveExportFolderName: String {
            AppSettings.resolvedGoogleDriveExportFolderName(folderName)
        }

        func googleDriveExportFolderID(forAccountID accountID: String) -> String? {
            self.accountID == accountID ? folderID : nil
        }

        func setGoogleDriveExportFolder(name: String, id: String, accountID: String) {
            folderName = name
            folderID = id
            self.accountID = accountID
        }

        func clearGoogleDriveExportFolderID(forAccountID accountID: String) {
            guard self.accountID == accountID else { return }
            folderID = nil
        }
    }

    private actor FolderConfigurationAPIClient: GoogleDriveAPIClientProviding {
        private(set) var validatedFolderIDs: [String] = []
        private(set) var resolvedFolderNames: [String] = []
        private(set) var uploadedParentFolderIDs: [String] = []
        private let folderID: String
        private let isFolderAvailable: Bool
        private let resolveDelay: Duration
        private let uploadStatusCode: Int?

        init(
            folderID: String,
            isFolderAvailable: Bool = true,
            resolveDelay: Duration = .zero,
            uploadStatusCode: Int? = nil
        ) {
            self.folderID = folderID
            self.isFolderAvailable = isFolderAvailable
            self.resolveDelay = resolveDelay
            self.uploadStatusCode = uploadStatusCode
        }

        func isExportFolderAvailable(accessToken _: String, folderID: String) async throws -> Bool {
            validatedFolderIDs.append(folderID)
            return isFolderAvailable
        }

        func resolveExportFolderID(accessToken _: String, folderName: String) async throws -> String {
            resolvedFolderNames.append(folderName)
            if resolveDelay > .zero {
                try await Task.sleep(for: resolveDelay)
            }
            return folderID
        }

        func upsertGoogleDocument(
            accessToken _: String,
            fileName _: String,
            data _: Data,
            dataMimeType _: String,
            appProperties _: [String: String],
            parentFolderID: String
        ) async throws -> String {
            uploadedParentFolderIDs.append(parentFolderID)
            if let uploadStatusCode {
                throw GoogleDriveAPIError.httpError(statusCode: uploadStatusCode, detail: "Unavailable folder")
            }
            return "document-1"
        }
    }

    @MainActor
    private final class NoOpFolderConfiguration: GoogleDriveExportFolderConfiguring {
        func configure(folderName _: String, session _: GoogleSession) async throws {}
        func configureIfNeeded(session _: GoogleSession) async throws {}
    }

    @MainActor
    private final class FolderConfigurationSignInProvider: GoogleSignInProviding {
        let isConfigured = true
        let hasPreviousSignIn: Bool
        let sessionDidChangeNotification = Notification.Name("FolderConfigurationSignInProvider.sessionDidChange")

        init(hasPreviousSignIn: Bool = false) {
            self.hasPreviousSignIn = hasPreviousSignIn
        }

        func restorePreviousSignIn() async throws -> GoogleSession {
            defaultDriveSession
        }

        func signIn(withPresentingWindow _: NSWindow, requestedScopes _: Set<String>) async throws -> GoogleSession {
            defaultDriveSession
        }

        func refreshCurrentSession() async throws -> GoogleSession? {
            defaultDriveSession
        }

        func disconnect() async throws {}
    }

    private let defaultDriveSession = makeDriveSession(accountID: "user-1")

    private func makeDriveSession(accountID: String) -> GoogleSession {
        GoogleSession(
            account: GoogleCalendarAccount(id: accountID, displayName: "Kazuki", email: "kazuki@example.com"),
            accessToken: "drive-token",
            grantedScopes: GoogleOAuthScope.authorizationScopes(for: GoogleOAuthScope.drive)
        )
    }
#endif
