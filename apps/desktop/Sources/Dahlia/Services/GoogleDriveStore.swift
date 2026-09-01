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
    @Published private(set) var accountScope: AppAccountScope

    var isConfigured: Bool {
        signInProvider.isConfigured
    }

    var isAuthorized: Bool {
        currentSession?.hasScopes(GoogleOAuthScope.drive) == true
    }

    var isBusy: Bool {
        state == .loading
    }

    private var signInProvider: any GoogleSignInProviding
    private var exportFolderConfiguration: any GoogleDriveExportFolderConfiguring
    private let settings: any GoogleDriveExportFolderSettingsProviding
    private let presentingWindowProvider: @MainActor () -> NSWindow?
    private var currentSession: GoogleSession?
    private var didAttemptRestore = false
    private var authChangeObserver: GoogleAuthSessionObserver?
    private let supportsAccountSwitching: Bool
    private var activationGeneration = 0

    init(
        scope: AppAccountScope = .local,
        signInProvider: (any GoogleSignInProviding)? = nil,
        exportFolderConfiguration: (any GoogleDriveExportFolderConfiguring)? = nil,
        settings: any GoogleDriveExportFolderSettingsProviding = AppSettings.shared,
        presentingWindowProvider: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }
    ) {
        self.accountScope = scope
        self.signInProvider = signInProvider ?? GoogleSignInAdapter(sessionKind: .drive(scope))
        self.exportFolderConfiguration = exportFolderConfiguration
            ?? GoogleDriveExportFolderConfigurationService(settings: settings, scope: scope)
        self.settings = settings
        supportsAccountSwitching = signInProvider == nil && exportFolderConfiguration == nil
        self.presentingWindowProvider = presentingWindowProvider
        let sessionDidChangeNotification = self.signInProvider.sessionDidChangeNotification
        self.state = self.signInProvider.isConfigured ? .signedOut : .unconfigured
        authChangeObserver = GoogleAuthSessionObserver(notificationName: sessionDidChangeNotification) { [weak self] forceSignOut in
            await self?.handleAuthSessionChanged(forceSignOut: forceSignOut)
        }
    }

    func activate(scope: AppAccountScope) async {
        guard accountScope != scope else {
            await restoreSessionIfNeeded()
            return
        }
        guard supportsAccountSwitching else { return }
        activationGeneration += 1
        accountScope = scope
        signInProvider = GoogleSignInAdapter(sessionKind: .drive(scope))
        exportFolderConfiguration = GoogleDriveExportFolderConfigurationService(settings: settings, scope: scope)
        authChangeObserver = GoogleAuthSessionObserver(
            notificationName: signInProvider.sessionDidChangeNotification
        ) { [weak self] forceSignOut in
            await self?.handleAuthSessionChanged(forceSignOut: forceSignOut)
        }
        didAttemptRestore = false
        lastErrorMessage = nil
        exportFolderErrorMessage = nil
        clearRuntimeState()
        recomputeState()
        await restoreSessionIfNeeded()
    }

    func restoreSessionIfNeeded() async {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true
        let generation = activationGeneration
        let provider = signInProvider
        let configuration = exportFolderConfiguration

        guard isConfigured else {
            transitionToUnconfiguredState()
            return
        }

        guard await provider.hasPreviousSignIn else {
            guard generation == activationGeneration else { return }
            lastErrorMessage = nil
            recomputeState()
            return
        }

        lastErrorMessage = nil
        state = .loading
        do {
            let session = try await provider.restorePreviousSignIn()
            guard generation == activationGeneration else { return }
            applySession(session)
            await configureExportFolderIfNeeded(
                for: session,
                generation: generation,
                configuration: configuration
            )
        } catch GoogleSignInError.noPreviousSignIn {
            guard generation == activationGeneration else { return }
            clearRuntimeState()
            recomputeState()
        } catch {
            guard generation == activationGeneration else { return }
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
        let generation = activationGeneration
        let provider = signInProvider
        let configuration = exportFolderConfiguration
        do {
            let session = try await provider.signIn(
                withPresentingWindow: presentingWindow,
                requestedScopes: GoogleOAuthScope.drive
            )
            guard generation == activationGeneration else { return }
            applySession(session)
            await configureExportFolderIfNeeded(
                for: session,
                generation: generation,
                configuration: configuration
            )
        } catch {
            guard generation == activationGeneration else { return }
            handle(error)
            recomputeStateIfNeeded()
        }
    }

    func disconnect() async {
        let generation = activationGeneration
        let scope = accountScope
        let provider = signInProvider
        state = .loading
        var disconnectError: Error?
        do {
            try await provider.disconnect()
        } catch {
            disconnectError = error
        }
        settings.clearGoogleDriveExportFolder(scope: scope)
        guard generation == activationGeneration, accountScope == scope else { return }
        if let disconnectError {
            handle(disconnectError)
        }
        clearRuntimeState()
        exportFolderErrorMessage = nil
        recomputeState()
    }

    func refreshExportFolderConfiguration() async {
        guard isAuthorized else { return }
        let generation = activationGeneration
        let provider = signInProvider
        let configuration = exportFolderConfiguration
        do {
            let session = try await refreshedAuthorizedSession(using: provider, generation: generation)
            await configureExportFolderIfNeeded(
                for: session,
                generation: generation,
                configuration: configuration
            )
        } catch {
            guard generation == activationGeneration else { return }
            recordExportFolderError(error)
        }
    }

    func performAuthorizedOperation<T: Sendable>(
        _ operation: @Sendable (GoogleSession) async throws -> T
    ) async throws -> T {
        let generation = activationGeneration
        let provider = signInProvider
        let session = try await refreshedAuthorizedSession(using: provider, generation: generation)
        state = .loading
        defer {
            if generation == activationGeneration {
                recomputeState()
            }
        }
        return try await operation(session)
    }

    private func refreshedAuthorizedSession(
        using provider: any GoogleSignInProviding,
        generation: Int
    ) async throws -> GoogleSession {
        let refreshedSession = try await provider.refreshCurrentSession()
        guard generation == activationGeneration else { throw CancellationError() }
        guard let session = refreshedSession ?? currentSession,
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

    private func configureExportFolderIfNeeded(
        for session: GoogleSession,
        generation: Int,
        configuration: any GoogleDriveExportFolderConfiguring
    ) async {
        guard session.hasScopes(GoogleOAuthScope.drive) else { return }
        state = .loading
        defer {
            if generation == activationGeneration {
                recomputeState()
            }
        }
        do {
            try await configuration.configureIfNeeded(session: session)
            guard generation == activationGeneration else { return }
            exportFolderErrorMessage = nil
        } catch {
            guard generation == activationGeneration else { return }
            recordExportFolderError(error)
        }
    }

    private func recordExportFolderError(_ error: Error) {
        exportFolderErrorMessage = GoogleAuthErrorFormatter.message(
            for: error,
            defaultMessage: L10n.googleDriveUnexpectedResponse
        )
        ErrorReportingService.captureSanitized(.googleDriveExportFolder)
    }

    private func handle(_ error: Error) {
        lastErrorMessage = GoogleAuthErrorFormatter.message(for: error, defaultMessage: L10n.googleDriveUnexpectedResponse)
        state = .failed
        ErrorReportingService.captureSanitized(.googleDrive)
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

    private func handleAuthSessionChanged(forceSignOut: Bool) async {
        let generation = activationGeneration
        let scope = accountScope
        let provider = signInProvider
        didAttemptRestore = false
        guard !forceSignOut, await provider.hasPreviousSignIn else {
            guard generation == activationGeneration, accountScope == scope else { return }
            settings.clearGoogleDriveExportFolder(scope: scope)
            clearRuntimeState()
            exportFolderErrorMessage = nil
            recomputeState()
            return
        }
        guard generation == activationGeneration, accountScope == scope else { return }
        await restoreSessionIfNeeded()
    }
}
