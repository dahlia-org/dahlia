import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class GoogleDriveBackupModel {
    private(set) var files: [GoogleDriveBackupFile] = []
    private(set) var account: GoogleCalendarAccount?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var isAuthorized = false
    private(set) var hasConnection = false
    private let signIn: any GoogleSignInProviding
    private let client: GoogleDriveBackupClient
    private let openAccount: @MainActor () -> CodexRuntimeProvider
    private var revision = 0

    init(
        signIn: any GoogleSignInProviding = DatabricksProxyGoogleSignInProvider(sessionKind: .drive),
        client: GoogleDriveBackupClient = GoogleDriveBackupClient(),
        openAccount: @escaping @MainActor () -> CodexRuntimeProvider = { AppSettings.shared.calendarAccount }
    ) {
        self.signIn = signIn
        self.client = client
        self.openAccount = openAccount
    }

    var usesDatabricksProxy: Bool { (signIn as? DatabricksProxyGoogleSignInProvider)?.isProxyActive == true }
    var connectionPageURL: URL? { (signIn as? DatabricksProxyGoogleSignInProvider)?.connectionPageURL }
    var isConfigured: Bool { signIn.isConfigured }

    func resetForAccount() {
        revision += 1
        files = []
        account = nil
        isAuthorized = false
        hasConnection = false
        errorMessage = nil
        isBusy = false
    }

    func refresh(connect: Bool = false) async {
        guard !isBusy else { return }
        let revision = revision
        let owner = openAccount()
        isBusy = true
        errorMessage = nil
        defer { if self.revision == revision { isBusy = false } }
        do {
            let session: GoogleSession
            if connect {
                guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { throw GoogleSignInError.missingPresentingWindow }
                session = try await signIn.signIn(withPresentingWindow: window, requestedScopes: GoogleOAuthScope.drive)
            } else {
                let hasPreviousSignIn = await signIn.hasPreviousSignIn
                guard self.revision == revision, owner == openAccount() else { return }
                hasConnection = hasPreviousSignIn
                guard hasPreviousSignIn else { return }
                session = try await signIn.restorePreviousSignIn()
            }
            guard self.revision == revision, owner == openAccount() else { return }
            hasConnection = true
            guard session.hasScopes(GoogleOAuthScope.drive) else { throw GoogleSignInError.noPreviousSignIn }
            let files = try await client.listBackups(session: session)
            try Task.checkCancellation()
            guard self.revision == revision, owner == openAccount() else { return }
            self.files = files
            account = session.account
            isAuthorized = true
        } catch {
            guard self.revision == revision, owner == openAccount(), !Task.isCancelled else { return }
            files = []
            isAuthorized = false
            errorMessage = GoogleAuthErrorFormatter.message(for: error, defaultMessage: L10n.backupDriveDownloadFailed)
        }
    }

    func disconnect() async {
        guard !isBusy else { return }
        resetForAccount()
        let revision = revision
        isBusy = true
        defer { if self.revision == revision { isBusy = false } }
        do { try await signIn.disconnect() } catch {
            guard self.revision == revision else { return }
            errorMessage = error.localizedDescription
        }
    }

    func importBackup(_ file: GoogleDriveBackupFile, using service: BackupService) async throws -> BackupGeneration {
        let revision = revision
        let owner = openAccount()
        guard !isBusy, isAuthorized, files.contains(file) else { throw GoogleSignInError.noPreviousSignIn }
        isBusy = true
        defer { if self.revision == revision { isBusy = false } }
        guard let session = try await signIn.refreshCurrentSession(), session.hasScopes(GoogleOAuthScope.drive),
              self.revision == revision, owner == openAccount() else { throw GoogleSignInError.noPreviousSignIn }
        let download = try await client.download(file, session: session)
        defer { try? FileManager.default.removeItem(at: download) }
        try Task.checkCancellation()
        guard self.revision == revision, owner == openAccount() else { throw CancellationError() }
        return try await service.importGeneration(from: download)
    }
}
