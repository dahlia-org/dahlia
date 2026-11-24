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
    private var revision = 0
    private var listingSession: GoogleSession?
    private var authObserver: GoogleAuthSessionObserver?
    private var routeObserver: GoogleAuthSessionObserver?
    private var refreshTask: Task<Void, Never>?

    init(
        signIn: any GoogleSignInProviding = DatabricksProxyGoogleSignInProvider(sessionKind: .drive),
        client: GoogleDriveBackupClient = GoogleDriveBackupClient(),
        routeChangeNotification: Notification.Name = GoogleCalendarProvider.didChange
    ) {
        self.signIn = signIn
        self.client = client
        authObserver = GoogleAuthSessionObserver(notificationName: signIn.sessionDidChangeNotification) { [weak self] disconnected in
            self?.sessionChanged(disconnected: disconnected)
        }
        routeObserver = GoogleAuthSessionObserver(notificationName: routeChangeNotification) { [weak self] _ in
            self?.sessionChanged(disconnected: false)
        }
    }

    private func sessionChanged(disconnected: Bool) {
        reset()
        if !disconnected {
            refreshTask = Task { [weak self] in await self?.refresh() }
        }
    }

    var usesDatabricksProxy: Bool { (signIn as? DatabricksProxyGoogleSignInProvider)?.isProxyActive == true }
    var connectionPageURL: URL? { (signIn as? DatabricksProxyGoogleSignInProvider)?.connectionPageURL }
    var isConfigured: Bool { signIn.isConfigured }

    func reset() {
        revision += 1
        refreshTask?.cancel()
        refreshTask = nil
        listingSession = nil
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
        isBusy = true
        errorMessage = nil
        files = []
        account = nil
        listingSession = nil
        isAuthorized = false
        defer { if self.revision == revision { isBusy = false } }
        do {
            let session: GoogleSession
            if connect {
                guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { throw GoogleSignInError.missingPresentingWindow }
                session = try await signIn.signIn(withPresentingWindow: window, requestedScopes: GoogleOAuthScope.drive)
            } else {
                let hasPreviousSignIn = await signIn.hasPreviousSignIn
                guard self.revision == revision else { return }
                hasConnection = hasPreviousSignIn
                guard hasPreviousSignIn else { return }
                session = try await signIn.restorePreviousSignIn()
            }
            guard self.revision == revision else { return }
            hasConnection = true
            guard session.hasScopes(GoogleOAuthScope.drive) else { throw GoogleSignInError.noPreviousSignIn }
            let files = try await client.listBackups(session: session)
            try Task.checkCancellation()
            guard self.revision == revision else { return }
            self.files = files
            listingSession = session
            account = session.account
            isAuthorized = true
        } catch {
            guard self.revision == revision, !Task.isCancelled else { return }
            files = []
            account = nil
            listingSession = nil
            isAuthorized = false
            errorMessage = GoogleAuthErrorFormatter.message(for: error, defaultMessage: L10n.backupDriveDownloadFailed)
        }
    }

    func disconnect() async {
        reset()
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
        guard !isBusy, isAuthorized, files.contains(file), let listingSession else { throw GoogleSignInError.noPreviousSignIn }
        isBusy = true
        defer { if self.revision == revision { isBusy = false } }
        let current = try await signIn.refreshCurrentSession()
        guard self.revision == revision else { throw CancellationError() }
        guard let session = current, session.hasScopes(GoogleOAuthScope.drive),
              session.account.id == listingSession.account.id, session.apiBaseURL == listingSession.apiBaseURL else {
            reset()
            throw GoogleSignInError.noPreviousSignIn
        }
        let download = try await client.download(file, session: session)
        defer { try? FileManager.default.removeItem(at: download) }
        try Task.checkCancellation()
        guard self.revision == revision else { throw CancellationError() }
        return try await service.importGeneration(from: download)
    }
}
