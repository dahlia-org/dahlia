import Foundation
import Observation

@MainActor
@Observable
final class CodexAccountController {
    private(set) var accountStatus: CodexAppServerService.AccountStatus?
    private(set) var isCheckingStatus = false
    private(set) var isSigningIn = false
    private(set) var isSigningOut = false
    private(set) var errorMessage: String?

    private let service: CodexAppServerService
    private let urlOpener: any CodexLoginURLOpening
    private let authenticationDidChange: @MainActor @Sendable () async throws -> Void

    init(
        service: CodexAppServerService = .localAccount,
        urlOpener: any CodexLoginURLOpening = WorkspaceCodexLoginURLOpener(),
        authenticationDidChange: @escaping @MainActor @Sendable () async throws -> Void = {
            try await CodexAccountController.reloadLocalRuntimeAfterAuthenticationChange()
        }
    ) {
        self.service = service
        self.urlOpener = urlOpener
        self.authenticationDidChange = authenticationDidChange
    }

    var isBusy: Bool {
        isCheckingStatus || isSigningIn || isSigningOut
    }

    static func reloadLocalRuntimeAfterAuthenticationChange(
        contextStore: CodexRuntimeContextStore = .shared,
        service: CodexAppServerService = .shared
    ) async throws {
        guard contextStore.isConfigured, contextStore.provider == .chatGPTSubscription else { return }
        try await service.reloadConfiguration()
    }

    func activateChatGPTSubscription() async {
        isCheckingStatus = true
        errorMessage = nil
        defer { isCheckingStatus = false }

        do {
            try Task.checkCancellation()
            accountStatus = try await service.accountStatus(forceRefresh: true)
            try Task.checkCancellation()
        } catch is CancellationError {
            // SwiftUI cancels this operation when the settings screen disappears.
        } catch {
            accountStatus = nil
            errorMessage = error.localizedDescription
        }
    }

    func signIn() async {
        guard !isBusy else { return }
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }

        do {
            let session = try await service.startChatGPTLogin()
            if Task.isCancelled {
                let service = service
                Task { try? await service.cancelLogin(loginID: session.id) }
                throw CancellationError()
            }
            guard urlOpener.open(session.authorizationURL) else {
                try? await service.cancelLogin(loginID: session.id)
                throw CodexAppServerError.loginPageCouldNotOpen
            }
            try await service.waitForLoginCompletion(loginID: session.id)
            try await refreshAfterAuthenticationChange()
        } catch is CancellationError {
            // Cancelling the task also cancels the pending app-server login attempt.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        guard !isBusy else { return }
        isSigningOut = true
        errorMessage = nil
        defer { isSigningOut = false }

        do {
            try await service.logout()
            try await refreshAfterAuthenticationChange()
        } catch is CancellationError {
            // SwiftUI cancels this operation when the settings screen disappears.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshAfterAuthenticationChange() async throws {
        // Credentials have changed; closing settings must not cancel runtime invalidation.
        let authenticationDidChange = authenticationDidChange
        try await Task { try await authenticationDidChange() }.value
        accountStatus = try await service.accountStatus(forceRefresh: true)
    }
}
