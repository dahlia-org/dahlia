import AppKit
import Foundation

@MainActor
final class GoogleDriveStore: ObservableObject {
    enum State: Equatable {
        case unconfigured
        case signedOut
        case loading
        case connected
        case failed
    }

    static let shared = GoogleDriveStore()

    @Published private(set) var state: State
    @Published private(set) var account: GoogleCalendarAccount?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var folders: [GoogleDriveFolderItem] = []

    var isConfigured: Bool {
        signInProvider.isConfigured
    }

    var isAuthorized: Bool {
        currentSession?.hasScopes(GoogleOAuthScope.drive) == true
    }

    var isBusy: Bool {
        state == .loading
    }

    private let signInProvider: any GoogleSignInProviding
    private let apiClient: any GoogleDriveAPIClientProviding
    private let presentingWindowProvider: @MainActor () -> NSWindow?
    private var currentSession: GoogleSession?
    private var didAttemptRestore = false
    private var authChangeTask: Task<Void, Never>?

    init(
        signInProvider: any GoogleSignInProviding = GoogleSignInAdapter(sessionKind: .drive),
        apiClient: any GoogleDriveAPIClientProviding = GoogleDriveAPIClient(),
        presentingWindowProvider: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }
    ) {
        self.signInProvider = signInProvider
        self.apiClient = apiClient
        self.presentingWindowProvider = presentingWindowProvider
        let sessionDidChangeNotification = signInProvider.sessionDidChangeNotification
        self.state = signInProvider.isConfigured ? .signedOut : .unconfigured
        authChangeTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: sessionDidChangeNotification) {
                await self?.handleAuthSessionChanged()
            }
        }
    }

    deinit {
        authChangeTask?.cancel()
    }

    func restoreSessionIfNeeded() async {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true

        guard isConfigured else {
            transitionToUnconfiguredState()
            return
        }

        guard signInProvider.hasPreviousSignIn else {
            recomputeState()
            return
        }

        state = .loading
        do {
            let session = try await signInProvider.restorePreviousSignIn()
            applySession(session)
        } catch GoogleSignInError.noPreviousSignIn {
            clearRuntimeState()
            recomputeState()
        } catch {
            handle(error)
            recomputeStateIfNeeded()
        }
    }

    func signIn() async {
        guard isConfigured else {
            transitionToUnconfiguredState()
            return
        }

        guard let presentingWindow = presentingWindowProvider() else {
            handle(GoogleSignInError.missingPresentingWindow)
            return
        }

        state = .loading
        do {
            let session = try await signInProvider.signIn(
                withPresentingWindow: presentingWindow,
                requestedScopes: GoogleOAuthScope.drive
            )
            applySession(session)
        } catch {
            handle(error)
            recomputeStateIfNeeded()
        }
    }

    func disconnect() async {
        state = .loading
        do {
            try await signInProvider.disconnect()
        } catch {
            handle(error)
        }
        clearRuntimeState()
        recomputeState()
    }

    func searchFolders(query: String) async {
        guard isAuthorized, let session = currentSession else {
            folders = []
            recomputeState()
            return
        }

        state = .loading
        do {
            folders = try await apiClient.searchFolders(accessToken: session.accessToken, query: query)
            lastErrorMessage = nil
            recomputeState()
        } catch {
            handle(error)
            recomputeStateIfNeeded()
        }
    }

    func browseFolders(parentFolderId: String?) async {
        guard isAuthorized, let session = currentSession else {
            folders = []
            recomputeState()
            return
        }

        state = .loading
        do {
            folders = try await apiClient.listFolders(
                accessToken: session.accessToken,
                parentFolderId: parentFolderId,
                driveId: nil
            )
            lastErrorMessage = nil
            recomputeState()
        } catch {
            handle(error)
            recomputeStateIfNeeded()
        }
    }

    func browseFolders(parentFolderId: String?, driveId: String?) async {
        guard isAuthorized, let session = currentSession else {
            folders = []
            recomputeState()
            return
        }

        state = .loading
        do {
            folders = try await apiClient.listFolders(
                accessToken: session.accessToken,
                parentFolderId: parentFolderId,
                driveId: driveId
            )
            lastErrorMessage = nil
            recomputeState()
        } catch {
            handle(error)
            recomputeStateIfNeeded()
        }
    }

    func browseRecentFolders() async {
        guard isAuthorized, let session = currentSession else {
            folders = []
            recomputeState()
            return
        }

        state = .loading
        do {
            folders = try await apiClient.listRecentFolders(accessToken: session.accessToken)
            lastErrorMessage = nil
            recomputeState()
        } catch {
            handle(error)
            recomputeStateIfNeeded()
        }
    }

    func browseSharedDrives() async {
        guard isAuthorized, let session = currentSession else {
            folders = []
            recomputeState()
            return
        }

        state = .loading
        do {
            folders = try await apiClient.listSharedDrives(accessToken: session.accessToken)
            lastErrorMessage = nil
            recomputeState()
        } catch {
            handle(error)
            recomputeStateIfNeeded()
        }
    }

    func resolveFolder(id: String) async throws -> GoogleDriveFolderItem {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GoogleDriveAPIError.folderNotFound
        }

        let session = try await refreshedAuthorizedSession()
        return try await apiClient.fetchFolder(accessToken: session.accessToken, id: trimmed)
    }

    func authorizedSession() async throws -> GoogleSession {
        try await refreshedAuthorizedSession()
    }

    private func refreshedAuthorizedSession() async throws -> GoogleSession {
        guard let session = try await signInProvider.refreshCurrentSession() ?? currentSession,
              session.hasScopes(GoogleOAuthScope.drive) else {
            throw GoogleSignInError.noPreviousSignIn
        }
        applySession(session)
        return session
    }

    private func applySession(_ session: GoogleSession) {
        currentSession = session
        account = session.account
        lastErrorMessage = nil
        recomputeState()
    }

    private func clearRuntimeState() {
        currentSession = nil
        if account != nil { account = nil }
        if !folders.isEmpty { folders = [] }
    }

    private func handle(_ error: Error) {
        lastErrorMessage = GoogleAuthErrorFormatter.message(for: error, defaultMessage: L10n.googleDriveUnexpectedResponse)
        state = .failed
        ErrorReportingService.capture(error, context: ["source": "googleDrive"])
    }

    private func recomputeState() {
        let newState: State = if !isConfigured {
            .unconfigured
        } else if !isAuthorized {
            .signedOut
        } else {
            .connected
        }
        if state != newState {
            state = newState
        }
    }

    private func recomputeStateIfNeeded() {
        guard state != .loading else { return }
        if state != .failed {
            recomputeState()
        }
    }

    private func transitionToUnconfiguredState() {
        clearRuntimeState()
        state = .unconfigured
    }

    private func handleAuthSessionChanged() async {
        didAttemptRestore = false
        if signInProvider.hasPreviousSignIn {
            await restoreSessionIfNeeded()
        } else {
            clearRuntimeState()
            recomputeState()
        }
    }
}
