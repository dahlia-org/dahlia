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
    @Published private(set) var exportFolderErrorMessage: String?

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
    private let exportFolderConfiguration: any GoogleDriveExportFolderConfiguring
    private let presentingWindowProvider: @MainActor () -> NSWindow?
    private var currentSession: GoogleSession?
    private var didAttemptRestore = false
    private var authChangeTask: Task<Void, Never>?

    init(
        signInProvider: any GoogleSignInProviding = GoogleSignInAdapter(sessionKind: .drive),
        exportFolderConfiguration: any GoogleDriveExportFolderConfiguring = GoogleDriveExportFolderConfigurationService.shared,
        presentingWindowProvider: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }
    ) {
        self.signInProvider = signInProvider
        self.exportFolderConfiguration = exportFolderConfiguration
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
            lastErrorMessage = nil
            recomputeState()
            return
        }

        lastErrorMessage = nil
        state = .loading
        do {
            let session = try await signInProvider.restorePreviousSignIn()
            applySession(session)
            await configureExportFolderIfNeeded(for: session)
        } catch GoogleSignInError.noPreviousSignIn {
            clearRuntimeState()
            recomputeState()
        } catch {
            didAttemptRestore = false
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

        lastErrorMessage = nil
        state = .loading
        do {
            let session = try await signInProvider.signIn(
                withPresentingWindow: presentingWindow,
                requestedScopes: GoogleOAuthScope.drive
            )
            applySession(session)
            await configureExportFolderIfNeeded(for: session)
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
        exportFolderErrorMessage = nil
        recomputeState()
    }

    func refreshExportFolderConfiguration() async {
        guard isAuthorized else { return }
        do {
            let session = try await refreshedAuthorizedSession()
            await configureExportFolderIfNeeded(for: session)
        } catch {
            recordExportFolderError(error)
        }
    }

    func performAuthorizedOperation<T: Sendable>(
        _ operation: @Sendable (GoogleSession) async throws -> T
    ) async throws -> T {
        let session = try await refreshedAuthorizedSession()
        state = .loading
        defer { recomputeState() }
        return try await operation(session)
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
    }

    private func configureExportFolderIfNeeded(for session: GoogleSession) async {
        guard session.hasScopes(GoogleOAuthScope.drive) else { return }
        state = .loading
        defer { recomputeState() }
        do {
            try await exportFolderConfiguration.configureIfNeeded(session: session)
            exportFolderErrorMessage = nil
        } catch {
            recordExportFolderError(error)
        }
    }

    private func recordExportFolderError(_ error: Error) {
        exportFolderErrorMessage = GoogleAuthErrorFormatter.message(
            for: error,
            defaultMessage: L10n.googleDriveUnexpectedResponse
        )
        ErrorReportingService.capture(error, context: ["source": "googleDriveExportFolder"])
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
        exportFolderErrorMessage = nil
        state = .unconfigured
    }

    private func handleAuthSessionChanged() async {
        didAttemptRestore = false
        if signInProvider.hasPreviousSignIn {
            await restoreSessionIfNeeded()
        } else {
            clearRuntimeState()
            exportFolderErrorMessage = nil
            recomputeState()
        }
    }
}
